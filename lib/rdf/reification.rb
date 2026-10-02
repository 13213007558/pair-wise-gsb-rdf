module RDF
  ##
  # RDF 1.1 compatibility transformation for data containing triple terms
  # (RDF 1.2 quoted triples).
  #
  # Some legacy stores only accept RDF 1.1, where a statement may not appear
  # as the subject or object of another statement. {RDF::Reification}
  # converts such *triple terms* into ordinary reified resources
  # (rdf:Statement with rdf:subject, rdf:predicate, and rdf:object)
  # which any RDF 1.1 store accepts, and returns a mapping that allows the
  # original triple terms to be restored later.
  #
  # Equal triple terms are reified onto the same resource, so repeated
  # references share a single reification. Named graphs are preserved:
  # statements stay in their original graphs, and the reification quads for
  # a triple term are added to every graph in which the term is referenced.
  # Blank nodes (including those inside triple terms) keep their identity,
  # preserving blank-node scope within the dataset.
  #
  # The inverse transformation is driven exclusively by the mapping returned
  # from {.transform}; rdf:Statement reification data that was natively
  # present in the input is left untouched and is never consumed by
  # {.restore}.
  #
  # @example Round-tripping a dataset through an RDF 1.1 store
  #   dataset = RDF::Dataset.new(statements: [
  #     RDF::Statement(RDF::URI(:s), RDF::URI(:p),
  #       RDF::Statement(RDF::URI(:a), RDF::URI(:b), RDF::URI(:c))),
  #   ])
  #   rdf11, mapping = RDF::Reification.transform(dataset)
  #   # ... store and reload rdf11 ...
  #   restored = RDF::Reification.restore(rdf11, mapping)
  module Reification
    # Node identifier prefix used for generated reification resources.
    NODE_PREFIX = 'reify'

    ##
    # Converts triple terms found in +dataset+ into reified resources.
    #
    # @param  [RDF::Enumerable] dataset
    #   the input data, e.g. an {RDF::Dataset} or {RDF::Repository}
    # @return [Array(RDF::Dataset, Hash{RDF::Node => RDF::Statement})]
    #   the transformed dataset containing no triple terms, and a mapping
    #   from each generated reification resource to the original triple
    #   term, suitable for {.restore}
    def self.transform(dataset)
      mapping    = {} # resource => original triple term
      resources  = {} # canonical (rewritten) triple term => resource
      canonicals = {} # resource => canonical triple term
      emitted    = {} # [resource, graph_name] => true
      taken      = blank_node_ids(dataset)
      counter    = 0
      statements = []

      convert = nil
      convert = lambda do |term, encountered|
        return term unless term.is_a?(RDF::Statement)

        subject   = convert.call(term.subject, encountered)
        object    = convert.call(term.object, encountered)
        canonical = RDF::Statement(subject, term.predicate, object)

        resource = resources[canonical]
        unless resource
          begin
            resource = RDF::Node("#{NODE_PREFIX}#{counter}")
            counter += 1
          end while taken[resource.id]
          taken[resource.id]   = true
          resources[canonical] = resource
          canonicals[resource] = canonical
          mapping[resource]    = term
        end

        encountered << resource
        resource
      end

      dataset.each do |statement|
        encountered = []
        subject     = convert.call(statement.subject, encountered)
        object      = convert.call(statement.object, encountered)
        graph_name  = statement.graph_name

        statements << if subject.equal?(statement.subject) && object.equal?(statement.object)
          statement
        else
          RDF::Statement(subject, statement.predicate, object, graph_name: graph_name)
        end

        encountered.each do |resource|
          key = [resource, graph_name]
          next if emitted[key]
          emitted[key] = true
          canonical = canonicals[resource]
          statements << RDF::Statement(resource, RDF.type,      RDF[:Statement],     graph_name: graph_name)
          statements << RDF::Statement(resource, RDF.subject,   canonical.subject,   graph_name: graph_name)
          statements << RDF::Statement(resource, RDF.predicate, canonical.predicate, graph_name: graph_name)
          statements << RDF::Statement(resource, RDF.object,    canonical.object,    graph_name: graph_name)
        end
      end

      [RDF::Dataset.new(statements: statements), mapping]
    end

    ##
    # Restores triple terms in a dataset previously transformed with
    # {.transform}, using only the returned +mapping+.
    #
    # Statements whose subject is a reification resource from +mapping+ are
    # removed, and remaining references to those resources are replaced by
    # the original triple terms. Any other data, including rdf:Statement
    # reification quads that were natively present in the input, is passed
    # through unchanged.
    #
    # @param  [RDF::Enumerable] dataset
    #   a dataset produced by {.transform}
    # @param  [Hash{RDF::Resource => RDF::Statement}] mapping
    #   the mapping returned by {.transform}
    # @return [RDF::Dataset]
    def self.restore(dataset, mapping)
      statements = []

      dataset.each do |statement|
        next if mapping.key?(statement.subject)

        subject = mapping.fetch(statement.subject, statement.subject)
        object  = mapping.fetch(statement.object, statement.object)

        statements << if subject.equal?(statement.subject) && object.equal?(statement.object)
          statement
        else
          RDF::Statement(subject, statement.predicate, object, graph_name: statement.graph_name)
        end
      end

      RDF::Dataset.new(statements: statements)
    end

    ##
    # Collects the identifiers of all blank nodes in +dataset+, including
    # those nested inside triple terms.
    #
    # @param  [RDF::Enumerable] dataset
    # @return [Hash{String => true}]
    # @private
    def self.blank_node_ids(dataset)
      ids = {}
      walk = nil
      walk = lambda do |term|
        case term
        when RDF::Node      then ids[term.id] = true
        when RDF::Statement then term.to_quad.each { |t| walk.call(t) }
        end
      end
      dataset.each { |statement| statement.to_quad.each { |term| walk.call(term) } }
      ids
    end
    private_class_method :blank_node_ids
  end
end
