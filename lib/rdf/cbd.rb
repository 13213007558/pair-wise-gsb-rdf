module RDF
  ##
  # Concise Bounded Description (CBD) extraction.
  #
  # A CBD is the complete local description of a resource, suitable for
  # handing off to another service without transferring the whole graph.
  # Starting from a given subject, the CBD contains:
  #
  # * every statement having the subject as its subject,
  # * recursively, the description of every blank node appearing as the
  #   object of an included statement (cycles are followed only once),
  # * every reification of an included statement, both in the classic
  #   `rdf:Statement` form and as RDF 1.2 triple terms (embedded
  #   statements appearing as the object of another statement).
  #
  # Plain URI objects are kept as references only; they are reported in
  # {Result#boundary} so the caller knows which resources were not taken
  # along. Blank nodes having no description in scope are reported there
  # as well.
  #
  # When the source contains multiple named graphs, the caller chooses
  # the scoping semantics through the `graph_name` option; extracted
  # statements always retain their original `graph_name`.
  #
  # @example Extracting the CBD of a resource from a repository
  #   result = RDF::CBD.extract(repository, RDF::URI("http://example.org/s"))
  #   result.statements # => [...]
  #   result.boundary   # => [RDF::URI("http://example.org/other"), ...]
  #
  # @see https://www.w3.org/Submission/CBD/
  module CBD
    ##
    # The result of a CBD extraction.
    #
    # Behaves as an {RDF::Enumerable} over the extracted statements.
    class Result
      include RDF::Enumerable

      ##
      # The resource the description was extracted for.
      #
      # @!attribute [r] subject
      # @return [RDF::Resource]
      attr_reader :subject

      ##
      # The statements making up the concise bounded description, in
      # extraction order. Each statement retains the `graph_name` it had
      # in the source.
      #
      # @!attribute [r] statements
      # @return [Array<RDF::Statement>]
      attr_reader :statements

      ##
      # Resources referenced from, but not taken along into, the
      # description: URI objects of included statements, and blank nodes
      # having no description in the selected scope.
      #
      # @!attribute [r] boundary
      # @return [Array<RDF::Resource>]
      attr_reader :boundary

      ##
      # @param  [RDF::Resource]          subject
      # @param  [Array<RDF::Statement>]  statements
      # @param  [Array<RDF::Resource>]   boundary
      def initialize(subject, statements, boundary)
        @subject    = subject
        @statements = statements.freeze
        @boundary   = boundary.freeze
      end

      ##
      # Enumerates each statement in the description.
      #
      # @yield  [statement]
      # @yieldparam [RDF::Statement] statement
      # @return [Enumerator<RDF::Statement>]
      def each(&block)
        block_given? ? @statements.each(&block) : enum_for(:each)
      end

      ##
      # Returns the description as an {RDF::Dataset}, preserving the
      # graph attribution of each statement.
      #
      # @return [RDF::Dataset]
      def to_dataset
        RDF::Dataset.new(statements: @statements)
      end
    end

    class << self
      ##
      # Extracts the concise bounded description of `subject` from
      # `queryable`.
      #
      # @param  [RDF::Queryable] queryable
      #   the source to extract from (e.g. an {RDF::Graph},
      #   {RDF::Repository}, or {RDF::Dataset})
      # @param  [RDF::Resource] subject
      #   the resource to describe
      # @param  [RDF::Resource, false, nil] graph_name
      #   graph scoping semantics: `nil` (the default) applies dataset
      #   semantics, considering statements in every graph; `false`
      #   considers only the default graph; any other term considers only
      #   that named graph. Note that an {RDF::Graph} is always
      #   implicitly scoped to its own graph name.
      # @return [RDF::CBD::Result]
      # @raise  [ArgumentError] unless `subject` is an {RDF::Resource}
      def extract(queryable, subject, graph_name: nil)
        unless subject.is_a?(RDF::Resource)
          raise ArgumentError, "subject must be an RDF::Resource, got: #{subject.inspect}"
        end

        statements      = []
        seen_statements = {}
        boundary        = []
        seen_boundary   = {}
        expanded_nodes  = {}
        node_queue      = [subject]
        statement_queue = []

        add_boundary = lambda do |term|
          unless seen_boundary.key?(term)
            seen_boundary[term] = true
            boundary << term
          end
        end

        # Note: statements are deduplicated by their quad, as
        # `RDF::Statement#hash` cannot be computed on frozen statements.
        add_statement = lambda do |statement|
          key = statement.to_quad
          next if seen_statements.key?(key)
          seen_statements[key] = true
          statements << statement
          statement_queue << statement

          object = statement.object
          if object.is_a?(RDF::Node)
            node_queue << object unless expanded_nodes.key?(object)
          elsif object.uri?
            add_boundary.call(object)
          end
        end

        until node_queue.empty? && statement_queue.empty?
          until node_queue.empty?
            resource = node_queue.shift
            next if resource.is_a?(RDF::Node) && expanded_nodes.key?(resource)
            expanded_nodes[resource] = true if resource.is_a?(RDF::Node)

            matches = []
            queryable.query({subject: resource, graph_name: graph_name}) {|statement| matches << statement}
            add_boundary.call(resource) if matches.empty? && resource.is_a?(RDF::Node)
            matches.each {|statement| add_statement.call(statement)}
          end

          until statement_queue.empty?
            statement = statement_queue.shift
            reifications(queryable, statement, graph_name).each do |reification|
              add_statement.call(reification)
              reifier = reification.subject
              node_queue << reifier if reifier.is_a?(RDF::Node) && !expanded_nodes.key?(reifier)
            end
          end
        end

        # The root subject is always taken along, never a boundary reference.
        if seen_boundary.key?(subject)
          seen_boundary.delete(subject)
          boundary.delete(subject)
        end

        Result.new(subject, statements, boundary)
      end

      private

      ##
      # Finds statements reifying `statement` within the given graph
      # scope, both as classic `rdf:Statement` reification quads and as
      # RDF 1.2 triple-term descriptions.
      #
      # @param  [RDF::Queryable] queryable
      # @param  [RDF::Statement] statement
      # @param  [RDF::Resource, false, nil] graph_name
      # @return [Array<RDF::Statement>]
      def reifications(queryable, statement, graph_name)
        found = []
        seen  = {}

        add = lambda do |candidate|
          key = candidate.to_quad
          unless seen.key?(key)
            seen[key] = true
            found << candidate
          end
        end

        # Triple-term reification: statements having `statement` as an
        # embedded (non-asserted) object. The embedded term carries no
        # graph name, so strip it before matching.
        embedded = statement.dup
        embedded.graph_name = nil
        queryable.query({object: embedded, graph_name: graph_name}) {|candidate| add.call(candidate)}

        # Classic reification: a subject typed `rdf:Statement` whose
        # `rdf:subject`, `rdf:predicate`, and `rdf:object` match.
        quad = {
          RDF.type      => RDF[:Statement],
          RDF.subject   => statement.subject,
          RDF.predicate => statement.predicate,
          RDF.object    => statement.object,
        }
        queryable.query({predicate: RDF.subject, object: statement.subject, graph_name: graph_name}) do |link|
          description = []
          queryable.query({subject: link.subject, graph_name: graph_name}) {|candidate| description << candidate}
          matching = description.select do |candidate|
            quad.any? {|predicate, object| candidate.predicate == predicate && candidate.object == object}
          end
          complete = quad.all? do |predicate, object|
            matching.any? {|candidate| candidate.predicate == predicate && candidate.object == object}
          end
          matching.each {|candidate| add.call(candidate)} if complete
        end

        found
      end
    end
  end
end
