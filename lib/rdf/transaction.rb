module RDF
  ##
  # An RDF transaction.
  #
  # Transactions provide an ACID scope for queries and mutations.
  #
  # Repository implementations may provide support for transactional updates
  # by providing an atomic implementation of {Mutable#apply_changeset} and 
  # responding to `#supports?(:atomic_write)` with `true`.
  # 
  # We carefully distinguish between read-only and read/write transactions,
  # in order to enable repository implementations to take out the
  # appropriate locks for concurrency control. Transactions are read-only
  # by default; mutability must be explicitly requested on construction in
  # order to obtain a read/write transaction.
  #
  # Individual repositories may make their own sets of guarantees within the 
  # transaction's scope. In case repository implementations should be unable
  # to provide full ACID guarantees for transactions, that must be clearly 
  # indicated in their documentation. If update atomicity is not provided, 
  # `#supports?(:atomic_write)` must respond `false`.
  #
  # @example Executing a read-only transaction
  #   repository = RDF::Repository.new
  #
  #   RDF::Transaction.begin(repository) do |tx|
  #     tx.query({predicate: RDF::Vocab::DOAP.developer}) do |statement|
  #       puts statement.inspect
  #     end
  #   end
  #
  # @example Executing a read/write transaction
  #   repository = RDF::Repository.new
  #
  #   RDF::Transaction.begin(repository, mutable: true) do |tx|
  #     subject = RDF::URI("http://example.org/article")
  #     tx.delete [subject, RDF::RDFS.label, "Old title"]
  #     tx.insert [subject, RDF::RDFS.label, "New title"]
  #   end
  # 
  # The base class provides an atomic write implementation depending on
  # {RDF::Changeset} and using {Changeset#apply}. Custom {Repository} classes
  # can implement a minimial write-atomic transactions by overriding
  # {#apply_changeset}.
  #
  # Reads within a transaction run against the live repository by default
  # ({#isolation_level} is `:read_committed`). Repositories may provide support
  # for snapshots by implementing {Repository#snapshot} and responding `true` to
  # `#supports?(:snapshots)`. In this case, the transaction will use the 
  # {RDF::Dataset} returned by {#snapshot} for reads (`:repeatable_read`).
  #
  # For datastores that support transactions natively, implementation of a 
  # custom {Transaction} subclass is recommended. The {Repository} is 
  # responsible for specifying snapshot support and isolation level as 
  # appropriate. Note that repositories may provide the snapshot isolation level
  # without implementing {#snapshot}.
  #
  # @example A repository with a custom transaction class
  #  class MyRepository < RDF::Repository
  #    DEFAULT_TX_CLASS = MyTransaction
  #    # ...
  #    # custom repository logic
  #    # ...
  #  end
  #
  # @see RDF::Changeset
  # @see RDF::Mutable#apply_changeset
  # @since 0.3.0
  class Transaction
    include RDF::Mutable
    include RDF::Enumerable
    include RDF::Queryable

    ##
    # @see RDF::Enumerable#each
    def each(*args, &block)
      read_target.each(*args, &block)
    end

    ##
    # Executes a transaction against the given RDF repository.
    #
    # @param  [RDF::Repository]         repository
    # @param  [Boolean]                 mutable (false)
    #    Whether this is a read-only or read/write transaction.
    # @param  [Hash{Symbol => Object}]  options
    # @yield  [tx]
    # @yieldparam [RDF::Transaction] tx
    # @return [void]
    def self.begin(repository, mutable: false, **options, &block)
      self.new(repository, mutable: mutable, **options, &block)
    end

    ##
    # The repository being operated upon.
    #
    # @return [RDF::Repository]
    # @since  2.0.0
    attr_reader :repository

    ##
    # The default graph name to apply to statements inserted or deleted by the
    # transaction.
    #
    # @return [RDF::Resource, nil]
    # @since  2.0.0
    attr_reader :graph_name

    ##
    # RDF statement mutations to apply when executed.
    #
    # @return [RDF::Changeset]
    # @since  2.0.0
    attr_reader :changes

    ##
    # Any additional options for this transaction.
    #
    # @return [Hash{Symbol => Object}]
    attr_reader :options

    ##
    # Initializes this transaction.
    #
    # @param  [Hash{Symbol => Object}]  options
    # @param  [Boolean]                 mutable (false)
    #    Whether this is a read-only or read/write transaction.
    # @yield  [tx]
    # @yieldparam [RDF::Transaction] tx
    def initialize(repository, graph_name: nil, mutable: false, **options, &block)
      @repository = repository
      @snapshot = 
        repository.supports?(:snapshots) ? repository.snapshot : repository
      @options    = options.dup
      @mutable    = mutable
      @graph_name = graph_name

      raise TransactionError, 
            'Tried to open a mutable transaction on an immutable repository' if
        @mutable && !@repository.mutable?

      @changes = RDF::Changeset.new
      
      if block_given?
        case block.arity
          when 1 then block.call(self)
          else self.instance_eval(&block)
        end
      end
    end
    
    ##
    # @see RDF::Dataset#isolation_level
    def isolation_level
      return options[:isolation] if RDF::Dataset::ISOLATION_LEVELS.include?(options[:isolation])
      return :repeatable_read if repository.supports?(:snapshots)
      :read_committed
    end

    ##
    # Indicates whether the transaction includes changes relative to the target 
    # repository's state at transaction start time.
    #
    # The response is guaranteed to be `true` if executing the transaction 
    # against the original repository state would cause a change. It may also
    # return `true` in cases where the repository would not change (e.g. 
    # because the transaction would insert statements already present). 
    #
    # @note `Transaction` implementers may choose to `NotImplementedError`
    #   if the transaction implementation cannot be implemented efficiently.
    #
    # @return [Boolean] true if the transaction has mutated (insert/delete) 
    #   since transaction start time
    #
    # @raise [NotImplementedError] if a mutation check is not implemented
    def mutated?
      return !changes.empty? if self.class == Transaction

      raise NotImplementedError, 
            '#mutated? is not implemented for #{self.class}'
    end

    ##
    # Returns `true` if this is a read/write transaction, `false` otherwise.
    #
    # @return [Boolean]
    # @see     RDF::Writable#writable?
    def writable?
      @mutable
    end

    ##
    # Returns `true` if this is a read/write transaction, `false` otherwise.
    #
    # @return [Boolean]
    # @see     RDF::Writable#mutable?
    def mutable?
      @mutable
    end

    ##
    # Returns `true` to indicate that this transaction is readable.
    #
    # @return [Boolean]
    # @see    RDF::Readable#readable?
    def readable?
      true
    end

    ##
    # @overload statement?
    #   Returns `false` indicating this is not an RDF::Statemenet.
    #   @return [Boolean]
    #   @see RDF::Value#statement?
    # @overload statement?(statement)
    #   @see    RDF::Enumerable#statement?
    def statement?(*args)
      case args.length
      when 0 then false
      when 1 then read_target.statement?(*args)
      else raise ArgumentError("wrong number of arguments (given #{args.length}, expected 0 or 1)")
      end
    end
    alias_method :has_statement?, :statement?

    ##
    # Returns a developer-friendly representation of this transaction.
    #
    # @return [String]
    def inspect
      sprintf("#<%s:%#0x(changes: -%d/+%d)>", self.class.name,
        self.__id__, self.changes.deletes.count, self.changes.inserts.count)
    end

    ##
    # Outputs a developer-friendly representation of this transaction to
    # `stderr`.
    #
    # @return [void]
    def inspect!
      $stderr.puts(inspect)
    end

    ##
    # Executes the transaction
    #
    # @return [Boolean] `true` if the changes are successfully applied.
    # @raise [TransactionError] if the transaction can't be applied
    def execute
      raise TransactionError, 'Cannot execute a rolled back transaction. ' \
                              'Open a new one instead.' if instance_variable_defined?(:@rolledback) && @rolledback
      @changes.apply(@repository)
    end

    ##
    # Rolls back the transaction
    #
    # @note: the base class simply replaces its current `Changeset` with a 
    #   fresh one. Other implementations may need to explictly rollback 
    #   at the supporting datastore.
    #
    # @note: clients should not rely on using same transaction instance after
    #   rollback.
    #
    # @return [Boolean] `true` if the changes are successfully applied.
    def rollback
      @changes = RDF::Changeset.new
      @rolledback = true
    end

    protected

    ##
    # Appends an RDF statement to the sequence to insert when executed.
    #
    # @param  [RDF::Statement] statement
    # @return [void]
    # @see    RDF::Writable#insert_statement
    def insert_statement(statement)
      @changes.insert(process_statement(statement))
    end

    ##
    # Appends an RDF statement to the sequence to delete when executed.
    #
    # @param  [RDF::Statement] statement
    # @return [void]
    # @see    RDF::Mutable#delete_statement
    def delete_statement(statement)
      @changes.delete(process_statement(statement))
    end

    def query_pattern(*args, &block)
      read_target.send(:query_pattern, *args, &block)
    end

    def query_execute(*args, &block)
      read_target.send(:query_execute, *args, &block)
    end
  
    undef_method :load, :update, :clear

    private
    
    ##
    # @private Adds the default graph_name to the statement, when one it does 
    #   not already have one.
    #
    # @param statement [RDF::Statement]
    # @return [RDF::Statement]
    def process_statement(statement)
      if graph_name
        statement = statement.dup
        statement.graph_name = graph_name
      end
      statement
    end
    
    def read_target
      return @snapshot if graph_name.nil?
      return @snapshot.project_graph(nil) if graph_name == false
      @snapshot.project_graph(graph_name)
    end

    public

    ##
    # A transaction with full serializability.
    # 
    # @todo refactor me!
    # @see RDF::Transaction
    class SerializedTransaction < Transaction
      ##
      # @see Transaction#initialize
      def initialize(*args, **options, &block)
        super(*args, **options, &block)
        @base_snapshot = @snapshot
        @read_patterns = []
        @write_statements = []
      end
      
      ##
      # Inserts the statement to the transaction's working snapshot.
      #
      # @see Transaction#insert_statement
      def insert_statement(statement)
        statement = process_statement(statement)
        @changes.insert(statement)
        @write_statements << statement
        @snapshot = @snapshot.class
          .new(data: @snapshot.send(:insert_to, 
                                    @snapshot.send(:data), 
                                    statement))
      end

      ##
      # Deletes the statement from the transaction's working snapshot.
      #
      # @see Transaction#insert_statement
      def delete_statement(statement)
        statement = process_statement(statement)
        @changes.delete(statement)
        @write_statements << statement
        @snapshot = @snapshot.class
          .new(data: @snapshot.send(:delete_from, 
                                    @snapshot.send(:data), 
                                    statement))
      end

      def each(*args, &block)
        return enum_for(:each, *args) unless block_given?

        track_read_pattern(full_read_pattern) { super(*args, &block) }
      end

      def statement?(*args)
        case args.length
        when 0 then false
        when 1
          pattern = RDF::Query::Pattern.from(args.first)
          track_read_pattern(pattern) { super }
        else raise ArgumentError("wrong number of arguments (given #{args.length}, expected 0 or 1)")
        end
      end
      alias_method :has_statement?, :statement?

      ##
      # @see RDF::Dataset#isolation_level
      def isolation_level
        :serializable
      end
      
      ##
      # @note this is a simple object equality check.
      # 
      # @see RDF::Transaction#mutated?
      def mutated?
        !@snapshot.send(:data).equal?(repository.send(:data))
      end

      def rollback
        @snapshot = @base_snapshot
        @read_patterns.clear
        @write_statements.clear
        super
      end
      
      ##
      # Replaces repository data with the transaction's snapshot in a safely 
      # serializable fashion.
      # 
      # Validates write intents and every read predicate against changes
      # committed after this transaction's snapshot was taken. Unrelated
      # updates are merged without rejecting the transaction.
      # 
      # @raise [ConflictError] when the transaction can't be serialized.
      # @see Transaction#execute
      def execute
        raise TransactionError, 'Cannot execute a rolled back transaction. ' \
                                'Open a new one instead.' if instance_variable_defined?(:@rolledback) && @rolledback

        repository.send(:synchronize) do
          base_data    = @base_snapshot.send(:data)
          current_data = repository.send(:data)
          working_data = @snapshot.send(:data)

          unless current_data.equal?(working_data)
            committed_changes = repository.send(:changed_statements, base_data, current_data)
            transaction_changes = repository.send(:changed_statements, base_data, working_data)

            validate_write_set(committed_changes)
            validate_read_set(committed_changes)

            repository.send(:data=, merge_changes(current_data, transaction_changes))
          end
        end

        true
      end

      protected

      def query_pattern(pattern, **options, &block)
        pattern = scoped_read_pattern(pattern)

        unless block_given?
          return Enumerator.new do |yielder|
            track_read_pattern(pattern) do
              read_target.send(:query_pattern, pattern, **options) { |statement| yielder << statement }
            end
          end
        end

        track_read_pattern(pattern) { super(pattern, **options, &block) }
      end

      private

      def full_read_pattern
        pattern = RDF::Query::Pattern.new
        pattern.graph_name = graph_name unless graph_name.nil?
        pattern
      end

      def scoped_read_pattern(pattern)
        pattern = pattern.dup
        if !graph_name.nil? &&
           (pattern.graph_name.nil? || pattern.graph_name.is_a?(RDF::Query::Variable))
          pattern.graph_name = graph_name
        end
        pattern.freeze
      end

      def track_read_pattern(pattern)
        pattern = scoped_read_pattern(pattern)
        @read_patterns << pattern
        yield if block_given?
      end

      def validate_write_set(changes)
        committed = changes[:inserts] + changes[:deletes]
        write_set = @write_statements +
          repository.send(:changed_statements, @base_snapshot.send(:data), @snapshot.send(:data)).values.flatten

        write_set.uniq.each do |statement|
          conflicting = committed.find { |committed_statement| committed_statement.eql?(statement) }
          next unless conflicting

          raise_conflict(:write_conflict,
                          pattern: RDF::Query::Pattern.from(conflicting),
                          statement: conflicting)
        end
      end

      def validate_read_set(changes)
        changes[:inserts].each do |statement|
          pattern = @read_patterns.find { |read_pattern| read_pattern_matches?(read_pattern, statement) }
          raise_conflict(:phantom_read, pattern: pattern, statement: statement) if pattern
        end

        changes[:deletes].each do |statement|
          pattern = @read_patterns.find { |read_pattern| read_pattern_matches?(read_pattern, statement) }
          raise_conflict(:write_skew, pattern: pattern, statement: statement) if pattern
        end
      end

      def read_pattern_matches?(pattern, statement)
        graph_matches = case pattern.graph_name
        when nil then true
        when false then statement.graph_name.nil?
        when RDF::Query::Variable then statement.graph_name?
        else pattern.graph_name.eql?(statement.graph_name)
        end

        return false unless graph_matches

        ungraphed_pattern = pattern.dup
        ungraphed_pattern.graph_name = nil
        ungraphed_pattern === statement
      end

      def merge_changes(current_data, changes)
        merged_data = current_data
        changes[:deletes].each do |statement|
          merged_data = repository.send(:delete_from, merged_data, statement)
        end
        changes[:inserts].each do |statement|
          merged_data = repository.send(:insert_to, merged_data, statement)
        end
        merged_data
      end

      def raise_conflict(conflict_type, pattern:, statement:)
        raise ConflictError.new(conflict_type,
                                pattern: pattern,
                                statement: statement,
                                repository: repository)
      end
    end # SerializedTransaction

    ##
    # An error class for transaction failures.
    # 
    # This error indicates that the transaction semantics have been violated in 
    # some way.
    class TransactionError < RuntimeError; end

    ##
    # Raised when a serializable transaction cannot be committed without
    # violating its snapshot or write intents.
    class ConflictError < TransactionError
      attr_reader :conflict_type, :pattern, :statement

      def initialize(conflict_type, pattern:, statement:, repository: nil)
        @conflict_type = conflict_type
        @pattern = pattern
        @statement = statement
        super("Unable to serialize transaction against #{repository.class}: " \
              "#{conflict_type} matches #{pattern.inspect}")
      end

      alias type conflict_type
    end
  end # Transaction
end # RDF
