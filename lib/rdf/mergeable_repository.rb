# frozen_string_literal: true

require 'securerandom'
require 'stringio'
require 'digest'

require 'rdf/repository'
require 'rdf/nquads'

module RDF
  # A mergeable in-memory repository using observed-remove semantics.
  class MergeableRepository < Repository
    INTERNAL_NODE_EXPRESSION = /\Ar-[0-9a-f]+-\d+-\d+\z/

    attr_reader :replica_id

    def initialize(replica_id: nil, state: nil, **options, &block)
      @replica_id = (replica_id || SecureRandom.uuid).to_s
      @state = normalize_state(state)
      @local_nodes = ObjectSpace::WeakMap.new
      super(**options, &block)
    end

    def replica_version
      versions.fetch(replica_id, 0)
    end

    def versions
      @state[:versions]
    end

    def full_state
      export_state(versions: true)
    end
    alias_method :state, :full_state

    def delta(since: nil)
      since = normalize_versions(since)
      export_state(versions: true, since: since)
    end

    def merge!(other)
      other = normalize_state(other)
      is_delta = other.key?(:since)
      other_since = is_delta ? normalize_versions(other[:since]) : {}
      other[:versions].each do |replica, point|
        versions[replica] = [versions.fetch(replica, 0), point].max
      end

      other[:node_versions].each do |replica, point|
        node_versions[replica] = [node_versions.fetch(replica, 0), point].max
      end

      other[:entries].each do |quad, tokens|
        next if is_delta && !token_after?(tokens, other_since)
        add_tokens(quad).concat(tokens)
        add_tokens(quad).sort!
        add_tokens(quad).uniq!
      end

      other[:tombstones].each do |tombstone|
        next if is_delta && tombstone[:point] <= other_since.fetch(tombstone[:replica], 0)
        tombstones << tombstone unless tombstones.include?(tombstone)
      end

      other[:guard].each do |token|
        guard << token unless guard.include?(token)
      end
      guard.sort!

      self
    end
    alias_method :merge, :merge!

    def compact_tombstones!(stable_frontier)
      stable_frontier = normalize_versions(stable_frontier)
      stable_frontier.each do |replica, point|
        raise ArgumentError, "stable frontier is ahead of known state" if point > versions.fetch(replica, 0)
      end

      retained_tombstones = []
      tombstones.each do |tombstone|
        stable = tombstone[:point] <= stable_frontier.fetch(tombstone[:replica], 0) &&
          tombstone[:adds].all? do |replica, point|
            point <= stable_frontier.fetch(replica, 0)
          end

        if stable
          tombstone[:adds].each do |token|
            guard << token unless guard.include?(token)
          end
        else
          retained_tombstones << tombstone
        end
      end
      guard.sort!

      entries.keep_if { |_, tokens| removed_tokens(tokens).any? }
      @state[:tombstones] = retained_tombstones
      self
    end

    def supports?(feature)
      case feature.to_sym
      when :merge, :observed_remove, :snapshots, :atomic_write, :rdf_full, :base_direction
        true
      else
        super
      end
    end

    def statement?(statement)
      return super unless statement.is_a?(RDF::Statement)
      active_entries.key?(encode_quad(map_known_statement(statement)))
    end

    def graph?(graph_name)
      each_graph.any? do |graph|
        graph.graph_name == (graph_name == false ? nil : graph_name)
      end
    end

    def graph_names(unique: true)
      names = active_entries.keys.map { |quad| decode_quad(quad).graph_name }.compact
      unique ? names.uniq : names
    end

    def each_graph(&block)
      return enum_graph unless block_given?

      names = graph_names
      if active_entries.any? { |quad, _| default_graph?(quad) }
        yield RDF::Graph.new(graph_name: nil, data: self)
      end
      names.each do |name|
        yield RDF::Graph.new(graph_name: name, data: self)
      end
    end

    protected

    def each_statement(&block)
      return enum_statement unless block_given?

      active_entries.each_key do |quad|
        yield decode_quad(quad)
      end
      self
    end
    alias_method :each, :each_statement

    def query_pattern(pattern, **_options, &block)
      return enum_for(:query_pattern, pattern) unless block_given?

      each_statement do |statement|
        next if pattern.graph_name == false && statement.graph_name
        yield statement if pattern === statement
      end
    end

    def insert_statements(statements)
      mapped = map_insert_statements(statements)
      add_statements(mapped)
    end

    def insert_statement(statement)
      add_statements([map_statement(statement)])
    end

    def delete_statements(statements)
      concrete = []
      enumerate_statements(statements) do |statement|
        if statement.variable?
          query(statement).each { |matched| concrete << matched }
        elsif !statement.incomplete? || statement.graph_name == false
          concrete << statement
        end
      end
      delete_statement_set(concrete)
    end

    def delete_statement(statement)
      if statement.respond_to?(:variable?) && statement.variable?
        delete_statements(statement)
      else
        delete_statement_set([statement])
      end
    end

    def clear_statements
      delete_statement_set(active_entries.keys.map { |quad| decode_quad(quad) })
    end

    def apply_changeset(changeset)
      deletes = []
      changeset.deletes.each do |statement|
        if statement.variable?
          query(statement).each { |matched| deletes << matched }
        elsif !statement.incomplete? || statement.graph_name == false
          deletes << statement
        end
      end

      insert_statements = changeset.inserts.each_statement.to_a
      insert_statements.each { |statement| validate_statement(statement) }
      inserts = map_insert_statements(insert_statements)
      inserts.each { |statement| validate_statement(statement) }

      delete_statement_set(deletes)
      add_statements(inserts)
      self
    end

    def snapshot
      RDF::Dataset.new(statements: statements).freeze
    end
    public :apply_changeset, :snapshot

    def node_versions
      @state[:node_versions]
    end

    def entries
      @state[:entries]
    end

    def tombstones
      @state[:tombstones]
    end

    def guard
      @state[:guard]
    end

    def add_tokens(quad)
      entries[quad] ||= []
    end

    def blank_state
      {
        replica_id: replica_id,
        versions: {},
        node_versions: {},
        entries: {},
        tombstones: [],
        guard: []
      }
    end

    def normalize_versions(versions)
      (versions || {}).each_with_object({}) do |(replica, point), normalized|
        normalized[replica.to_s] = point.to_i
      end
    end

    def normalize_state(state)
      state = state || blank_state
      normalized = blank_state
      normalized[:replica_id] = state_value(state, :replica_id, replica_id).to_s
      normalized[:versions] = normalize_versions(state_value(state, :versions))
      normalized[:node_versions] = normalize_versions(state_value(state, :node_versions))
      normalized[:guard] = state_value(state, :guard, []).map { |token| normalize_token(token) }.sort.uniq

      state_value(state, :entries, {}).each do |quad, tokens|
        normalized[:entries][quad.to_s] = tokens.map { |token| normalize_token(token) }.sort.uniq
      end

      state_value(state, :tombstones, []).each do |tombstone|
        normalized[:tombstones] <<= {
          quad: state_value(tombstone, :quad).to_s,
          replica: state_value(tombstone, :replica).to_s,
          point: state_value(tombstone, :point).to_i,
          adds: state_value(tombstone, :adds).map { |token| normalize_token(token) }.sort
        }
      end
      normalized[:tombstones].uniq!
      normalized
    end

    def state_value(state, key, default = nil)
      state[key] || state[key.to_s] || default
    end

    def normalize_token(token)
      [token.first.to_s, token.last.to_i]
    end

    def export_state(versions:, since: nil)
      since ||= {}
      state = {
        replica_id: replica_id,
        versions: versions ? self.versions.dup : {},
        node_versions: self.node_versions.dup,
        entries: {},
        tombstones: [],
        guard: []
      }

      entries.each do |quad, tokens|
        filtered = tokens.select { |token| token.last > since.fetch(token.first, 0) }
        state[:entries][quad] = filtered.dup unless filtered.empty?
      end

      tombstones.each do |tombstone|
        next unless tombstone[:point] > since.fetch(tombstone[:replica], 0)
        state[:tombstones] <<= tombstone.merge(adds: tombstone[:adds].dup)
      end

      guard.each do |token|
        state[:guard] << token.dup if token.last > since.fetch(token.first, 0)
      end

      state[:since] = since unless since.empty?
      state
    end

    def token_after?(tokens, since)
      tokens.any? { |replica, point| point > since.fetch(replica, 0) }
    end

    def active_entries
      entries.select { |quad, tokens| removed_tokens(tokens).any? }
    end

    def active_tokens(quad)
      removed_tokens(entries.fetch(quad, []))
    end

    def removed_tokens(tokens)
      tokens.reject { |token| guard.include?(token) || tombstone_removed?(token) }
    end

    def tombstone_removed?(token)
      tombstones.any? do |tombstone|
        tombstone[:adds].include?(token)
      end
    end

    def add_statements(statements, validate: true)
      statements.each do |statement|
        validate_statement(statement) if validate
        quad = encode_quad(statement)
        next unless active_tokens(quad).empty?

        point = versions[replica_id] = versions.fetch(replica_id, 0) + 1
        token = [replica_id, point]
        add_tokens(quad) << token unless add_tokens(quad).include?(token)
      end
      self
    end

    def delete_statement_set(statements)
      tombstones_by_quad = {}

      statements.each do |statement|
        next if statement.respond_to?(:incomplete?) && statement.incomplete? && statement.graph_name != false
        mapped = map_known_statement(statement)
        quad = encode_quad(mapped)
        tokens = active_tokens(quad)
        tombstones_by_quad[quad] = tokens if tokens.any?
      end

      return self if tombstones_by_quad.empty?

      point = versions[replica_id] = versions.fetch(replica_id, 0) + 1
      tombstones_by_quad.each do |quad, tokens|
        tombstone = {quad: quad, replica: replica_id, point: point, adds: tokens.dup.sort}
        tombstones << tombstone unless tombstones.include?(tombstone)
      end
      self
    end

    def validate_statement(statement)
      raise ArgumentError, "Statement #{statement.inspect} is incomplete" if statement.incomplete?
    end

    def enumerate_statements(statements, &block)
      if statements.respond_to?(:each_statement)
        statements.each_statement(&block)
      elsif statements.respond_to?(:each)
        statements.each do |value|
          block.call(value.is_a?(RDF::Statement) ? value : RDF::Statement.from(value))
        end
      else
        block.call(statements.is_a?(RDF::Statement) ? statements : RDF::Statement.from(statements))
      end
    end

    def map_insert_statements(statements)
      mapped = []
      enumerate_statements(statements) do |statement|
        mapped << map_statement(statement)
      end
      mapped.uniq { |statement| encode_quad(statement) }
    end

    def map_statement(statement)
      mapped = statement.dup
      mapped.subject = map_term(mapped.subject)
      mapped.predicate = map_term(mapped.predicate)
      mapped.object = map_term(mapped.object)
      mapped.graph_name = map_term(mapped.graph_name) if mapped.graph_name
      mapped
    end

    def map_term(term)
      return term unless term.is_a?(RDF::Node)
      original = term.original || term
      internal = @local_nodes[original]
      return internal if internal
      return term if internal_node?(term)

      internal = new_internal_node(original)
      @local_nodes[original] = internal
      internal
    end

    def map_known_statement(statement)
      mapped = statement.dup
      mapped.subject = map_known_term(mapped.subject)
      mapped.predicate = map_known_term(mapped.predicate)
      mapped.object = map_known_term(mapped.object)
      mapped.graph_name = map_known_term(mapped.graph_name) if mapped.graph_name
      mapped
    end

    def map_known_term(term)
      return term unless term.is_a?(RDF::Node)
      original = term.original || term
      @local_nodes[original] || term
    end

    def new_internal_node(node)
      point = node_versions[replica_id] = node_versions.fetch(replica_id, 0) + 1
      id = "r-#{internal_replica_segment}-#{replica_version}-#{point}"
      internal = RDF::Node.new(id)
      @local_nodes[node] = internal
      internal
    end

    def internal_node?(node)
      node.id.match?(INTERNAL_NODE_EXPRESSION)
    end

    def internal_replica_segment
      Digest::SHA256.hexdigest(replica_id)
    end

    def encode_quad(statement)
      RDF::NQuads::Writer.new(validate: false).format_statement(statement)
    end

    def decode_quad(quad)
      reader = RDF::NQuads::Reader.new(quad, validate: false, rdfstar: true)
      RDF::Statement.from(reader.__send__(:read_statement))
    end

    def default_graph?(quad)
      decode_quad(quad).graph_name.nil?
    end

  end

  ObservedRemoveRepository = MergeableRepository
end
