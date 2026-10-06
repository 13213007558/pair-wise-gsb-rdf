require 'json'

require_relative 'spec_helper'

describe RDF::MergeableRepository do
  let(:a) { described_class.new(replica_id: 'a') }
  let(:b) { described_class.new(replica_id: 'b') }
  let(:c) { described_class.new(replica_id: 'c') }

  let(:quad_1) do
    RDF::Statement.new(
      RDF::URI('http://example.org/s1'),
      RDF::URI('http://example.org/p'),
      RDF::URI('http://example.org/o1'),
      graph_name: RDF::URI('http://example.org/g')
    )
  end

  let(:quad_2) do
    RDF::Statement.new(
      RDF::URI('http://example.org/s2'),
      RDF::URI('http://example.org/p'),
      RDF::URI('http://example.org/o2')
    )
  end

  let(:quad_3) do
    RDF::Statement.new(
      RDF::URI('http://example.org/s3'),
      RDF::URI('http://example.org/p'),
      RDF::URI('http://example.org/o3')
    )
  end

  def visible_quads(repository)
    repository.quads.map do |subject, predicate, object, graph_name|
      [subject.to_s, predicate.to_s, object.to_s, graph_name&.to_s]
    end.sort
  end

  it 'advertises merge support' do
    expect(a.supports?(:merge)).to be(true)
    expect(a.supports?(:observed_remove)).to be(true)
  end

  it 'enumerates default and named graphs from active quads' do
    a.insert(quad_1)
    a.insert(quad_2)

    expect(a.graph_names).to contain_exactly(quad_1.graph_name)
    expect(a).to have_graph(quad_1.graph_name)
    expect(a).to have_graph(false)
    expect(a.each_graph.to_a.map(&:graph_name)).to contain_exactly(nil, quad_1.graph_name)
  end

  it 'merges unordered and repeated deltas into identical visible quads' do
    a.insert(quad_1)
    a_frontier = {}
    a_after_1 = a.delta(since: a_frontier)
    a_frontier = a.versions.dup

    b.insert(quad_2)
    b_frontier = {}
    b.delta(since: b_frontier)
    b_frontier = b.versions.dup

    b.merge!(a_after_1)
    b.delete(quad_1)
    b_after_2 = b.delta(since: b_frontier)
    b_frontier = b.versions

    c.insert(quad_3)
    c_frontier = {}
    c_after_1 = c.delta(since: c_frontier)
    c_frontier = c.versions.dup

    a.merge!(b_after_2)
    a.merge!(c_after_1)
    a.insert(quad_2)
    a_after_2 = a.delta(since: a_frontier)
    a_frontier = a.versions.dup

    b.merge!(c_after_1)
    b.merge!(a_after_2)
    b.merge!(b_after_2)

    c.merge!(b_after_2)
    c.merge!(a_after_1)
    c.merge!(a_after_2)
    c.merge!(b_after_2)
    c.merge!(a_after_1)

    expect(visible_quads(a)).to eq visible_quads(c)
    expect(visible_quads(b)).to eq visible_quads(c)
    expect(visible_quads(a)).to contain_exactly(
      [quad_2.subject.to_s, quad_2.predicate.to_s, quad_2.object.to_s, nil],
      [quad_3.subject.to_s, quad_3.predicate.to_s, quad_3.object.to_s, nil]
    )
  end

  it 'merges full states idempotently' do
    a.insert(quad_1, quad_2)
    b.insert(quad_3)
    b.merge!(a.full_state)
    b.delete(quad_2)

    c.merge!(b.full_state)
    c.merge!(a.full_state)
    c.merge!(b.full_state)

    expect(visible_quads(a.merge!(b.full_state))).to eq visible_quads(c)
    expect(visible_quads(c)).to contain_exactly(
      [quad_1.subject.to_s, quad_1.predicate.to_s, quad_1.object.to_s, quad_1.graph_name.to_s],
      [quad_3.subject.to_s, quad_3.predicate.to_s, quad_3.object.to_s, nil]
    )
  end

  it 'compacts tombstones only after a stable frontier and ignores older adds' do
    a.insert(quad_1)
    first_add = a.full_state

    b.merge!(first_add)
    b.delete(quad_1)
    b_state = b.full_state

    a.merge!(b_state)
    frontier = a.versions.dup
    a.compact_tombstones!(frontier)

    expect(a).not_to have_statement(quad_1)

    c.merge!(a.full_state)
    c.merge!(first_add)

    expect(c).not_to have_statement(quad_1)
  end

  it 'does not compact a tombstone before the frontier covers every observed add' do
    a.insert(quad_1)
    b.insert(quad_1)
    b.merge!(a.full_state)
    b.delete(quad_1)

    expect do
      b.compact_tombstones!('a' => 1)
    end.not_to change { b.send(:tombstones).size }
  end

  it 'gives equal temporary blank node labels from different replicas distinct identities' do
    a_node = RDF::Node.new('temp')
    b_node = RDF::Node.new('temp')

    a.insert([a_node, RDF::URI('http://example.org/p'), RDF::URI('http://example.org/a')])
    b.insert([b_node, RDF::URI('http://example.org/p'), RDF::URI('http://example.org/b')])

    a.merge!(b.full_state)
    b.merge!(a.full_state)

    expect(a.subjects.select(&:node?)).to contain_exactly(*b.subjects.select(&:node?))
    expect(a.count).to eq 2
    expect(b.count).to eq 2
    expect(a.subjects.select(&:node?).first.id).to start_with('r-')
    expect(b.subjects.select(&:node?).map(&:id).sort).to eq(a.subjects.select(&:node?).map(&:id).sort)
  end

  it 'keeps a local blank node usable as the identity of its inserted fact' do
    node = RDF::Node.new('local-temp')
    statement = RDF::Statement.new(node, RDF::URI('http://example.org/p'), RDF::URI('http://example.org/o'))

    a.insert(statement)

    expect(a).to have_statement(statement)
    a.delete(statement)
    expect(a).to be_empty
  end

  it 'accepts state or delta encoded with string keys' do
    a.insert(quad_1)
    delta = JSON.parse(JSON.dump(a.delta(since: {})))

    expect { b.merge!(delta) }.not_to raise_error
    expect(b).to have_statement(quad_1)
  end
end
