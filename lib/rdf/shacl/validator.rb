require 'rdf/shacl'

module RDF
  module SHACL
    ##
    # Validates a data graph against a shapes graph using a practical
    # subset of SHACL Core. See RDF::SHACL for the feature list and the
    # recursion strategy.
    #
    # @example
    #   validator = RDF::SHACL::Validator.new(shapes: shapes_graph, data: data_graph)
    #   report    = validator.validate
    class Validator
      # @return [RDF::Queryable] the shapes graph
      attr_reader :shapes_graph

      # @return [RDF::Queryable] the data graph
      attr_reader :data_graph

      ##
      # @param  [RDF::Queryable] shapes the shapes graph
      # @param  [RDF::Queryable] data   the data graph
      def initialize(shapes:, data:)
        @shapes_graph = shapes
        @data_graph   = data
      end

      ##
      # Validates the data graph against every shape in the shapes
      # graph that has targets.
      #
      # @return [RDF::SHACL::ValidationReport]
      def validate
        report = ValidationReport.new
        shape_nodes.each do |shape|
          next if deactivated?(shape)
          targets_for(shape).each do |focus|
            validate_against_shape(focus, shape, [], report)
          end
        end
        report
      end

      private

      ##
      # All subjects in the shapes graph that are shapes: typed
      # sh:NodeShape / sh:PropertyShape, or carrying a target or a path.
      #
      # @return [Array<RDF::Resource>]
      def shape_nodes
        shapes = []
        shapes.concat(shapes_graph.query({predicate: RDF.type, object: SHACL[:NodeShape]}).subjects)
        shapes.concat(shapes_graph.query({predicate: RDF.type, object: SHACL[:PropertyShape]}).subjects)
        [SHACL[:targetClass], SHACL[:targetNode], SHACL[:path]].each do |predicate|
          shapes.concat(shapes_graph.query({predicate: predicate}).subjects)
        end
        shapes.uniq
      end

      ##
      # The focus nodes targeted by +shape+: sh:targetNode objects plus
      # all instances of each sh:targetClass.
      #
      # @param  [RDF::Resource] shape
      # @return [Array<RDF::Resource>]
      def targets_for(shape)
        targets = []
        shapes_graph.query({subject: shape, predicate: SHACL[:targetNode]}).each_object do |node|
          targets << node if node.is_a?(RDF::Resource)
        end
        shapes_graph.query({subject: shape, predicate: SHACL[:targetClass]}).each_object do |klass|
          ([klass] + all_subclasses(klass)).each do |type|
            targets.concat(data_graph.query({predicate: RDF.type, object: type}).subjects)
          end
        end
        targets.uniq
      end

      ##
      # Validates +focus+ against +shape+, dispatching to node-level
      # constraints and nested sh:property shapes.
      #
      # Recursion guard: +stack+ holds the [shape, focus_node] pairs
      # currently being validated. Re-entering a pair is treated as
      # conforming (see RDF::SHACL), so recursive shapes terminate.
      #
      # @param  [RDF::Term]     focus
      # @param  [RDF::Resource] shape
      # @param  [Array<Array(RDF::Resource, RDF::Term)>] stack
      # @param  [RDF::SHACL::ValidationReport] report
      # @return [void]
      def validate_against_shape(focus, shape, stack, report)
        return if stack.include?([shape, focus])
        stack.push([shape, focus])
        begin
          validate_value_constraints(focus, shape, [focus], nil, stack, report)
          shapes_graph.query({subject: shape, predicate: SHACL[:property]}).each_object do |property_shape|
            validate_property_shape(focus, property_shape, stack, report)
          end
        ensure
          stack.pop
        end
      end

      ##
      # Validates +focus+ against a property shape: evaluates its
      # sh:path in the data graph and checks cardinality, value and
      # qualified-value-shape constraints over the resulting values.
      #
      # @return [void]
      def validate_property_shape(focus, property_shape, stack, report)
        return if deactivated?(property_shape)
        path_node = shapes_graph.first_object(subject: property_shape, predicate: SHACL[:path])
        return unless path_node
        path   = Path.parse(path_node, shapes_graph)
        values = path.evaluate(focus, data_graph)

        if (min = integer_parameter(property_shape, SHACL[:minCount])) && values.length < min
          add_result(report, focus: focus, shape: property_shape,
            component: :MinCountConstraintComponent, path: path_node,
            default_message: "Less than #{min} values on #{focus}-#{path_node}")
        end
        if (max = integer_parameter(property_shape, SHACL[:maxCount])) && values.length > max
          add_result(report, focus: focus, shape: property_shape,
            component: :MaxCountConstraintComponent, path: path_node,
            default_message: "More than #{max} values on #{focus}-#{path_node}")
        end

        validate_value_constraints(focus, property_shape, values, path_node, stack, report)
        validate_qualified_value_shapes(focus, property_shape, values, path_node, stack, report)
      end

      ##
      # Checks the per-value constraints attached to +shape+ (either a
      # node shape, where +values+ is [focus], or a property shape,
      # where +values+ are the path values): sh:datatype, sh:class,
      # sh:node, sh:not, sh:and, sh:or and sh:xone.
      #
      # @return [void]
      def validate_value_constraints(focus, shape, values, path_node, stack, report)
        shapes_graph.query({subject: shape, predicate: SHACL[:datatype]}).each_object do |datatype|
          values.each do |value|
            next if value.is_a?(RDF::Literal) && value.datatype == datatype
            add_result(report, focus: focus, shape: shape,
              component: :DatatypeConstraintComponent, path: path_node, value: value,
              default_message: "Value does not have datatype #{datatype}")
          end
        end

        shapes_graph.query({subject: shape, predicate: SHACL[:class]}).each_object do |klass|
          values.each do |value|
            next if instance_of?(value, klass)
            add_result(report, focus: focus, shape: shape,
              component: :ClassConstraintComponent, path: path_node, value: value,
              default_message: "Value is not an instance of #{klass}")
          end
        end

        shapes_graph.query({subject: shape, predicate: SHACL[:node]}).each_object do |node_shape|
          values.each do |value|
            next if conforms?(value, node_shape, stack)
            add_result(report, focus: focus, shape: shape,
              component: :NodeConstraintComponent, path: path_node, value: value,
              default_message: "Value does not conform to #{node_shape.to_ntriples}")
          end
        end

        shapes_graph.query({subject: shape, predicate: SHACL[:not]}).each_object do |negated|
          values.each do |value|
            next unless conforms?(value, negated, stack)
            add_result(report, focus: focus, shape: shape,
              component: :NotConstraintComponent, path: path_node, value: value,
              default_message: "Value conforms to #{negated.to_ntriples}")
          end
        end

        shapes_graph.query({subject: shape, predicate: SHACL[:and]}).each_object do |list|
          members = Path.list_members(list, shapes_graph)
          values.each do |value|
            next if members.all? { |member| conforms?(value, member, stack) }
            add_result(report, focus: focus, shape: shape,
              component: :AndConstraintComponent, path: path_node, value: value,
              default_message: "Value does not conform to all shapes in #{list.to_ntriples}")
          end
        end

        shapes_graph.query({subject: shape, predicate: SHACL[:or]}).each_object do |list|
          members = Path.list_members(list, shapes_graph)
          values.each do |value|
            next if members.any? { |member| conforms?(value, member, stack) }
            add_result(report, focus: focus, shape: shape,
              component: :OrConstraintComponent, path: path_node, value: value,
              default_message: "Value does not conform to any shape in #{list.to_ntriples}")
          end
        end

        shapes_graph.query({subject: shape, predicate: SHACL[:xone]}).each_object do |list|
          members = Path.list_members(list, shapes_graph)
          values.each do |value|
            next if members.count { |member| conforms?(value, member, stack) } == 1
            add_result(report, focus: focus, shape: shape,
              component: :XoneConstraintComponent, path: path_node, value: value,
              default_message: "Value does not conform to exactly one shape in #{list.to_ntriples}")
          end
        end
      end

      ##
      # Checks sh:qualifiedValueShape with sh:qualifiedMinCount /
      # sh:qualifiedMaxCount. Unlike sh:minCount / sh:maxCount, which
      # count all values of the property, qualified counts only tally
      # the values that conform to the qualified shape, so a minimum
      # can be required for a specific kind of value. With
      # sh:qualifiedValueShapesDisjoint true, a value conforming to a
      # sibling qualified shape is not tallied here.
      #
      # @return [void]
      def validate_qualified_value_shapes(focus, shape, values, path_node, stack, report)
        qualified_shapes = shapes_graph.query({subject: shape, predicate: SHACL[:qualifiedValueShape]}).objects
        return if qualified_shapes.empty?
        disjoint = boolean_parameter(shape, SHACL[:qualifiedValueShapesDisjoint])

        qualified_shapes.each do |qualified|
          count = values.count do |value|
            next false unless conforms?(value, qualified, stack)
            !(disjoint && qualified_shapes.any? { |sibling| sibling != qualified && conforms?(value, sibling, stack) })
          end

          if (min = integer_parameter(shape, SHACL[:qualifiedMinCount])) && count < min
            add_result(report, focus: focus, shape: shape,
              component: :QualifiedMinCountConstraintComponent, path: path_node,
              default_message: "Less than #{min} values conforming to #{qualified.to_ntriples}")
          end
          if (max = integer_parameter(shape, SHACL[:qualifiedMaxCount])) && count > max
            add_result(report, focus: focus, shape: shape,
              component: :QualifiedMaxCountConstraintComponent, path: path_node,
              default_message: "More than #{max} values conforming to #{qualified.to_ntriples}")
          end
        end
      end

      ##
      # Whether +value+ conforms to +shape+ without polluting the main
      # report. Shares the recursion stack, so a [shape, value] pair
      # already being validated counts as conforming.
      #
      # @return [Boolean]
      def conforms?(value, shape, stack)
        sub_report = ValidationReport.new
        validate_against_shape(value, shape, stack, sub_report)
        sub_report.results.none? { |result| result.severity == SHACL[:Violation] }
      end

      ##
      # Whether +node+ is an instance of +klass+ in the data graph,
      # i.e. has rdf:type +klass+ or one of its rdfs:subClassOf
      # descendants.
      #
      # @return [Boolean]
      def instance_of?(node, klass)
        return false unless node.is_a?(RDF::Resource)
        data_graph.query({subject: node, predicate: RDF.type}).objects.any? do |type|
          type == klass || subclass_of?(type, klass)
        end
      end

      ##
      # Whether +sub+ is a transitive rdfs:subClassOf descendant of
      # +klass+ in the data graph.
      #
      # @return [Boolean]
      def subclass_of?(sub, klass)
        all_subclasses(klass).include?(sub)
      end

      ##
      # All transitive rdfs:subClassOf descendants of +klass+ asserted
      # in the data graph.
      #
      # @return [Array<RDF::Resource>]
      def all_subclasses(klass)
        descendants = []
        seen        = {}
        queue       = [klass]
        until queue.empty?
          current = queue.shift
          next if seen[current]
          seen[current] = true
          data_graph.query({predicate: RDF::RDFS.subClassOf, object: current}).each_subject do |sub|
            descendants << sub
            queue       << sub
          end
        end
        descendants
      end

      ##
      # @return [Integer, nil]
      def integer_parameter(shape, predicate)
        value = shapes_graph.first_object(subject: shape, predicate: predicate)
        value.is_a?(RDF::Literal) ? value.to_i : nil
      end

      ##
      # @return [Boolean]
      def boolean_parameter(shape, predicate)
        shapes_graph.first_object(subject: shape, predicate: predicate) == RDF::Literal::TRUE
      end

      ##
      # @return [Boolean]
      def deactivated?(shape)
        boolean_parameter(shape, SHACL[:deactivated])
      end

      ##
      # Records a validation result, honoring sh:severity and
      # sh:message on the source shape.
      #
      # @return [void]
      def add_result(report, focus:, shape:, component:, path: nil, value: nil, default_message: nil)
        severity = shapes_graph.first_object(subject: shape, predicate: SHACL[:severity]) || SHACL[:Violation]
        message  = shapes_graph.first_object(subject: shape, predicate: SHACL[:message])
        report.add(ValidationResult.new(
          focus_node: focus,
          path: path,
          value: value,
          source_shape: shape,
          source_constraint_component: SHACL[component],
          severity: severity,
          message: (message.to_s if message) || default_message))
      end
    end # Validator
  end # SHACL
end # RDF
