module RDF; class Query
  ##
  # Provenance tracking for basic graph pattern (BGP) query results.
  #
  # When a query is executed with the `provenance` option, each solution
  # is annotated with a provenance expression recording which input
  # statements were used to derive it:
  #
  # * Every matched statement contributes an {Atom}, identified by a
  #   symbol (by default, the statement itself).
  # * Statements joined across patterns combine by multiplication
  #   ({Product}).
  # * Alternative derivations yielding the same solution bindings combine
  #   by addition ({Sum}).
  #
  # Expressions form a directed acyclic graph (DAG) with structural
  # sharing: nodes created through {.atom}, {.sum}, and {.product} are
  # interned, so identical sub-expressions are shared rather than
  # duplicated, and expressions are never expanded into a normal form.
  # This keeps expressions compact even when the number of derivations
  # grows exponentially. Note that expressions are intentionally _not_
  # simplified: using the same fact twice in a self-join yields a square
  # term (`s * s`), and duplicate derivations are preserved under
  # addition, so that evaluation can count derivations faithfully.
  #
  # An expression is evaluated by substituting values for its symbols,
  # for example statement counts or booleans:
  #
  # @example Computing the provenance of query solutions
  #   query = RDF::Query.new { pattern [:s, RDF::URI("p"), :o] }
  #   query.execute(graph, provenance: true).each do |solution|
  #     puts solution.provenance
  #   end
  #
  # @example Evaluating a provenance expression with counts
  #   expr.evaluate({stmt1 => 1, stmt2 => 1}) #=> Integer
  #
  # @example Evaluating a provenance expression with booleans
  #   expr.evaluate_boolean({stmt1 => true, stmt2 => false}) #=> true or false
  #
  # @see RDF::Query#execute
  # @see RDF::Query::Solution#provenance
  module Provenance
    # Default semiring operations: numeric addition and multiplication,
    # suitable for counting derivations.
    DEFAULT_ADD = ->(a, b) { a + b }
    DEFAULT_MUL = ->(a, b) { a * b }

    # Boolean semiring operations, suitable for reachability checks.
    BOOLEAN_ADD = ->(a, b) { a | b }
    BOOLEAN_MUL = ->(a, b) { a & b }

    @atoms    = {}
    @sums     = {}
    @products = {}

    class << self
      ##
      # Returns the (shared) atom for the given symbol.
      #
      # @param  [Object] symbol
      #   anything identifying an input statement; a statement itself by
      #   default
      # @return [Atom]
      def atom(symbol)
        @atoms[symbol] ||= Atom.new(symbol)
      end

      ##
      # Returns the (shared) sum of the given terms, flattening nested
      # sums and dropping {ZERO}. Returns {ZERO} without terms, and the
      # term itself when given a single term.
      #
      # @param  [Array<Node>] terms
      # @return [Node]
      def sum(*terms)
        terms = terms.flat_map {|term| term.is_a?(Sum) ? term.terms : [term]}
        return zero if terms.empty?
        return terms.first if terms.size == 1
        @sums[terms.freeze] ||= Sum.new(terms)
      end

      ##
      # Returns the (shared) product of the given factors, flattening
      # nested products and dropping {ONE}. Returns {ONE} without
      # factors, and the factor itself when given a single factor.
      #
      # @param  [Array<Node>] factors
      # @return [Node]
      def product(*factors)
        factors = factors.flat_map {|factor| factor.is_a?(Product) ? factor.factors : [factor]}
        return one if factors.empty?
        return factors.first if factors.size == 1
        @products[factors.freeze] ||= Product.new(factors)
      end

      ##
      # The multiplicative identity: the provenance of a solution derived
      # without using any statements.
      #
      # @return [Product]
      def one
        @one ||= Product.new([].freeze)
      end

      ##
      # The additive identity: the provenance of a solution with no
      # derivations.
      #
      # @return [Sum]
      def zero
        @zero ||= Sum.new([].freeze)
      end
    end

    ##
    # Base class for provenance expression nodes.
    class Node
      ##
      # Combines this expression with `other` as alternative derivations.
      #
      # @param  [Node] other
      # @return [Node]
      def +(other)
        Provenance.sum(self, other)
      end

      ##
      # Combines this expression with `other` as joined derivations.
      #
      # @param  [Node] other
      # @return [Node]
      def *(other)
        Provenance.product(self, other)
      end

      ##
      # Is this the additive identity?
      #
      # @return [Boolean]
      def zero?
        false
      end

      ##
      # Is this the multiplicative identity?
      #
      # @return [Boolean]
      def one?
        false
      end

      ##
      # Evaluates this expression by substituting a value for every
      # symbol, combining them with the given semiring operations.
      #
      # Sub-expressions are evaluated only once, no matter how often they
      # are shared within the expression.
      #
      # @param  [Hash{Object => Object}, #call] env
      #   maps each symbol to its value; either a `Hash` (missing symbols
      #   raise `KeyError`) or a callable invoked with each symbol
      # @param  [#call] add
      #   combines alternative derivations
      # @param  [#call] mul
      #   combines joined derivations
      # @param  [Object] one
      #   value of an empty product
      # @param  [Object] zero
      #   value of an empty sum
      # @return [Object]
      def evaluate(env = {}, add: DEFAULT_ADD, mul: DEFAULT_MUL, one: 1, zero: 0)
        evaluate_node(env, {}, add, mul, one, zero)
      end

      ##
      # Evaluates this expression in the boolean semiring.
      #
      # @param  [Hash{Object => Boolean}, #call] env
      # @return [Boolean]
      # @see    #evaluate
      def evaluate_boolean(env = {})
        evaluate(env, add: BOOLEAN_ADD, mul: BOOLEAN_MUL, one: true, zero: false)
      end

      ##
      # The symbols used by this expression.
      #
      # @return [Array<Object>]
      def symbols
        symbols, seen = [], {}
        queue = [self]
        until queue.empty?
          node = queue.shift
          next if seen[node]
          seen[node] = true
          case node
          when Atom    then symbols << node.symbol
          when Sum     then queue.concat(node.terms)
          when Product then queue.concat(node.factors)
          end
        end
        symbols
      end

      ##
      # @return [String]
      def inspect
        sprintf("#<%s %s>", self.class.name, self)
      end
    end

    ##
    # A provenance atom: the use of a single input statement.
    class Atom < Node
      # The symbol identifying the input statement.
      #
      # @return [Object]
      attr_reader :symbol

      ##
      # @param  [Object] symbol
      def initialize(symbol)
        @symbol = symbol
      end

      ##
      # (see Node#evaluate)
      def evaluate_node(env, memo, add, mul, one, zero)
        return memo[self] if memo.key?(self)
        memo[self] = env.respond_to?(:call) ? env.call(symbol) : env.fetch(symbol)
      end

      ##
      # @return [Boolean]
      def ==(other)
        other.is_a?(Atom) && symbol.eql?(other.symbol)
      end
      alias_method :eql?, :==

      ##
      # @return [Integer]
      def hash
        [self.class, symbol].hash
      end

      ##
      # @return [String]
      def to_s
        symbol.to_s
      end
    end

    ##
    # A provenance sum: alternative derivations of the same result.
    class Sum < Node
      # The alternative derivations.
      #
      # @return [Array<Node>]
      attr_reader :terms

      ##
      # @param  [Array<Node>] terms
      def initialize(terms)
        @terms = terms
      end

      ##
      # (see Node#zero?)
      def zero?
        terms.empty?
      end

      ##
      # (see Node#evaluate)
      def evaluate_node(env, memo, add, mul, one, zero)
        return memo[self] if memo.key?(self)
        memo[self] = terms.map {|term| term.evaluate_node(env, memo, add, mul, one, zero)}.reduce(zero, &add)
      end

      ##
      # @return [Boolean]
      def ==(other)
        other.is_a?(Sum) && terms == other.terms
      end
      alias_method :eql?, :==

      ##
      # @return [Integer]
      def hash
        [self.class, terms].hash
      end

      ##
      # @return [String]
      def to_s
        terms.empty? ? "0" : terms.map(&:to_s).join(" + ")
      end
    end

    ##
    # A provenance product: statements joined to derive a result.
    class Product < Node
      # The joined derivations.
      #
      # @return [Array<Node>]
      attr_reader :factors

      ##
      # @param  [Array<Node>] factors
      def initialize(factors)
        @factors = factors
      end

      ##
      # (see Node#one?)
      def one?
        factors.empty?
      end

      ##
      # (see Node#evaluate)
      def evaluate_node(env, memo, add, mul, one, zero)
        return memo[self] if memo.key?(self)
        memo[self] = factors.map {|factor| factor.evaluate_node(env, memo, add, mul, one, zero)}.reduce(one, &mul)
      end

      ##
      # @return [Boolean]
      def ==(other)
        other.is_a?(Product) && factors == other.factors
      end
      alias_method :eql?, :==

      ##
      # @return [Integer]
      def hash
        [self.class, factors].hash
      end

      ##
      # @return [String]
      def to_s
        factors.empty? ? "1" : factors.map {|factor| factor.is_a?(Sum) && !factor.zero? ? "(#{factor})" : factor.to_s}.join(" * ")
      end
    end
  end # Provenance
end; end # RDF::Query
