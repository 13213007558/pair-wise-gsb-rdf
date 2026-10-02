# -*- coding: utf-8 -*-
module RDF
  module Util
    ##
    # Compatibility conversion between datasets containing RDF 1.2 triple
    # terms (quoted triples) and the RDF 1.1 reification vocabulary, for
    # stores which only accept RDF 1.1 data.
    #
    # {Reification.convert} replaces every triple term used as the subject
    # or object of a statement with a fresh reification resource, and adds
    # the corresponding `rdf:type`, `rdf:subject`, `rdf:predicate`, and
    # `rdf:object` quads to the same graph as the referencing statement.
    # It returns the converted dataset along with a mapping from each
    # generated resource to the triple term it stands for.
    #
    # {Reification.restore} performs the inverse conversion, driven
    # exclusively by that mapping: only generated resources found in the
    # mapping are substituted back, and only their generated reification
    # quads are removed. Native `rdf:Statement` data already present in
    # the dataset is left untouched.
    #
    # Equal triple terms are reified to the same resource, nested triple
    # terms are reified recursively, and graph names and blank node
    # identities are preserved.
    #
    # @example Round-tripping a dataset through an RDF 1.1 store
    #   converted, mapping = RDF::Util::Reification.convert(dataset)
    #   # ... store and reload converted ...
    #   restored = RDF::Util::Reification.restore(converted, mapping)
    module Reification
      extend self

      ##
      # Converts triple terms in the input into RDF 1.1 reification quads.
      #
      # @param  [RDF::Enumerable] enum
      #   a dataset or repository, possibly containing triple terms
      # @return [Array(RDF::Dataset, Hash{RDF::Resource => RDF::Statement})]
      #   the converted dataset, and a mapping from each generated
      #   reification resource to the original triple term, for use with
      #   {#restore}
      def convert(enum)
        mapping   = {}
        resources = {}
        emitted   = Hash.new {|h, k| h[k] = {} }
        output    = []

        convert_term = nil
        convert_term = lambda do |term, graph_key, graph_name, quads|
          return term unless term.is_a?(RDF::Statement)
          resource = resources[term.to_triple] ||= RDF::Node.new
          mapping[resource] ||= term
          unless emitted[resource][graph_key]
            emitted[resource][graph_key] = true
            subject = convert_term.call(term.subject, graph_key, graph_name, quads)
            object  = convert_term.call(term.object,  graph_key, graph_name, quads)
            quads << RDF::Statement.new(resource, RDF[:type],      RDF[:Statement], graph_name: graph_name)
            quads << RDF::Statement.new(resource, RDF[:subject],   subject,         graph_name: graph_name)
            quads << RDF::Statement.new(resource, RDF[:predicate], term.predicate,  graph_name: graph_name)
            quads << RDF::Statement.new(resource, RDF[:object],    object,          graph_name: graph_name)
          end
          resource
        end

        enum.each_statement do |statement|
          graph_name = statement.graph_name
          graph_key  = graph_name || false
          quads      = []
          subject    = convert_term.call(statement.subject, graph_key, graph_name, quads)
          object     = convert_term.call(statement.object,  graph_key, graph_name, quads)
          output.concat(quads)
          output << if subject.equal?(statement.subject) && object.equal?(statement.object)
            statement
          else
            RDF::Statement.new(subject, statement.predicate, object,
              **statement.options, graph_name: graph_name)
          end
        end

        [RDF::Dataset.new(statements: output), mapping]
      end

      ##
      # Restores triple terms from a dataset produced by {#convert}, using
      # the mapping returned by {#convert}.
      #
      # Only statements whose subject is a resource found in the mapping
      # are removed (the generated reification quads), and only mapped
      # resources are substituted back with their original triple term.
      # Any other statements, including native `rdf:Statement`
      # reification data, are passed through unchanged.
      #
      # @param  [RDF::Enumerable] enum
      #   a dataset previously produced by {#convert}
      # @param  [Hash{RDF::Resource => RDF::Statement}] mapping
      #   the mapping returned by {#convert}
      # @return [RDF::Dataset]
      def restore(enum, mapping)
        output = []
        enum.each_statement do |statement|
          next if mapping.key?(statement.subject)
          object = statement.object
          object = mapping[object] if mapping.key?(object)
          output << if object.equal?(statement.object)
            statement
          else
            RDF::Statement.new(statement.subject, statement.predicate, object,
              **statement.options, graph_name: statement.graph_name)
          end
        end
        RDF::Dataset.new(statements: output)
      end
    end
  end
end
