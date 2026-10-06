require 'rdf/shacl'

module RDF
  module SHACL
    ##
    # A single SHACL validation result. Every result records the focus
    # node, the result path (for property-shape violations), the
    # offending value (when there is one), the shape and the constraint
    # component that produced it, plus severity and message.
    class ValidationResult
      # @return [RDF::Term] the focus node (sh:focusNode)
      attr_reader :focus_node

      # @return [RDF::Resource, nil] the result path (sh:resultPath);
      #   the predicate IRI for predicate paths, the path blank node
      #   otherwise, nil for node-shape violations
      attr_reader :path

      # @return [RDF::Term, nil] the offending value (sh:value), if any
      attr_reader :value

      # @return [RDF::Resource] the shape that was violated (sh:sourceShape)
      attr_reader :source_shape

      # @return [RDF::URI] the constraint component
      #   (sh:sourceConstraintComponent), e.g. sh:MinCountConstraintComponent
      attr_reader :source_constraint_component

      # @return [RDF::URI] sh:Violation, sh:Warning or sh:Info
      attr_reader :severity

      # @return [String] a human-readable message (sh:resultMessage)
      attr_reader :message

      def initialize(focus_node:, source_shape:, source_constraint_component:,
                     path: nil, value: nil,
                     severity: SHACL[:Violation], message: nil)
        @focus_node                  = focus_node
        @path                        = path
        @value                       = value
        @source_shape                = source_shape
        @source_constraint_component = source_constraint_component
        @severity                    = severity
        @message                     = message
      end

      ##
      # @return [String]
      def to_s
        parts = ["[#{severity.to_s.split('#').last}] #{source_constraint_component.to_s.split('#').last}"]
        parts << "focus=#{focus_node.to_ntriples}"
        parts << "path=#{path.to_ntriples}" if path
        parts << "value=#{value.to_ntriples}" if value
        parts << "message=#{message.inspect}" if message
        parts.join(' ')
      end

      ##
      # Serializes this result as sh:ValidationResult statements
      # attached to +report_node+.
      #
      # @param  [RDF::Resource] report_node
      # @return [Array<RDF::Statement>]
      def to_statements(report_node)
        result_node = RDF::Node.new
        statements  = []
        statements << RDF::Statement(report_node, SHACL[:result], result_node)
        statements << RDF::Statement(result_node, RDF.type, SHACL[:ValidationResult])
        statements << RDF::Statement(result_node, SHACL[:focusNode], focus_node)
        statements << RDF::Statement(result_node, SHACL[:resultPath], path) if path
        statements << RDF::Statement(result_node, SHACL[:value], value) if value
        statements << RDF::Statement(result_node, SHACL[:sourceShape], source_shape)
        statements << RDF::Statement(result_node, SHACL[:sourceConstraintComponent], source_constraint_component)
        statements << RDF::Statement(result_node, SHACL[:resultSeverity], severity)
        statements << RDF::Statement(result_node, SHACL[:resultMessage], RDF::Literal(message)) if message
        statements
      end
    end # ValidationResult

    ##
    # The outcome of validating a data graph against a shapes graph.
    class ValidationReport
      include RDF::Enumerable

      # @return [Array<RDF::SHACL::ValidationResult>]
      attr_reader :results

      def initialize
        @results = []
      end

      ##
      # Adds a validation result to the report.
      #
      # @param  [RDF::SHACL::ValidationResult] result
      # @return [void]
      def add(result)
        results << result
      end

      ##
      # The data graph conforms when no result has severity sh:Violation.
      #
      # @return [Boolean]
      def conforms?
        results.none? { |result| result.severity == SHACL[:Violation] }
      end

      ##
      # Iterates over the report as RDF statements (sh:ValidationReport).
      def each(&block)
        return to_enum(__method__) unless block_given?
        to_graph.each_statement(&block)
      end

      ##
      # @return [RDF::Graph] this report as a SHACL validation report graph
      def to_graph
        report_node = RDF::Node.new
        graph       = RDF::Graph.new
        graph << RDF::Statement(report_node, RDF.type, SHACL[:ValidationReport])
        graph << RDF::Statement(report_node, SHACL[:conforms], RDF::Literal(conforms?))
        results.each do |result|
          result.to_statements(report_node).each { |statement| graph << statement }
        end
        graph
      end
    end # ValidationReport
  end # SHACL
end # RDF
