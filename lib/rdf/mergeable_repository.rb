require 'securerandom'

module RDF
  ##
  # A mergeable, eventually-consistent RDF repository.
  #
  # {RDF::MergeableRepository} is designed for scenarios where several
  # replicas of the same RDF dataset are edited offline and later
  # synchronized. It implements a state-based CRDT (conflict-free
  # replicated data type) with *observed-remove* (OR-Set) semantics:
  #
  #   * Every inserted statement is tagged with a *dot*: a
  #     (replica_id, counter) pair uniquely identifying the insert
  #     event. The counter is monotonically increasing per replica.
  #   * Deleting a statement only retracts the insert dots that the
  #     deleting replica has already *observed*. Concurrent inserts from
  #     other replicas survive the delete (add-wins on concurrency).
  #   * Deletes are recorded as tombstones so that the removal can be
  #     propagated to (and is idempotent for) other replicas.
  #
  # Blank nodes are given a collision-free internal identity: on insert,
  # every blank node is canonicalized to a node whose identifier is
  # namespaced by the inserting replica's replica_id under the reserved
  # {BNODE_ID_PREFIX} prefix. Identity is therefore stable across
  # replicas and independent of the temporary labels produced by
  # serializers. Statements copied verbatim from one replica to another
  # retain their blank node identity.
  #
  # Replicas may synchronize either by merging full state
  # ({#merge}) or by exchanging deltas relative to a version vector
  # ({#delta_since} / {#merge_delta}). Both operations are commutative,
  # associative and idempotent, so merges may be applied in any order,
  # any number of times.
  #
  # Tombstones are only garbage-collected via {#compact!}, given a
  # *stable frontier*: a version vector such that every replica is known
  # to have observed all events it covers. Compacting with a frontier
  # that some replica has not yet reached may cause removed statements
  # to resurrect on that replica.
  #
  # @example Synchronizing two replicas
  #   a = RDF::MergeableRepository.new(replica_id: "a")
  #   b = RDF::MergeableRepository.new(replica_id: "b")
  #   a.insert(RDF::Statement(RDF::URI("ex:s"), RDF::URI("ex:p"), RDF::URI("ex:o")))
  #   b.merge(a)                      # full-state merge
  #   b.merge_delta(a.delta_since(b.version_vector)) # or delta merge
  #
  # @see RDF::Repository
  class MergeableRepository < RDF::Repository
    ##
    # A dot uniquely identifies a single insert/delete event as a
    # (replica, counter) pair.
    Dot = Struct.new(:replica, :counter)

    ##
    # Reserved prefix marking canonical blank node identifiers. A blank
    # node whose identifier carries this prefix is treated as already
    # canonical on every replica; local blank node labels using this
    # prefix are therefore reserved and must not be used.
    BNODE_ID_PREFIX = "rdf:mb:"

    ##
    # A delta of CRDT state relative to a version vector, suitable for
    # incremental (anti-entropy) synchronization between replicas.
    #
    # @see RDF::MergeableRepository#delta_since
    # @see RDF::MergeableRepository#merge_delta
    class Delta
      ##
      # @return [Hash{RDF::Statement => Array<Dot>}] insert events
      attr_reader :adds

      ##
      # @return [Hash{RDF::Statement => Hash{Dot => Dot}}] remove events,
      #   mapping each removed insert dot to the dot of the remove event
      attr_reader :removes

      ##
      # @return [Hash{String => Integer}] the source replica's version
      #   vector when the delta was produced
      attr_reader :clock

      ##
      # @param [Hash{RDF::Statement => Array<Dot>}] adds
      # @param [Hash{RDF::Statement => Hash{Dot => Dot}}] removes
      # @param [Hash{String => Integer}] clock
      def initialize(adds:, removes:, clock:)
        @adds    = adds
        @removes = removes
        @clock   = clock
      end

      ##
      # @return [Boolean] true if the delta carries no events
      def empty?
        @adds.empty? && @removes.empty?
      end
    end

    ##
    # Returns the unique identifier of this replica.
    #
    # @return [String]
    attr_reader :replica_id

    ##
    # @param [String, #to_s] replica_id (SecureRandom.uuid)
    #   A unique identifier for this replica. It MUST be distinct from
    #   the identifier of every other replica of the same dataset;
    #   reusing replica identifiers breaks convergence guarantees.
    # @param [Hash{Symbol => Object}] options
    #   Options from {RDF::Repository#initialize}
    def initialize(replica_id: nil, **options, &block)
      @replica_id = (replica_id || SecureRandom.uuid).to_s
      @clock  = Hash.new(0) # version vector: replica id => max observed event counter
      @stable = Hash.new(0) # stable frontier acknowledged via #compact!
      @adds    = {} # statement => { Dot => true }
      @removes = {} # statement => { insert Dot => remove Dot }
      @canonical_nodes = {} # canonical blank node id => canonical RDF::Node
      @local_bnodes    = {} # local blank node id => canonical blank node id
      super(**options, &block)
    end

    ##
    # Returns this replica's current version vector: the highest event
    # counter observed from every known replica.
    #
    # @return [Hash{String => Integer}]
    def version_vector
      @clock.dup
    end

    ##
    # Returns the stable frontier acknowledged so far via {#compact!}.
    #
    # @return [Hash{String => Integer}]
    def stable_frontier
      @stable.dup
    end

    ##
    # Merges the complete CRDT state of another replica into this one.
    #
    # The operation is commutative, associative and idempotent.
    #
    # @param  [RDF::MergeableRepository] other
    # @return [self]
    def merge(other)
      raise ArgumentError, "can only merge another RDF::MergeableRepository" unless other.is_a?(MergeableRepository)
      apply_state(other.send(:export_adds), other.send(:export_removes))
      merge_clock(other.version_vector)
      merge_stable(other.stable_frontier)
      self
    end

    ##
    # Returns a delta of all events not covered by the given version
    # vector, typically the version vector of the replica the delta will
    # be sent to.
    #
    # @note The caller must ensure this replica has not compacted
    #   tombstones for events that version_vector has not observed;
    #   this is guaranteed when compaction only uses frontiers known to
    #   be stable across all replicas (see {#compact!}).
    #
    # @param  [Hash{String => Integer}] version_vector
    # @return [Delta]
    def delta_since(version_vector = {})
      adds = {}
      @adds.each do |statement, dots|
        fresh = dots.keys.select { |dot| dot.counter > (version_vector[dot.replica] || 0) }
        adds[statement] = fresh unless fresh.empty?
      end
      removes = {}
      @removes.each do |statement, entries|
        fresh = entries.select { |_add_dot, rem_dot| rem_dot.counter > (version_vector[rem_dot.replica] || 0) }
        removes[statement] = fresh unless fresh.empty?
      end
      Delta.new(adds: adds, removes: removes, clock: version_vector)
    end

    ##
    # Applies a delta produced by {RDF::MergeableRepository#delta_since}
    # on another replica.
    #
    # @param  [Delta] delta
    # @return [self]
    def merge_delta(delta)
      apply_state(delta.adds, delta.removes)
      merge_clock(delta.clock)
      self
    end

    ##
    # Garbage-collects tombstones covered by the given stable frontier.
    #
    # A tombstone may only be dropped once its remove event is *stable*,
    # i.e. known to have been observed by every replica. Passing a
    # frontier that some replica has not yet reached may cause removed
    # statements to resurrect when that replica eventually merges.
    #
    # @param  [Hash{String => Integer}] frontier
    #   a version vector such that every replica has observed all events
    #   it covers
    # @return [self]
    def compact!(frontier)
      @removes.each do |statement, entries|
        entries.delete_if do |add_dot, rem_dot|
          next false unless (frontier[rem_dot.replica] || 0) >= rem_dot.counter
          # The remove is stable everywhere, and the insert causally
          # precedes it, so the insert dot can be dropped as well.
          if (dots = @adds[statement])
            dots.delete(add_dot)
            @adds.delete(statement) if dots.empty?
          end
          true
        end
      end
      @removes.delete_if { |_statement, entries| entries.empty? }
      merge_stable(frontier)
      self
    end

    ##
    # Returns the number of tombstones currently retained.
    #
    # @return [Integer]
    def tombstone_count
      @removes.inject(0) { |memo, (_statement, entries)| memo + entries.size }
    end

    ##
    # @private
    # @see RDF::Enumerable#supports?
    def supports?(feature)
      feature.to_sym == :mergeable || super
    end

    ##
    # @private
    # @see RDF::Countable#count
    def count
      count = 0
      @adds.each do |statement, dots|
        count += 1 if visible?(statement, dots)
      end
      count
    end

    ##
    # @private
    # @see RDF::Enumerable#statement?
    def statement?(statement)
      statement = canonicalize_statement(RDF::Statement.from(statement))
      visible?(statement, @adds[statement])
    end
    alias_method :has_statement?, :statement?

    ##
    # @private
    # @see RDF::Enumerable#each_statement
    def each_statement(&block)
      if block_given?
        @adds.each do |statement, dots|
          yield statement if visible?(statement, dots)
        end
      end
      enum_statement
    end
    alias_method :each, :each_statement

    protected

    ##
    # @private
    # @see RDF::Mutable#insert_statement
    def insert_statement(statement)
      statement = canonicalize_statement(statement)
      raise ArgumentError, "Statement #{statement.inspect} is incomplete" if statement.incomplete?
      dot = next_dot
      (@adds[statement] ||= {})[dot] = true
      self
    end

    ##
    # @private
    # @see RDF::Mutable#delete_statement
    def delete_statement(statement)
      statement = canonicalize_statement(statement)
      dots = @adds[statement]
      return self unless dots
      entries = (@removes[statement] ||= {})
      observed = dots.keys.reject { |dot| entries.key?(dot) }
      return self if observed.empty?
      rem_dot = next_dot
      observed.each { |dot| entries[dot] = rem_dot }
      self
    end

    ##
    # @private
    # @see RDF::Mutable#clear_statements
    def clear_statements
      each_statement { |statement| delete_statement(statement) }
    end

    ##
    # @private
    # @return [Hash{RDF::Statement => Array<Dot>}]
    def export_adds
      adds = {}
      @adds.each { |statement, dots| adds[statement] = dots.keys }
      adds
    end

    ##
    # @private
    # @return [Hash{RDF::Statement => Hash{Dot => Dot}}]
    def export_removes
      removes = {}
      @removes.each { |statement, entries| removes[statement] = entries.dup }
      removes
    end

    private

    ##
    # @private
    # @return [Boolean] true if the statement has at least one insert dot
    #   that has not been observed-removed
    def visible?(statement, dots)
      return false unless dots
      entries = @removes[statement]
      dots.keys.any? { |dot| !(entries && entries.key?(dot)) }
    end

    ##
    # @private
    # @return [Dot] the next dot for a local event
    def next_dot
      counter = @clock[@replica_id] + 1
      @clock[@replica_id] = counter
      Dot.new(@replica_id, counter)
    end

    ##
    # @private
    def observe_dot(dot)
      @clock[dot.replica] = dot.counter if dot.counter > @clock[dot.replica]
    end

    ##
    # @private
    def merge_clock(clock)
      clock.each { |replica, counter| @clock[replica] = counter if counter > @clock[replica] }
    end

    ##
    # @private
    def merge_stable(frontier)
      frontier.each { |replica, counter| @stable[replica] = counter if counter > @stable[replica] }
    end

    ##
    # @private
    def apply_state(adds, removes)
      adds.each do |statement, dots|
        statement = intern_statement(statement)
        entry = (@adds[statement] ||= {})
        dots.each do |dot|
          entry[dot] = true
          observe_dot(dot)
        end
      end
      removes.each do |statement, entries|
        statement = intern_statement(statement)
        target = (@removes[statement] ||= {})
        entries.each do |add_dot, rem_dot|
          if (existing = target[add_dot])
            # Deterministically retain the smallest remove dot so that
            # replicas converge on identical internal state.
            target[add_dot] = rem_dot if (dot_key(rem_dot) <=> dot_key(existing)) < 0
          else
            target[add_dot] = rem_dot
          end
          observe_dot(rem_dot)
        end
      end
      self
    end

    ##
    # @private
    def dot_key(dot)
      [dot.replica, dot.counter]
    end

    ##
    # Canonicalizes blank nodes in a statement produced by a *local*
    # operation. Blank nodes minted locally are mapped to a canonical
    # node whose identifier is namespaced by this replica's replica_id,
    # giving them a collision-free internal identity across replicas.
    # Blank nodes that already carry a canonical identity (e.g.
    # statements copied from another replica) are kept as-is.
    #
    # @private
    def canonicalize_statement(statement)
      subject   = canonicalize_term(statement.subject)
      predicate = canonicalize_term(statement.predicate)
      object    = canonicalize_term(statement.object)
      graph     = statement.graph_name && canonicalize_term(statement.graph_name)
      if subject.equal?(statement.subject) &&
         predicate.equal?(statement.predicate) &&
         object.equal?(statement.object) &&
         graph.equal?(statement.graph_name)
        statement
      else
        RDF::Statement.new(subject, predicate, object, graph_name: graph)
      end
    end

    ##
    # @private
    def canonicalize_term(term)
      case term
      when RDF::Statement
        canonicalize_statement(term)
      when RDF::Node
        id = term.id.to_s
        if (node = @canonical_nodes[id])
          node
        elsif id.start_with?(BNODE_ID_PREFIX)
          # Already carries a canonical identity (e.g. a statement
          # copied from another replica); adopt it unchanged.
          @canonical_nodes[id] = term
        elsif (canonical_id = @local_bnodes[id])
          @canonical_nodes[canonical_id]
        else
          canonical_id = "#{BNODE_ID_PREFIX}#{@replica_id}:#{id}"
          @local_bnodes[id] = canonical_id
          @canonical_nodes[canonical_id] ||= RDF::Node.new(canonical_id)
        end
      else
        term
      end
    end

    ##
    # Unifies blank nodes in a statement received through a merge with
    # this replica's canonical node registry, so that equal blank node
    # identities are always the same object internally. Unlike
    # {#canonicalize_statement}, no new identities are minted: merged
    # statements already carry canonical blank nodes.
    #
    # @private
    def intern_statement(statement)
      subject   = intern_term(statement.subject)
      predicate = intern_term(statement.predicate)
      object    = intern_term(statement.object)
      graph     = statement.graph_name && intern_term(statement.graph_name)
      if subject.equal?(statement.subject) &&
         predicate.equal?(statement.predicate) &&
         object.equal?(statement.object) &&
         graph.equal?(statement.graph_name)
        statement
      else
        RDF::Statement.new(subject, predicate, object, graph_name: graph)
      end
    end

    ##
    # @private
    def intern_term(term)
      case term
      when RDF::Statement
        intern_statement(term)
      when RDF::Node
        id = term.id.to_s
        (@canonical_nodes[id] ||= term)
      else
        term
      end
    end
  end
end
