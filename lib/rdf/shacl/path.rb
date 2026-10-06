require 'rdf/shacl'

module RDF
  module SHACL
    ##
    # A SHACL property path. Paths are parsed once from the shapes
    # graph and evaluated against the data graph, returning the set of
    # value nodes reachable from a focus node.
    class Path
      ##
      # Parses the object of an sh:path triple into a Path.
      #
      # @param  [RDF::Resource] node
      # @param  [RDF::Queryable] shapes_graph
      # @return [RDF::SHACL::Path]
      # @raise  [ArgumentError] on malformed paths
      def self.parse(node, shapes_graph)
        case
        when node.is_a?(RDF::URI)
          Predicate.new(node)
        when (inner = shapes_graph.first_object(subject: node, predicate: SHACL[:inversePath]))
          subpath = parse(inner, shapes_graph)
          unless subpath.is_a?(Predicate)
            raise ArgumentError, "sh:inversePath only supports predicate paths: #{node.to_ntriples}"
          end
          Inverse.new(subpath)
        when (inner = shapes_graph.first_object(subject: node, predicate: SHACL[:alternativePath]))
          Alternative.new(list_members(inner, shapes_graph).map { |member| parse(member, shapes_graph) })
        when (inner = shapes_graph.first_object(subject: node, predicate: SHACL[:zeroOrMorePath]))
          ZeroOrMore.new(parse(inner, shapes_graph))
        when (inner = shapes_graph.first_object(subject: node, predicate: SHACL[:oneOrMorePath]))
          OneOrMore.new(parse(inner, shapes_graph))
        when (inner = shapes_graph.first_object(subject: node, predicate: SHACL[:zeroOrOnePath]))
          ZeroOrOne.new(parse(inner, shapes_graph))
        when node == RDF.nil || shapes_graph.first_object(subject: node, predicate: RDF.first)
          Sequence.new(list_members(node, shapes_graph).map { |member| parse(member, shapes_graph) })
        else
          raise ArgumentError, "Unsupported SHACL path: #{node.to_ntriples}"
        end
      end

      ##
      # Returns the members of an RDF list in the shapes graph.
      #
      # @param  [RDF::Resource] node
      # @param  [RDF::Queryable] shapes_graph
      # @return [Array<RDF::Term>]
      def self.list_members(node, shapes_graph)
        return [] if node == RDF.nil
        # NOTE: use #map to get a plain Array; RDF::List#to_a is extended
        # with RDF::Countable, whose #count silently ignores blocks.
        RDF::List.new(subject: node, graph: shapes_graph).map { |term| term }
      end

      ##
      # Evaluates this path from +focus+ against the data graph.
      #
      # @param  [RDF::Term] focus
      # @param  [RDF::Queryable] data_graph
      # @return [Array<RDF::Term>] unique value nodes
      def evaluate(focus, data_graph)
        raise NotImplementedError
      end

      ##
      # A predicate path: a single IRI, including rdf:type.
      class Predicate < Path
        attr_reader :iri

        def initialize(iri)
          @iri = iri
        end

        def evaluate(focus, data_graph)
          data_graph.query({subject: focus, predicate: iri}).objects.uniq
        end

        def to_s
          iri.to_s
        end
      end

      ##
      # An inverse path: sh:inversePath.
      class Inverse < Path
        attr_reader :subpath

        def initialize(subpath)
          @subpath = subpath
        end

        def evaluate(focus, data_graph)
          data_graph.query({predicate: subpath.iri, object: focus}).subjects.uniq
        end
      end

      ##
      # A sequence path: an RDF list of paths evaluated in order.
      class Sequence < Path
        attr_reader :subpaths

        def initialize(subpaths)
          @subpaths = subpaths
        end

        def evaluate(focus, data_graph)
          nodes = [focus]
          subpaths.each do |subpath|
            nodes = nodes.flat_map { |node| subpath.evaluate(node, data_graph) }.uniq
          end
          nodes
        end
      end

      ##
      # An alternative path: sh:alternativePath, the union of members.
      class Alternative < Path
        attr_reader :subpaths

        def initialize(subpaths)
          @subpaths = subpaths
        end

        def evaluate(focus, data_graph)
          subpaths.flat_map { |subpath| subpath.evaluate(focus, data_graph) }.uniq
        end
      end

      ##
      # A zero-or-more path: sh:zeroOrMorePath. Cycle-safe by keeping a
      # visited set during the breadth-first traversal.
      class ZeroOrMore < Path
        attr_reader :subpath

        def initialize(subpath)
          @subpath = subpath
        end

        def evaluate(focus, data_graph)
          reached = [focus]
          seen    = {focus => true}
          queue   = [focus]
          until queue.empty?
            subpath.evaluate(queue.shift, data_graph).each do |value|
              next if seen[value]
              seen[value] = true
              reached << value
              queue   << value
            end
          end
          reached
        end
      end

      ##
      # A one-or-more path: sh:oneOrMorePath. Like ZeroOrMore but the
      # focus node itself only counts if it is reachable in >= 1 steps.
      class OneOrMore < Path
        attr_reader :subpath

        def initialize(subpath)
          @subpath = subpath
        end

        def evaluate(focus, data_graph)
          reached = []
          seen    = {}
          queue   = subpath.evaluate(focus, data_graph)
          until queue.empty?
            current = queue.shift
            next if seen[current]
            seen[current] = true
            reached << current
            subpath.evaluate(current, data_graph).each do |value|
              queue << value unless seen[value]
            end
          end
          reached
        end
      end

      ##
      # A zero-or-one path: sh:zeroOrOnePath.
      class ZeroOrOne < Path
        attr_reader :subpath

        def initialize(subpath)
          @subpath = subpath
        end

        def evaluate(focus, data_graph)
          ([focus] + subpath.evaluate(focus, data_graph)).uniq
        end
      end
    end # Path
  end # SHACL
end # RDF
