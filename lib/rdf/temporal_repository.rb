module RDF
  ##
  # An in-memory RDF repository that records the valid time of each quad.
  #
  # Every quad is associated with a set of half-open valid-time intervals
  # [start, finish). Time points are arbitrary comparable values
  # (integers, Time, DateTime, ...); no wall clock is involved, so logical
  # timestamps work equally well.
  #
  # @example Recording and querying valid time
  #   repository = RDF::TemporalRepository.new
  #   repository.insert(statement, interval: [0, 10])  # valid during [0, 10)
  #   repository.valid_at(5)        #=> [statement]
  #   repository.valid_at(10)       #=> [] (half-open interval)
  #   repository.delete(statement, interval: [3, 6])   # splits into [0,3), [6,10)
  #
  # @example Temporal basic graph pattern join
  #   query = RDF::Query.new do
  #     pattern [:s, RDF::URI('http://example.org/p'), :o]
  #   end
  #   repository.query(query).first.interval  #=> [0, 10)
  #
  # Intervals of the same quad are normalized: overlapping or adjacent
  # intervals are merged, and retracting an interval may split existing
  # ones. When several patterns are joined, the resulting solutions carry
  # the *intersection* of the valid intervals of all matched statements;
  # solutions whose common valid time is empty are not produced.
  class TemporalRepository < Repository
    ##
    # A half-open valid-time interval [start, finish).
    #
    # A nil start denotes negative infinity and a nil finish denotes
    # positive infinity, so Interval.new(nil, nil) is valid for all time.
    class Interval
      include Comparable

      # @return [Object, nil] the inclusive lower bound
      attr_reader :start

      # @return [Object, nil] the exclusive upper bound
      attr_reader :finish

      ##
      # Coerces a value to an Interval. Accepts an Interval, a two element
      # [start, finish] Array, or a Range (always interpreted as half-open,
      # using its begin and end).
      #
      # @param  [Interval, Array, Range] value
      # @return [Interval]
      def self.from(value)
        case value
        when Interval then value
        when Range    then new(value.begin, value.end)
        when Array    then new(value[0], value[1])
        else raise ArgumentError, "invalid interval: #{value.inspect}"
        end
      end

      ##
      # @param  [Object, nil] start   inclusive lower bound, nil for -inf
      # @param  [Object, nil] finish  exclusive upper bound, nil for +inf
      # @raise  [ArgumentError] if the interval would be empty
      def initialize(start, finish)
        if !start.nil? && !finish.nil? && finish <= start
          raise ArgumentError,
            "interval finish must be greater than start: [#{start}, #{finish})"
        end
        @start  = start
        @finish = finish
      end

      ##
      # The interval valid for all time.
      ETERNAL = new(nil, nil).freeze

      ##
      # @return [Boolean] true if this interval is unbounded on both sides
      def eternal?
        @start.nil? && @finish.nil?
      end

      ##
      # @param  [Object] time
      # @return [Boolean] true if time lies within [start, finish)
      def contains?(time)
        (@start.nil? || @start <= time) && (@finish.nil? || time < @finish)
      end

      ##
      # @param  [Interval] other
      # @return [Boolean] true if both intervals share at least one point
      def overlaps?(other)
        before = !@finish.nil? && !other.start.nil? && @finish <= other.start
        after  = !other.finish.nil? && !@start.nil? && other.finish <= @start
        !(before || after)
      end

      ##
      # @param  [Interval] other
      # @return [Boolean] true if the intervals touch without overlapping
      def adjacent?(other)
        (!@finish.nil? && @finish.eql?(other.start)) ||
          (!other.finish.nil? && other.finish.eql?(@start))
      end

      ##
      # @param  [Interval] other
      # @return [Interval, nil] the intersection, or nil if empty
      def intersect(other)
        start  = @start.nil?  ? other.start  : (other.start.nil?  ? @start  : [@start, other.start].max)
        finish = @finish.nil? ? other.finish : (other.finish.nil? ? @finish : [@finish, other.finish].min)
        return nil if !start.nil? && !finish.nil? && finish <= start
        Interval.new(start, finish)
      end

      ##
      # Merges two overlapping or adjacent intervals.
      #
      # @param  [Interval] other
      # @return [Interval]
      def merge(other)
        start  = @start.nil?  || other.start.nil?  ? nil : [@start, other.start].min
        finish = @finish.nil? || other.finish.nil? ? nil : [@finish, other.finish].max
        Interval.new(start, finish)
      end

      ##
      # Subtracts other from this interval.
      #
      # @param  [Interval] other
      # @return [Array<Interval>] zero, one, or two remaining intervals
      def subtract(other)
        return [self] unless overlaps?(other)
        parts = []
        if !other.start.nil? && (@start.nil? || @start < other.start)
          parts << Interval.new(@start, other.start)
        end
        if !other.finish.nil? && (@finish.nil? || other.finish < @finish)
          parts << Interval.new(other.finish, @finish)
        end
        parts
      end

      ##
      # Orders intervals by start (negative infinity first), then by finish
      # (positive infinity last).
      def <=>(other)
        cmp = compare_bounds(@start, other.start, nil_is_low: true)
        cmp.zero? ? compare_bounds(@finish, other.finish, nil_is_low: false) : cmp
      end

      def ==(other)
        other.is_a?(Interval) && @start == other.start && @finish == other.finish
      end
      alias_method :eql?, :==

      def hash
        [@start, @finish].hash
      end

      def to_s
        "[#{@start.nil? ? '-inf' : @start}, #{@finish.nil? ? '+inf' : @finish})"
      end
      alias_method :inspect, :to_s

      private

      def compare_bounds(a, b, nil_is_low:)
        return 0 if a.nil? && b.nil?
        return (nil_is_low ? -1 : 1) if a.nil?
        return (nil_is_low ? 1 : -1) if b.nil?
        a <=> b
      end
    end # Interval

    ##
    # An RDF::Query::Solution carrying the common valid-time interval of
    # the statements matched by a basic graph pattern.
    class TemporalSolution < RDF::Query::Solution
      # @return [Interval, nil] the common valid-time interval
      attr_accessor :interval

      def initialize(bindings = {}, interval: nil, &block)
        @interval = interval
        super(bindings, &block)
      end
    end

    ##
    # @see RDF::Repository#initialize
    def initialize(uri: nil, title: nil, **options, &block)
      @data = {}
      super
    end

    ##
    # Returns true if this repository supports the given feature.
    # Adds the :temporal feature to those of RDF::Repository.
    def supports?(feature)
      feature.to_sym == :temporal ? true : super
    end

    ##
    # Inserts statements, optionally recording a valid-time interval.
    #
    # Without an interval, behaves like RDF::Mutable#insert and the
    # statements are valid for all time. With an interval, the interval is
    # added to each statement's valid time, merging overlapping or adjacent
    # intervals.
    #
    # @param  [Array<RDF::Statement>] statements
    # @param  [Interval, Array, Range, nil] interval
    # @return [self]
    def insert(*statements, interval: nil)
      return super(*statements) if interval.nil?
      raise TypeError.new("#{self} is immutable") if immutable?

      interval = Interval.from(interval)
      coerce_statements(statements) do |value|
        each = value.respond_to?(:each_statement) ? :each_statement : :each
        value.__send__(each) { |statement| insert_interval(statement, interval) }
      end
      self
    end

    ##
    # Deletes statements, optionally retracting only a valid-time interval.
    #
    # Without an interval, behaves like RDF::Mutable#delete and removes all
    # valid time of the matched statements. With an interval, only that
    # interval is retracted; existing intervals are shrunk or split as
    # needed, and statements left without any valid time are removed.
    #
    # @param  [Array<RDF::Statement>] statements
    # @param  [Interval, Array, Range, nil] interval
    # @return [self]
    def delete(*statements, interval: nil)
      return super(*statements) if interval.nil?
      raise TypeError.new("#{self} is immutable") if immutable?

      interval = Interval.from(interval)
      coerce_statements(statements, query: true, constant: true) do |value|
        each = value.respond_to?(:each_statement) ? :each_statement : :each
        value.__send__(each) { |statement| retract_interval(statement, interval) }
      end
      self
    end

    ##
    # Returns the normalized valid-time intervals of the given statement.
    #
    # @param  [RDF::Statement, Array] statement
    # @return [Array<Interval>] sorted, disjoint intervals (frozen)
    def intervals(statement)
      (@data[quad_key(RDF::Statement.from(statement))] || []).freeze
    end

    ##
    # Enumerates the statements valid at the given point in time.
    #
    # @param  [Object] time
    # @yield  [statement]
    # @yieldparam [RDF::Statement] statement
    # @return [Enumerator<RDF::Statement>]
    def valid_at(time, &block)
      return enum_for(:valid_at, time) unless block_given?
      @data.each do |quad, intervals|
        yield statement_for(quad) if intervals.any? { |iv| iv.contains?(time) }
      end
    end

    ##
    # Enumerates the statements valid at some point within the given
    # half-open interval.
    #
    # @param  [Object, Interval, Array, Range] start
    # @param  [Object, nil] finish
    # @yield  [statement]
    # @yieldparam [RDF::Statement] statement
    # @return [Enumerator<RDF::Statement>]
    def valid_during(start, finish = nil, &block)
      interval = finish.nil? ? Interval.from(start) : Interval.new(start, finish)
      return enum_for(:valid_during, start, finish) unless block_given?
      @data.each do |quad, intervals|
        yield statement_for(quad) if intervals.any? { |iv| iv.overlaps?(interval) }
      end
    end

    ##
    # Queries self for statements or solutions matching pattern.
    #
    # Behaves like RDF::Queryable#query, with two additions:
    #
    # * When pattern is an RDF::Query (a basic graph pattern), the patterns
    #   are joined on their common valid time: each resulting
    #   TemporalSolution carries the intersection of the valid intervals of
    #   all matched statements, and solutions whose common valid time is
    #   empty are not produced. A statement valid in several disjoint
    #   intervals may contribute several solutions with the same bindings
    #   but different intervals.
    # * The optional at: (a point in time) and during: (an interval)
    #   constraints restrict matches to statements valid at that time;
    #   during: also clips the intervals used in joins.
    #
    # @param  [RDF::Query, RDF::Statement, Array, Hash] pattern
    # @param  [Object, nil] at      only match statements valid at this time
    # @param  [Interval, Array, Range, nil] during
    #   only match statements valid within this interval
    # @param  [Hash{Symbol => Object}] options
    # @yield  [statement]
    # @return [Enumerator, RDF::Query::Solutions]
    def query(pattern, at: nil, during: nil, **options, &block)
      if !pattern.is_a?(RDF::Query) && (at || during)
        statements = Array(super(pattern, **options)).select do |statement|
          temporal_match?(statement, at: at, during: during)
        end
        return block_given? ? statements.each(&block) : statements
      end
      super(pattern, at: at, during: during, **options, &block)
    end

    ##
    # @private
    # @see RDF::Enumerable#each_statement
    def each_statement(&block)
      if block_given?
        @data.each_key { |quad| yield statement_for(quad) }
      end
      enum_statement
    end
    alias_method :each, :each_statement

    ##
    # @private
    # @see RDF::Enumerable#statement?
    def statement?(*args)
      case args.length
      when 0 then false
      when 1
        statement = begin
          args.first && RDF::Statement.from(args.first)
        rescue ArgumentError
          nil
        end
        !statement.nil? && @data.key?(quad_key(statement))
      else
        raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 0 or 1)"
      end
    end
    alias_method :has_statement?, :statement?

    protected

    ##
    # Executes a basic graph pattern, joining the patterns on their common
    # valid time.
    #
    # @private
    # @see RDF::Queryable#query_execute
    def query_execute(query, at: nil, during: nil, **options, &block)
      constraint = during && Interval.from(during)
      pairs = [[RDF::Query::Solution.new, nil]] # [solution, common interval]

      query.patterns.each do |pattern|
        next_pairs = []
        pairs.each do |solution, common|
          matched = false
          pattern.execute(self, solution) do |statement|
            statement_solution = pattern.solution(statement)
            next unless solution.compatible?(statement_solution)
            @data.fetch(quad_key(statement), []).each do |interval|
              interval = interval.intersect(constraint) if constraint
              next if interval.nil?
              next if at && !interval.contains?(at)
              joined = common ? common.intersect(interval) : interval
              next if joined.nil?
              matched = true
              next_pairs << [solution.merge(statement_solution), joined]
            end
          end
          next_pairs << [solution, common] if !matched && pattern.optional?
        end
        pairs = next_pairs
        break if pairs.empty?
      end

      pairs.each do |solution, common|
        yield TemporalSolution.new(solution.to_h, interval: common)
      end
    end

    ##
    # @private
    # @see RDF::Writable#insert_statement
    def insert_statement(statement)
      insert_interval(statement, Interval::ETERNAL)
    end

    ##
    # @private
    # @see RDF::Mutable#delete_statement
    def delete_statement(statement)
      @data.delete(quad_key(statement))
    end

    ##
    # @private
    # @see RDF::Mutable#clear
    def clear_statements
      @data = {}
    end

    private

    ##
    # @private
    def insert_interval(statement, interval)
      statement = RDF::Statement.from(statement)
      raise ArgumentError, "Statement #{statement.inspect} is incomplete" if statement.incomplete?

      key = quad_key(statement)
      @data[key] = normalize((@data[key] || []) + [interval])
      self
    end

    ##
    # @private
    def retract_interval(statement, interval)
      statement = RDF::Statement.from(statement)
      key = quad_key(statement)
      existing = @data[key]
      return self unless existing

      remaining = existing.flat_map { |iv| iv.subtract(interval) }
      if remaining.empty?
        @data.delete(key)
      else
        @data[key] = remaining
      end
      self
    end

    ##
    # Sorts intervals and merges overlapping or adjacent ones.
    #
    # @private
    def normalize(intervals)
      intervals.sort.each_with_object([]) do |interval, merged|
        if merged.empty? || !(merged.last.overlaps?(interval) || merged.last.adjacent?(interval))
          merged << interval
        else
          merged[-1] = merged.last.merge(interval)
        end
      end
    end

    ##
    # @private
    def temporal_match?(statement, at: nil, during: nil)
      intervals = @data[quad_key(statement)]
      return false if intervals.nil?
      if at
        intervals.any? { |iv| iv.contains?(at) }
      else
        constraint = Interval.from(during)
        intervals.any? { |iv| iv.overlaps?(constraint) }
      end
    end

    ##
    # @private
    def quad_key(statement)
      statement.to_quad
    end

    ##
    # @private
    def statement_for(quad)
      RDF::Statement.new(quad[0], quad[1], quad[2], graph_name: quad[3])
    end
  end # TemporalRepository
end # RDF

