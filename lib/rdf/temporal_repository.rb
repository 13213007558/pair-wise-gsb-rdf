module RDF
  class Statement
    def valid_intervals
      options[:valid_intervals]
    end

    def valid_time
      intervals = valid_intervals
      intervals && intervals.length == 1 ? intervals.first : intervals
    end
    alias_method :valid_interval, :valid_time
  end

  ##
  # An in-memory {Repository} recording half-open validity intervals for quads.
  #
  # Queries accept either `at:` for a point or `during:`/`valid_time:` for a
  # half-open range. Basic graph pattern solutions expose their common validity
  # through `#valid_time` and `#valid_intervals`.
  class TemporalRepository < Repository
    def initialize(*args, **options, &block)
      options[:temporal] = true unless options.key?(:temporal)
      super(*args, **options, &block)
    end
  end

  class Repository
    module TemporalImplementation
      DEFAULT_GRAPH = Implementation::DEFAULT_GRAPH
      VALID_TIME_KEY = :valid_intervals

      class TemporalSolution < RDF::Query::Solution
        attr_reader :valid_intervals, :valid_at

        def initialize(bindings = {}, valid_intervals: nil, valid_at: nil, &block)
          super(bindings, &block)
          @valid_intervals = valid_intervals
          @valid_at = valid_at
        end

        def valid_time
          @valid_intervals && @valid_intervals.length == 1 ? @valid_intervals.first : @valid_intervals
        end
        alias_method :valid_interval, :valid_time

        def merge!(other)
          result = super
          if other.is_a?(TemporalSolution)
            @valid_intervals = RDF::Repository::TemporalImplementation.interval_intersection(
              @valid_intervals, other.valid_intervals)
            @valid_at = other.valid_at || @valid_at
          end
          result
        end

        def merge(other)
          merged = dup
          merged.__send__(:merge!, other)
          merged
        end

        def dup
          self.class.new(@bindings.dup,
                         valid_intervals: @valid_intervals&.dup,
                         valid_at: @valid_at)
        end

        def hash
          [super, @valid_intervals, @valid_at].hash
        end

        def eql?(other)
          super && (!other.is_a?(TemporalSolution) ||
                    @valid_intervals.eql?(other.valid_intervals) &&
                    @valid_at.eql?(other.valid_at))
        end

        def ==(other)
          super && (!other.is_a?(TemporalSolution) ||
                    @valid_intervals == other.valid_intervals &&
                    @valid_at == other.valid_at)
        end

        def inspect
          sprintf("#<%s:%#0x(%s) valid_time=%s>", self.class.name, __id__, @bindings.inspect,
                  @valid_intervals.inspect)
        end
      end

      class << self
        def interval(interval)
          interval = interval.is_a?(Array) ? Range.new(interval.first, interval.last, true)
                                            : interval
          unless interval.is_a?(Range) && interval.begin && interval.end
            raise ArgumentError, "expected a half-open range with finite endpoints, got #{interval.inspect}"
          end
          unless interval.exclude_end? && interval.begin < interval.end
            raise ArgumentError, "expected a half-open [start, finish) interval, got #{interval.inspect}"
          end
          interval
        end

        def merge_intervals(intervals)
          intervals.sort_by(&:begin).each_with_object([]) do |interval, merged|
            if merged.empty? || merged.last.end < interval.begin
              merged << interval
            else
              previous = merged.pop
              merged << (previous.begin...[previous.end, interval.end].max)
            end
          end
        end

        def subtract_intervals(intervals, removed)
          removed = removed.is_a?(Range) ? [removed] : Array(removed)
          removed = removed.map { |interval| interval(interval) }.sort_by(&:begin)
          intervals.each_with_object([]) do |interval, remaining|
            current_start = interval.begin
            removed.each do |other|
              next if other.end <= interval.begin || other.begin >= interval.end

              if other.begin > current_start
                remaining << (current_start...[other.begin, interval.end].min)
              end
              current_start = [current_start, other.end].max
            end
            remaining << (current_start...interval.end) if current_start < interval.end
          end
        end

        def interval_intersection(left, right)
          return left.dup if right.nil?
          return right.dup if left.nil?
          left = left.is_a?(Range) ? [left] : Array(left)
          right = right.is_a?(Range) ? [right] : Array(right)

          left.filter_map do |left_interval|
            right.filter_map do |right_interval|
              start = [left_interval.begin, right_interval.begin].max
              finish = [left_interval.end, right_interval.end].min
              start...finish if start < finish
            end
          end.flatten.then { |intervals| merge_intervals(intervals) }
        end
      end

      def self.extend_object(obj)
        obj.instance_variable_set(:@data, obj.options.delete(:data) || Hash.new)
        obj.instance_variable_set(:@tx_class,
                                  obj.options.delete(:transaction_class) ||
                                  RDF::Transaction::SerializedTransaction)
        super
      end

      def supports?(feature)
        case feature.to_sym
        when :temporal then true
        when :graph_name then @options[:with_graph_name]
        when :validity then @options.fetch(:with_validity, true)
        when :literal_equality then true
        when :atomic_write then true
        when :rdf_full then true
        when :base_direction then true
        when :snapshots then true
        else false
        end
      end

      def count
        each_statement.count
      end

      def graph?(*args)
        case args.length
        when 0 then false
        when 1 then @data.key?(args.first)
        else raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 0 or 1)"
        end
      end
      alias_method :has_graph?, :graph?

      def graph_names(options = nil, &block)
        @data.keys.reject { |g| g == DEFAULT_GRAPH }.to_a
      end

      def each_graph(&block)
        if block_given?
          @data.each_key do |gn|
            yield RDF::Graph.new(graph_name: (gn == DEFAULT_GRAPH ? nil : gn), data: self)
          end
        end
        enum_graph
      end

      def statement?(*args)
        case args.length
        when 0 then false
        when 1 then args.first && valid_intervals_for(args.first).any?
        else raise ArgumentError, "wrong number of arguments (given #{args.length}, expected 0 or 1)"
        end
      end
      alias_method :has_statement?, :statement?

      def each_statement(&block)
        return enum_statement unless block_given?

        each_quad_with_intervals do |subject, predicate, object, graph_name, intervals|
          yield temporal_statement(subject, predicate, object, graph_name, intervals)
        end
      end
      alias_method :each, :each_statement

      # Inserts one or more statements carrying the same validity interval.
      def insert(*statements, valid_time: nil, valid_interval: nil, **statement_options)
        raise TypeError.new("#{self} is immutable") if immutable?
        interval = valid_interval || valid_time
        coerce_temporal_statements(statements, statement_options) do |statement|
          attach_valid_time(statement, interval)
          insert_statement(statement)
        end
        self
      end

      # Inserts a statement for a half-open validity interval.
      def insert_valid(*statements, valid_time: nil, valid_interval: nil, **options)
        interval = valid_interval || valid_time
        if interval.nil? && statements.length > 1 && (statements.last.is_a?(Range) || statements.last.is_a?(Array))
          interval = statements.pop
        end
        insert(*statements, **options, valid_time: interval)
      end
      alias_method :insert_interval, :insert_valid

      # Removes a half-open validity interval, splitting stored intervals when needed.
      def retract(statement, valid_time)
        raise TypeError.new("#{self} is immutable") if immutable?
        statement = RDF::Statement.from(statement)
        update_statement(statement, temporal_interval(valid_time)) { |intervals, _| intervals }
        self
      end
      alias_method :retract_valid, :retract
      alias_method :retract_interval, :retract
      alias_method :withdraw, :retract

      def apply_changeset(changeset)
        data = @data
        changeset.deletes.each do |del|
          if del.constant?
            data = delete_from(data, del)
          else
            query_pattern(del) { |stmt| data = delete_from(data, stmt) }
          end
        end
        changeset.inserts.each { |ins| data = insert_to(data, ins) }
        @data = data
      end

      def snapshot
        self.class.new(data: @data, temporal: true).freeze
      end

      def query(pattern, **options, &block)
        if pattern.is_a?(RDF::Query)
          query_execute(pattern, **options, &block)
        else
          pattern = RDF::Query::Pattern.from(pattern)
          results = RDF::Query::Solutions.new
          query_pattern(pattern, **options) { |statement| results << statement }
          results.each(&block) if block_given?
          results
        end
      end

      protected

      def query_execute(query, at: nil, time: nil, during: nil, valid_time: nil,
                        bindings: {}, graph_name: nil, name: nil, **options, &block)
        at ||= time
        valid_during = options.delete(:valid_during)
        during ||= valid_time || valid_during
        if query.empty?
          solution = TemporalSolution.new({})
          yield solution if block_given?
          return RDF::Query::Solutions([solution])
        end

        patterns = query.patterns
        patterns = patterns.map(&:dup)
        patterns = patterns.sort_by(&:cost) if options[:optimize]
        effective_graph_name = name || graph_name || query.graph_name
        unless effective_graph_name.nil?
          patterns.each do |pattern|
            pattern.graph_name = effective_graph_name if pattern.graph_name.nil?
          end
        end

        restriction = during || valid_time
        initial_bindings = bindings.is_a?(RDF::Query::Solution) ? bindings.to_h : bindings.to_h
        solutions = RDF::Query::Solutions([
          TemporalSolution.new(initial_bindings,
                               valid_intervals: restriction && [temporal_interval(restriction)],
                               valid_at: at)
        ])

        patterns.each do |pattern|
          old_solutions, solutions = solutions, RDF::Query::Solutions.new

          old_solutions.each do |solution|
            found_match = false
            pattern.execute(self, solution.to_h) do |statement|
              pattern_solution = pattern.solution(statement)
              next unless solution.compatible?(pattern_solution)

              statement_intervals = statement.options.fetch(VALID_TIME_KEY, [])
              if at
                statement_intervals = statement_intervals.select { |interval| interval.cover?(at) }
              end
              statement_intervals = temporal_intersection(statement_intervals,
                                                          solution.valid_intervals)
              next if statement_intervals.empty?

              temporal_solution = TemporalSolution.new(pattern_solution.to_h,
                                                      valid_intervals: statement_intervals,
                                                      valid_at: at)
              merged = solution.merge(temporal_solution)
              found_match = true
              solutions << merged
            end

            solutions << solution if !found_match && pattern.optional?
          end

          return solutions if solutions.empty?
        end

        solutions.each(&block) if block_given?
        solutions
      end

      def query_pattern(pattern, at: nil, time: nil, during: nil, valid_time: nil, valid_during: nil,
                        **options)
        at ||= time
        restriction = during || valid_time || valid_during
        restriction &&= [temporal_interval(restriction)]
        return enum_for(:query_pattern, pattern, at: at, time: time, during: during,
                        valid_time: valid_time, valid_during: valid_during,
                        **options) unless block_given?

        each_quad_with_intervals do |subject, predicate, object, graph_name, intervals|
          statement = temporal_statement(subject, predicate, object, graph_name, intervals)
          next unless temporal_pattern_match?(pattern, statement)

          if at
            next unless intervals.any? { |interval| interval.cover?(at) }
            yield statement
          elsif restriction
            matching = temporal_intersection(intervals, restriction)
            matching.each do |interval|
              yield temporal_statement(subject, predicate, object, graph_name, [interval])
            end
          else
            yield statement
          end
        end
      end

      def insert_statement(statement)
        @data = insert_to(@data, statement)
      end

      def delete_statement(statement)
        @data = delete_from(@data, statement)
      end

      def clear_statements
        @data = Hash.new
      end

      def data
        @data
      end

      def data=(data)
        @data = data
      end

      private

      def temporal_interval(interval)
        RDF::Repository::TemporalImplementation.interval(interval)
      end

      def temporal_intersection(left, right)
        RDF::Repository::TemporalImplementation.interval_intersection(left, right)
      end

      def temporal_merge(intervals)
        RDF::Repository::TemporalImplementation.merge_intervals(intervals)
      end

      def temporal_subtract(intervals, removed)
        RDF::Repository::TemporalImplementation.subtract_intervals(intervals, removed)
      end

      def coerce_temporal_statements(statements, statement_options = {})
        if statements.length == 1 && !statements.first.is_a?(RDF::Statement) &&
           statements.first.respond_to?(:each_statement)
          statements.first.each_statement { |statement| yield statement }
        elsif temporal_statement_arguments?(statements) || temporal_statement_list_arguments?(statements)
          statements.each { |value| yield RDF::Statement.from(value) }
        elsif statements.length > 1
          yield RDF::Statement.new(*statements, **statement_options)
        else
          statements.each do |value|
            statement = RDF::Statement.from(value)
            statement_options.each do |key, option_value|
              statement.options[key] = option_value unless statement.options.key?(key)
              statement.graph_name = option_value if key == :graph_name && statement.graph_name.nil?
            end
            raise ArgumentError, "Statement #{statement.inspect} is incomplete" if statement.incomplete?
            yield statement
          end
        end
      end

      def attach_valid_time(statement, interval)
        statement_valid_time = statement.options.delete(:valid_time) || interval
        unless statement.options.key?(VALID_TIME_KEY)
          statement.options[VALID_TIME_KEY] = [temporal_interval(statement_valid_time)]
        end
      end

      def temporal_statement_arguments?(statements)
        statements.length > 1 && !statements.first.is_a?(Array) &&
          statements.all? { |value| value.is_a?(RDF::Statement) }
      end

      def temporal_statement_list_arguments?(statements)
        statements.length > 1 && statements.all? { |value| value.is_a?(Array) }
      end

      def each_quad_with_intervals
        @data.each do |graph, subjects|
          subjects.each do |subject, predicates|
            predicates.each do |predicate, objects|
              objects.each do |object, intervals|
                next unless intervals&.any?
                graph_name = graph.equal?(DEFAULT_GRAPH) ? nil : graph
                yield subject, predicate, object, graph_name, intervals
              end
            end
          end
        end
      end

      def temporal_statement(subject, predicate, object, graph_name, intervals)
        RDF::Statement.new(subject, predicate, object,
                           graph_name: graph_name,
                           VALID_TIME_KEY => intervals)
      end

      def temporal_pattern_match?(pattern, statement)
        graph_name = pattern.graph_name
        graph = statement.graph_name || false
        graph_matches = graph_name.nil? ||
                        (graph_name == false || graph_name == DEFAULT_GRAPH) && !graph ||
                        graph && graph_name.eql?(graph)
        return false unless graph_matches

        if pattern.subject?
          subject = pattern.subject
          return false unless subject.is_a?(RDF::Query::Pattern) ? subject.eql?(statement.subject) :
                                                               subject == statement.subject
        end
        return false if pattern.predicate? && pattern.predicate != statement.predicate
        return false if pattern.object? && pattern.object != statement.object
        true
      end

      def valid_intervals_for(statement)
        s, p, o, g = statement.to_quad
        g ||= DEFAULT_GRAPH
        @data.dig(g, s, p, o) || []
      end

      def temporal_options?(options)
        options = options.dup
        at = options.delete(:at)
        time = options.delete(:time)
        during = options.delete(:during)
        valid_time = options.delete(:valid_time)
        valid_during = options.delete(:valid_during)
        temporal = [at, time, during, valid_time, valid_during].any?
        [temporal, options]
      end

      def insert_to(data, statement)
        intervals = Array(statement.options[VALID_TIME_KEY]).map do |interval|
          temporal_interval(interval)
        end
        raise ArgumentError, "temporal insert requires valid_time" unless intervals&.any?
        update_leaf(data, statement) do |existing|
          temporal_merge(existing + intervals)
        end
      end

      def delete_from(data, statement)
        intervals = Array(statement.options[VALID_TIME_KEY]).map do |interval|
          temporal_interval(interval)
        end
        update_leaf(data, statement) do |existing|
          if intervals.any?
            temporal_subtract(existing, intervals)
          else
            []
          end
        end
      end

      def update_leaf(data, statement)
        s, p, o, graph = statement.to_quad
        graph ||= DEFAULT_GRAPH
        existing = data.dig(graph, s, p, o) || []
        updated = yield(existing)
        replace_leaf(data, graph, s, p, o, updated)
      end

      def update_statement(statement, interval)
        @data = update_leaf(@data, statement) do |existing|
          yield temporal_subtract(existing, interval), interval
        end
      end

      def replace_leaf(data, graph, subject, predicate, object, intervals)
        data = deep_dup(data)
        data[graph] = data.fetch(graph, {}).dup
        data[graph][subject] = data[graph].fetch(subject, {}).dup
        data[graph][subject][predicate] = data[graph][subject].fetch(predicate, {}).dup

        if intervals.any?
          data[graph][subject][predicate][object] = intervals
        else
          data[graph][subject][predicate].delete(object)
        end

        if data[graph][subject][predicate].empty?
          data[graph][subject].delete(predicate)
        end
        data[graph].delete(subject) if data[graph][subject].empty?
        data.delete(graph) if data[graph].empty?
        data
      end

      def deep_dup(value)
        case value
        when Hash then value.transform_values { |child| deep_dup(child) }
        when Array then value.map(&:dup)
        else value
        end
      end
    end
  end
end
