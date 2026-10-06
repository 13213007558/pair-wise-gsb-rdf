# frozen_string_literal: true

module RDF
  module SHACL
    class Validator
      class Shape
        attr_reader :id, :target_classes, :target_nodes
        attr_accessor :path
        attr_accessor :deactivated, :klass, :datatype, :min_count, :max_count
        attr_accessor :and_shapes, :or_shapes, :not_shapes, :xone_shapes
        attr_accessor :node_shapes, :property_shapes
        attr_accessor :qualified_value_shapes, :qualified_min_count, :qualified_max_count
        attr_accessor :qualified_disjoint

        def initialize(id)
          @id = id
          @target_classes = []
          @target_nodes = []
          @and_shapes = []
          @or_shapes = []
          @not_shapes = []
          @xone_shapes = []
          @node_shapes = []
          @property_shapes = []
          @qualified_value_shapes = []
        end

        def property_shape?
          !@path.nil?
        end
      end

      class FatalResult < Result
      end

      def initialize(shape_graph)
        @shape_graph = shape_graph
        @shapes = {}
        @compiled = Set.new
      end

      def validate(data_graph)
        @data_graph = data_graph
        @active = []
        @fatal_results = []
        @fatal_seen = Set.new

        results = root_shapes.flat_map do |shape|
          target_nodes(shape).flat_map do |node|
            validate_shape(shape, node)
          end
        end

        all_results = results.compact + @fatal_results
        Report.new(all_results.uniq { |result| result_key(result) })
      ensure
        @data_graph = nil
        @active = []
      end

      private

      def root_shapes
        terms = [SHACL.targetClass, SHACL.targetNode].flat_map do |predicate|
          @shape_graph.query([nil, predicate, nil]).map(&:subject)
        end.uniq

        terms.map { |term| shape(term) }.reject(&:deactivated)
      end

      def target_nodes(shape)
        nodes = shape.target_nodes.select(&:resource?).dup
        nodes.concat(shape.target_classes.flat_map { |klass| instances_of(klass) })
        nodes.uniq
      end

      def instances_of(klass)
        subclasses(klass).flat_map do |candidate|
          @data_graph.query([nil, RDF.type, candidate]).map(&:subject)
        end.uniq
      end

      def subclasses(klass)
        result = [klass]
        frontier = [klass]
        seen = Set.new([klass])

        until frontier.empty?
          current = frontier.pop
          children = @data_graph.query([nil, RDF::RDFS.subClassOf, current]).map(&:subject)
          children.each do |child|
            next unless seen.add?(child)

            result << child
            frontier << child
          end
        end

        result
      end

      def shape(id)
        return @shapes[id] if @shapes.key?(id)

        model = Shape.new(id)
        @shapes[id] = model
        compile(model)
        model
      end

      def compile(model)
        id = model.id
        return unless @compiled.add?(id)
        statements = @shape_graph.query([id, nil, nil]).to_a
        path_statement = statements.find { |statement| statement.predicate == SHACL.path }
        model.path = Path.parse(@shape_graph, path_statement.object) if path_statement

        is_property_shape = model.property_shape? || statements.any? { |statement| statement.object == SHACL.PropertyShape }
        if is_property_shape && model.path.nil?
          raise MalformedShapeError, "property shape #{id.inspect} requires sh:path"
        end

        statements.each do |statement|
          assign(model, statement.predicate, statement.object)
        end

        model
      end

      def assign(model, predicate, object)
        case predicate
        when RDF.type then nil
        when SHACL.targetClass then model.target_classes << object
        when SHACL.targetNode then model.target_nodes << object
        when SHACL.deactivated then model.deactivated = true?(object)
        when SHACL.path then nil
        when SHACL[:class] then model.klass = object
        when SHACL.datatype then model.datatype = object
        when SHACL.minCount then model.min_count = integer(object)
        when SHACL.maxCount then model.max_count = integer(object)
        when SHACL.and then model.and_shapes.concat(list(object).map { |item| shape(item) })
        when SHACL.or then model.or_shapes.concat(list(object).map { |item| shape(item) })
        when SHACL.not then model.not_shapes << shape(object)
        when SHACL.xone then model.xone_shapes.concat(list(object).map { |item| shape(item) })
        when SHACL.node then model.node_shapes << shape(object)
        when SHACL.property then model.property_shapes << shape(object)
        when SHACL.qualifiedValueShape
          model.qualified_value_shapes << shape(object)
        when SHACL.qualifiedValueShapesDisjoint
          model.qualified_disjoint = true?(object)
        when SHACL.qualifiedMinCount then model.qualified_min_count = integer(object)
        when SHACL.qualifiedMaxCount then model.qualified_max_count = integer(object)
        end
      end

      def validate_shape(model, focus, result_path = nil, negative = false)
        return [] if model.deactivated

        key = [model.id, focus]
        if (active = @active.find { |entry| entry[0] == key })
          return positive_cycle_result unless negative != active[1]

          return negative_cycle_result(model, focus, result_path)
        end

        @active << [key, negative]
        begin
          findings = if model.property_shape?
            validate_property_shape(model, focus)
          else
            validate_node_shape(model, focus, result_path)
          end
          fatal = findings.any? { |finding| finding.is_a?(FatalResult) }
          fatal ? nil : findings.compact
        ensure
          @active.pop
        end
      end

      def validate_property_shape(model, focus)
        values = model.path.evaluate(@data_graph, [focus])
        findings = []

        if model.min_count && values.length < model.min_count
          findings << result(focus, model.path.result_path, nil, model, :minCount,
                             expected: model.min_count, actual: values.length)
        end
        if model.max_count && values.length > model.max_count
          findings << result(focus, model.path.result_path, nil, model, :maxCount,
                             expected: model.max_count, actual: values.length)
        end

        values.each do |value|
          value_findings = validate_value_constraints(model, focus, value, model.path.result_path)
          return nil if value_findings.nil?

          findings.concat(value_findings)
        end

        qualified_findings = validate_qualified_counts(model, focus, values)
        return nil if qualified_findings.nil?

        findings.concat(qualified_findings)
        model.property_shapes.each do |child|
          child_findings = validate_shape(child, focus)
          return nil if child_findings.nil?

          findings.concat(child_findings)
        end
        findings
      end

      def validate_node_shape(model, focus, result_path)
        findings = validate_value_constraints(model, focus, focus, result_path)
        return nil if findings.nil?

        model.property_shapes.each do |child|
          child_findings = validate_shape(child, focus)
          return nil if child_findings.nil?

          findings.concat(child_findings)
        end
        findings
      end

      def validate_value_constraints(model, focus, value, result_path)
        findings = []
        findings << datatype_result(model, focus, value, result_path) if model.datatype
        findings << class_result(model, focus, value, result_path) if model.klass
        model.node_shapes.each do |child|
          child_findings = validate_shape(child, value, result_path)
          return nil if child_findings.nil?

          findings.concat(child_findings)
        end
        logical_findings = logical_results(model, focus, value, result_path)
        return nil if logical_findings.nil?

        findings.concat(logical_findings)
        findings
      end

      def datatype_result(model, focus, value, result_path)
        return if value.literal? && value.datatype == model.datatype && value.valid?

        result(focus, result_path, value, model, :datatype, expected: model.datatype)
      end

      def class_result(model, focus, value, result_path)
        types = value.resource? ? @data_graph.query([value, RDF.type, nil]).map(&:object) : []
        matches = types.any? { |type| class_chain_includes?(type, model.klass) }
        return if matches

        result(focus, result_path, value, model, :class, expected: model.klass)
      end

      def class_chain_includes?(type, expected)
        frontier = [type]
        seen = Set.new

        until frontier.empty?
          current = frontier.pop
          return true if current == expected
          next unless seen.add?(current)

          @data_graph.query([current, RDF::RDFS.subClassOf, nil]).each do |statement|
            frontier << statement.object
          end
        end

        false
      end

      def logical_results(model, focus, value, result_path)
        findings = []
        model.and_shapes.each do |shape|
          child_findings = validate_shape(shape, value, result_path)
          return nil if child_findings.nil?

          findings.concat(child_findings)
        end
        findings.concat(or_result(model, focus, value, result_path)) if model.or_shapes.any?
        return nil if findings.any?(&:nil?)

        findings.concat(xone_result(model, focus, value, result_path)) if model.xone_shapes.any?
        return nil if findings.any?(&:nil?)

        findings.concat(not_results(model, focus, value, result_path))
        return nil if findings.any?(&:nil?)

        findings
      end

      def or_result(model, focus, value, result_path)
        branches = model.or_shapes.map do |shape|
          [shape, validate_shape(shape, value, result_path)]
        end
        fatal = branches.any? { |_, findings| findings.nil? }
        return [] if !fatal && branches.any? { |_, findings| findings == [] }

        fatal ? nil : [result(focus, result_path, value, model, :or,
                              detail: branches.flat_map { |_, findings| findings })]
      end

      def xone_result(model, focus, value, result_path)
        branches = model.xone_shapes.map do |shape|
          [shape, validate_shape(shape, value, result_path)]
        end
        return nil if branches.any? { |_, findings| findings.nil? }
        conforming = branches.select { |_, findings| findings == [] }
        return [] if conforming.length == 1

        [result(focus, result_path, value, model, :xone,
                 conforming: conforming.length,
                 detail: branches.flat_map { |_, findings| findings })]
      end

      def not_results(model, focus, value, result_path)
        results = []
        model.not_shapes.each do |shape|
          child_findings = validate_shape(shape, value, result_path, true)
          return nil if child_findings.nil?
          next unless child_findings.empty?

          results << result(focus, result_path, value, model, :not, negated_shape: shape.id)
        end
        results
      end

      def validate_qualified_counts(model, focus, values)
        return [] unless model.qualified_min_count || model.qualified_max_count

        findings = []
        model.qualified_value_shapes.each do |qualified_shape|
          siblings = model.qualified_value_shapes.reject { |candidate| candidate.equal?(qualified_shape) }
          count = 0
          values.each do |value|
            conforms = conforms?(qualified_shape, value)
            return nil if conforms.nil?
            next unless conforms
            disjoint_match = false
            if model.qualified_disjoint
              siblings.each do |sibling|
                sibling_conforms = conforms?(sibling, value)
                return nil if sibling_conforms.nil?
                disjoint_match ||= sibling_conforms
              end
            end
            count += 1 unless disjoint_match
          end

          if model.qualified_min_count && count < model.qualified_min_count
            findings << result(focus, model.path.result_path, nil, model, :qualifiedMinCount,
                               qualified_value_shape: qualified_shape.id,
                               expected: model.qualified_min_count, actual: count)
          end
          if model.qualified_max_count && count > model.qualified_max_count
            findings << result(focus, model.path.result_path, nil, model, :qualifiedMaxCount,
                               qualified_value_shape: qualified_shape.id,
                               expected: model.qualified_max_count, actual: count)
          end
        end
        findings
      end

      def conforms?(shape, value)
        validate_shape(shape, value) == []
      end

      def positive_cycle_result
        []
      end

      def negative_cycle_result(model, focus, result_path)
        key = [model.id, focus, result_path]
        unless @fatal_seen.include?(key)
          @fatal_seen << key
          @fatal_results << FatalResult.new(
            focus_node: focus,
            result_path: result_path,
            value: focus,
            source_shape: model.id,
            source_constraint: :unsupportedRecursion,
            constraint_parameter: {
              strategy: 'positive cycles conform; negated recursion is unsupported'
            }
          )
        end
        [FatalResult.new]
      end

      def result(focus, path, value, model, constraint, parameter = {})
        detail = parameter.delete(:detail) || []
        Result.new(
          focus_node: focus,
          result_path: path,
          value: value,
          source_shape: model.id,
          source_constraint: constraint,
          constraint_parameter: parameter,
          detail: detail
        )
      end

      def result_key(result)
        [
          result.focus_node,
          result.result_path,
          result.value,
          result.source_shape,
          result.source_constraint,
          result.constraint_parameter
        ]
      end

      def list(head)
        Path.list(@shape_graph, head)
      end

      def integer(term)
        value = term.respond_to?(:object) ? term.object : term
        raise MalformedShapeError, "expected integer, got #{term.inspect}" unless value.is_a?(Integer)

        value
      end

      def true?(term)
        (term.respond_to?(:object) && term.object == true) || term == RDF::Literal(true)
      end
    end
  end
end
