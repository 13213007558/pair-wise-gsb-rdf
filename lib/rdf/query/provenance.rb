module RDF; class Query
  ##
  # Provenance expressions for positive basic graph patterns.
  #
  # A matched statement contributes a symbolic {Variable}. Join inputs are
  # combined with multiplication, while alternative derivations are combined
  # with addition. Expressions are represented as a DAG, so repeated joins do
  # not copy or expand their shared prefixes.
  module Provenance
    ##
    # @return [One] the multiplicative identity
    def self.one
      ONE
    end

    ##
    # Shared builder used while evaluating one query.
    class Builder
      def initialize
        @variables = {}
        @products = {}
        @sums = {}
      end

      ##
      # @param [RDF::Statement] statement
      # @return [Variable]
      def variable(statement)
        statement = RDF::Statement.from(statement) unless statement.is_a?(RDF::Statement)
        @variables[statement] ||= Variable.new(statement)
      end

      ##
      # @param [Expression, One, nil] left
      # @param [Expression, One, nil] right
      # @return [Expression, One, Product]
      def product(left, right)
        left ||= ONE
        right ||= ONE
        return right if left.is_a?(One)
        return left if right.is_a?(One)

        cached(@products, Product, left, right)
      end

      ##
      # @param [Expression, One] left
      # @param [Expression, One] right
      # @return [Expression, Sum]
      def sum(left, right)
        return right if left.nil?
        return left if right.nil?

        cached(@sums, Sum, left, right)
      end

      private

      def cached(cache, klass, left, right)
        operands = [left, right].sort_by(&:__id__)
        cache[operands] ||= klass.new(operands.first, operands.last)
      end
    end

    ##
    # Abstract provenance expression.
    class Expression
      ##
      # @return [Expression, Product]
      def *(other)
        Product.new(self, other)
      end

      ##
      # @return [Expression, Sum]
      def +(other)
        Sum.new(self, other)
      end

      ##
      # @return [Array<RDF::Statement>] distinct input statements in the DAG
      def statements
        collect_statements({}).keys
      end

      ##
      # Substitutes statement symbols with values and evaluates the DAG.
      #
      # Integer-like values use addition and multiplication. Boolean values
      # use logical OR and AND. A block, callable, or Hash maps each matched
      # {RDF::Statement} to its value.
      #
      # @param [Hash, #call] assignments
      # @param [Object] one multiplicative identity for a positive empty pattern
      # @yield [statement]
      # @yieldparam [RDF::Statement] statement
      # @return [Object]
      def evaluate(assignments = nil, one: nil, &block)
        Evaluator.new(assignments, one, &block).evaluate(self)
      end

      # @private
      def collect_statements(_statements)
        raise NotImplementedError
      end

      # @private
      def evaluate_with(_evaluator)
        raise NotImplementedError
      end
    end

    ##
    # The multiplicative identity.
    class One < Expression
      def initialize
        freeze
      end

      def *(other)
        other
      end

      def collect_statements(statements)
        statements
      end

      def evaluate_with(evaluator)
        evaluator.identity
      end

      def to_s
        "1"
      end
      alias_method :inspect, :to_s
    end

    ##
    # A symbolic input statement.
    class Variable < Expression
      # @return [RDF::Statement]
      attr_reader :statement

      # @private
      def initialize(statement)
        @statement = statement
        freeze
      end

      def collect_statements(statements)
        statements[@statement] = true
        statements
      end

      def evaluate_with(evaluator)
        evaluator.value(@statement)
      end

      def to_s
        statement.to_s
      end
      alias_method :inspect, :to_s
    end

    ##
    # Provenance for a join.
    class Product < Expression
      # @return [Expression, One]
      attr_reader :left, :right

      # @private
      def initialize(left, right)
        @left = left
        @right = right
        freeze
      end

      def collect_statements(statements)
        left.collect_statements(statements)
        right.collect_statements(statements)
        statements
      end

      def evaluate_with(evaluator)
        evaluator.product(evaluator.evaluate(left), evaluator.evaluate(right))
      end

      def to_s
        "(#{left} * #{right})"
      end
      alias_method :inspect, :to_s
    end

    ##
    # Provenance for alternative derivations.
    class Sum < Expression
      # @return [Expression, One]
      attr_reader :left, :right

      # @private
      def initialize(left, right)
        @left = left
        @right = right
        freeze
      end

      def collect_statements(statements)
        left.collect_statements(statements)
        right.collect_statements(statements)
        statements
      end

      def evaluate_with(evaluator)
        evaluator.sum(evaluator.evaluate(left), evaluator.evaluate(right))
      end

      def to_s
        "(#{left} + #{right})"
      end
      alias_method :inspect, :to_s
    end

    # @private
    class Evaluator
      def initialize(assignments, one, &block)
        @assignments = assignments
        @one = one
        @block = block
        @memo = {}
        @values = {}
        @modes = []
      end

      def evaluate(expression)
        if expression.is_a?(One)
          identity
        else
          expression.statements.each { |statement| resolve(statement) }
          modes = @modes.uniq
          if modes.length > 1
            raise ArgumentError, "provenance values must all be booleans or all support + and *"
          end
          @mode = modes.first
          @memo[expression] ||= expression.evaluate_with(self)
        end
      end

      def value(statement)
        @values[statement] ||= resolve(statement)
      end

      def identity
        @one || (resolved_boolean? ? true : 1)
      end

      def sum(left, right)
        check_boolean!(left, right)
        if resolved_boolean?
          left | right
        else
          left + right
        end
      end

      def product(left, right)
        check_boolean!(left, right)
        if resolved_boolean?
          left & right
        else
          left * right
        end
      end

      private

      def resolved_boolean?
        @mode.nil? || @mode == :boolean
      end

      def check_boolean!(*values)
        booleans = values.map { |value| value.equal?(true) || value.equal?(false) }
        if booleans.any? && !booleans.all?
          raise ArgumentError, "provenance values must all be booleans or all support + and *"
        end
      end

      def resolve(statement)
        value = if @block
          @block.call(statement)
        elsif @assignments.respond_to?(:call)
          @assignments.call(statement)
        elsif @assignments.respond_to?(:fetch)
          @assignments.fetch(statement)
        elsif @assignments.respond_to?(:[])
          @assignments[statement]
        else
          raise ArgumentError, "missing provenance value for #{statement.inspect}"
        end

        @modes << (value.equal?(true) || value.equal?(false) ? :boolean : :numeric)
        value
      end
    end

    ONE = One.new
  end
end; end
