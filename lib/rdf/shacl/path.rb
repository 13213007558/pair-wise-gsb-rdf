# frozen_string_literal: true

module RDF
  module SHACL
    ##
    # Property path syntax accepted by this SHACL Core subset.
    class Path
      class Predicate < Path
        attr_reader :predicate

        def initialize(predicate)
          @predicate = predicate
        end

        def evaluate(graph, nodes)
          nodes.flat_map do |node|
            graph.query([node, predicate, nil]).map(&:object)
          end.uniq
        end

        def result_path
          predicate
        end
      end

      class Inverse < Path
        def initialize(path)
          @path = path
        end

        def evaluate(graph, nodes)
          targets = nodes.uniq
          if @path.is_a?(Predicate)
            graph.query([nil, @path.predicate, nil]).select do |statement|
              targets.include?(statement.object)
            end.map(&:subject).uniq
          else
            graph.subjects.select do |subject|
              (@path.evaluate(graph, [subject]) & targets).any?
            end
          end
        end

        def result_path
          { inverse: @path.result_path }
        end
      end

      class Alternative < Path
        def initialize(paths)
          @paths = paths
        end

        def evaluate(graph, nodes)
          @paths.flat_map { |path| path.evaluate(graph, nodes) }.uniq
        end

        def result_path
          { alternative: @paths.map(&:result_path) }
        end
      end

      class Sequence < Path
        def initialize(paths)
          @paths = paths
        end

        def evaluate(graph, nodes)
          @paths.reduce(nodes.uniq) do |current, path|
            path.evaluate(graph, current)
          end
        end

        def result_path
          { sequence: @paths.map(&:result_path) }
        end
      end

      class ZeroOrMore < Path
        def initialize(path)
          @path = path
        end

        def evaluate(graph, nodes)
          reachable = nodes.uniq.to_set
          frontier = nodes.uniq

          until frontier.empty?
            frontier = @path.evaluate(graph, frontier).reject { |node| reachable.include?(node) }
            reachable.merge(frontier)
          end

          reachable.to_a
        end

        def result_path
          { zero_or_more: @path.result_path }
        end
      end

      class OneOrMore < Path
        def initialize(path)
          @path = path
        end

        def evaluate(graph, nodes)
          ZeroOrMore.new(@path).evaluate(graph, @path.evaluate(graph, nodes))
        end

        def result_path
          { one_or_more: @path.result_path }
        end
      end

      class ZeroOrOne < Path
        def initialize(path)
          @path = path
        end

        def evaluate(graph, nodes)
          (nodes.uniq + @path.evaluate(graph, nodes)).uniq
        end

        def result_path
          { zero_or_one: @path.result_path }
        end
      end

      def self.parse(shape_graph, term)
        return Predicate.new(term) if term.uri?
        if term.node?
          sequence = try_sequence(shape_graph, term)
          return sequence if sequence
          return parse_blank_path(shape_graph, term)
        end

        raise MalformedShapeError, "unsupported path term: #{term.inspect}"
      end

      def self.parse_blank_path(graph, term)
        statements = graph.query([term, nil, nil]).to_a
        predicates = statements.map(&:predicate).uniq
        if predicates.length > 1
          raise MalformedShapeError, "property path has multiple path operators: #{term.inspect}"
        end
        if statements.empty? && term == RDF.nil
          raise MalformedShapeError, 'empty property path is not supported'
        end

        predicate = predicates.first
        values = statements.map(&:object)

        case predicate
        when SHACL.inverse
          single(predicate, values) { |value| Inverse.new(parse(graph, value)) }
        when SHACL.alternativePath
          list(graph, single(predicate, values)).map { |item| parse(graph, item) }.then { |paths| Alternative.new(paths) }
        when path_list_term(:zeroOrMorePath)
          single(predicate, values) { |value| ZeroOrMore.new(parse(graph, value)) }
        when path_list_term(:oneOrMorePath)
          single(predicate, values) { |value| OneOrMore.new(parse(graph, value)) }
        when path_list_term(:zeroOrOnePath)
          single(predicate, values) { |value| ZeroOrOne.new(parse(graph, value)) }
        else
          raise MalformedShapeError, "unsupported property path operator: #{predicate.inspect}"
        end
      end

      def self.path_list_term(name)
        RDF::SHACL::TERMS.fetch(name)
      end

      def self.single(predicate, values)
        unless values.length == 1
          raise MalformedShapeError, "#{predicate} requires exactly one value, got #{values.length}"
        end

        block_given? ? yield(values.first) : values.first
      end

      def self.list(graph, head)
        values = []
        current = head
        seen = Set.new

        until current == RDF.nil
          raise MalformedShapeError, 'cyclic RDF list' unless seen.add?(current)

          firsts = graph.query([current, RDF.first, nil]).map(&:object)
          rests = graph.query([current, RDF.rest, nil]).map(&:object)
          unless firsts.length == 1 && rests.length == 1
            raise MalformedShapeError, "malformed RDF list at #{current.inspect}"
          end

          values << firsts.first
          current = rests.first
        end

        values
      end

      # A sequence path is an RDF list of any supported path terms.
      def self.try_sequence(graph, term)
        return unless term.node?
        path_predicates = [
          SHACL.inverse,
          SHACL.alternativePath,
          path_list_term(:zeroOrMorePath),
          path_list_term(:oneOrMorePath),
          path_list_term(:zeroOrOnePath)
        ]
        return if path_predicates.any? { |predicate| graph.query([term, predicate, nil]).any? }
        return if graph.query([term, RDF.rest, nil]).none?
        return unless graph.query([term, RDF.first, nil]).any? || term == RDF.nil

        list(graph, term).map { |item| parse(graph, item) }.then { |paths| Sequence.new(paths) }
      end

      def evaluate(_graph, _nodes)
        raise NotImplementedError
      end

      def result_path
        raise NotImplementedError
      end
    end
  end
end
