require_relative 'spec_helper'

describe RDF::MergeableRepository do
  def uri(value)
    RDF::URI(value)
  end

  def stmt(s, o, p: "ex:p", graph_name: nil)
    RDF::Statement.new(uri(s), uri(p), o.is_a?(RDF::Term) ? o : uri(o), graph_name: graph_name)
  end

  def visible_quads(repo)
    repo.map { |st| st.to_quad.map(&:to_s) }.sort
  end

  let(:s1) { stmt("ex:s1", "ex:o1") }
  let(:s2) { stmt("ex:s2", "ex:o2") }
  let(:s3) { stmt("ex:s3", "ex:o3") }

  it "is a mutable repository" do
    repo = described_class.new
    expect(repo).to be_a(RDF::Repository)
    expect(repo).to be_mutable
    expect(repo).to be_readable
    expect(repo).to be_writable
    expect(repo.supports?(:mergeable)).to be true
  end

  it "generates unique replica ids by default" do
    expect(described_class.new.replica_id).not_to eq described_class.new.replica_id
  end

  describe "basic repository behavior" do
    subject(:repo) { described_class.new(replica_id: "r") }

    it "inserts, counts, queries and deletes statements" do
      repo.insert(s1)
      repo << s2
      expect(repo.count).to eq 2
      expect(repo).not_to be_empty
      expect(repo.statement?(s1)).to be true
      expect(repo.query([nil, uri("ex:p"), nil]).count).to eq 2
      repo.delete(s1)
      expect(repo.count).to eq 1
      expect(repo.statement?(s1)).to be false
    end

    it "deletes statements matching wildcard patterns" do
      repo.insert(s1)
      repo.insert(s2)
      repo.delete([nil, uri("ex:p"), nil])
      expect(repo).to be_empty
    end

    it "supports named graphs" do
      st = stmt("ex:s", "ex:o", graph_name: uri("ex:g"))
      repo.insert(st)
      expect(repo.graph_names).to contain_exactly(uri("ex:g"))
      expect(repo.statement?(st)).to be true
    end

    it "applies changesets" do
      repo.insert(s1)
      repo.apply_changeset(RDF::Changeset.new(delete: [s1], insert: [s2]))
      expect(repo.statement?(s1)).to be false
      expect(repo.statement?(s2)).to be true
    end
  end

  describe "observed-remove semantics" do
    let(:a) { described_class.new(replica_id: "a") }
    let(:b) { described_class.new(replica_id: "b") }

    it "removes statements observed by the deleting replica" do
      a.insert(s1)
      b.merge(a)
      b.delete(s1)
      a.merge(b)
      expect(a).to be_empty
      expect(b).to be_empty
    end

    it "keeps concurrent inserts from other replicas (add-wins)" do
      a.insert(s1)
      b.insert(s1)
      a.delete(s1) # only observes its own add
      a.merge(b)
      b.merge(a)
      expect(a.statement?(s1)).to be true
      expect(b.statement?(s1)).to be true
    end

    it "only retracts adds observed at delete time" do
      a.insert(s1)
      b.merge(a)
      b.delete(s1)  # observes a's add
      a.insert(s1)  # concurrent re-add, not observed by b's delete
      a.merge(b)
      b.merge(a)
      expect(a.statement?(s1)).to be true
      expect(b.statement?(s1)).to be true
    end

    it "treats re-insert after delete as a new add" do
      a.insert(s1)
      a.delete(s1)
      expect(a).to be_empty
      a.insert(s1)
      expect(a.statement?(s1)).to be true
    end

    it "clear only removes observed adds" do
      a.insert(s1)
      b.merge(a)
      b.clear
      a.insert(s2) # concurrent with b's clear
      a.merge(b)
      b.merge(a)
      expect(visible_quads(a)).to eq [s2.to_quad.map(&:to_s)]
      expect(visible_quads(b)).to eq [s2.to_quad.map(&:to_s)]
    end
  end

  describe "blank node identity" do
    let(:a) { described_class.new(replica_id: "a") }
    let(:b) { described_class.new(replica_id: "b") }

    it "does not collide same-labeled blank nodes from different replicas" do
      a.insert(RDF::Statement.new(RDF::Node.new("b1"), uri("ex:p"), uri("ex:o")))
      b.insert(RDF::Statement.new(RDF::Node.new("b1"), uri("ex:p"), uri("ex:o")))
      a.merge(b)
      b.merge(a)
      expect(a.count).to eq 2
      expect(b.count).to eq 2
      subjects = a.map { |st| st.subject.to_s }.sort
      expect(subjects).to eq ["_:rdf:mb:a:b1", "_:rdf:mb:b:b1"]
      expect(visible_quads(a)).to eq visible_quads(b)
    end

    it "preserves identity of blank nodes copied across replicas" do
      a.insert(RDF::Statement.new(RDF::Node.new("b1"), uri("ex:p"), uri("ex:o")))
      copied = a.first
      b.insert(copied) # insert a statement read from a, before any merge
      a.merge(b)
      b.merge(a)
      expect(a.count).to eq 1
      expect(b.count).to eq 1
      expect(b.first.subject.id).to eq copied.subject.id
    end

    it "keeps internal identity stable across merges and independent of serialization labels" do
      a.insert(RDF::Statement.new(RDF::Node.new, uri("ex:p"), uri("ex:o")))
      id_before = a.first.subject.id
      expect(id_before).to start_with described_class::BNODE_ID_PREFIX
      b.merge(a)
      a.merge(b)
      expect(a.first.subject.id).to eq id_before
      expect(b.first.subject.id).to eq id_before
    end

    it "resolves statements using the original blank node object" do
      node = RDF::Node.new("original")
      st = RDF::Statement.new(node, uri("ex:p"), uri("ex:o"))
      a.insert(st)
      expect(a.statement?(st)).to be true
      expect(a.statement?(RDF::Statement.new(RDF::Node.new("original"), uri("ex:p"), uri("ex:o")))).to be true
      a.delete(st)
      expect(a).to be_empty
    end
  end

  describe "full-state and delta merging" do
    let(:a) { described_class.new(replica_id: "a") }
    let(:b) { described_class.new(replica_id: "b") }

    it "tracks a version vector over all events" do
      a.insert(s1)
      a.delete(s1)
      expect(a.version_vector).to eq("a" => 2)
      b.insert(s2)
      a.merge(b)
      expect(a.version_vector).to eq("a" => 2, "b" => 1)
    end

    it "delta_since only carries events after the given version vector" do
      a.insert(s1)
      vv = a.version_vector
      a.insert(s2)
      a.delete(s1)
      delta = a.delta_since(vv)
      expect(delta.adds.keys.map(&:subject)).to eq [s2.subject]
      expect(delta.removes.keys.map(&:subject)).to eq [s1.subject]
      expect(a.delta_since(a.version_vector)).to be_empty
    end

    it "converges to the same state via full merge and via deltas" do
      full_a = described_class.new(replica_id: "a")
      full_b = described_class.new(replica_id: "b")
      delta_a = described_class.new(replica_id: "a")
      delta_b = described_class.new(replica_id: "b")

      [full_a, delta_a].each { |r| r.insert(s1); r.insert(s2) }
      [full_b, delta_b].each { |r| r.insert(s3); r.delete(s3) }

      full_a.merge(full_b)
      full_b.merge(full_a)

      2.times do
        delta_b.merge_delta(delta_a.delta_since(delta_b.version_vector))
        delta_a.merge_delta(delta_b.delta_since(delta_a.version_vector))
      end

      expect(visible_quads(delta_a)).to eq visible_quads(full_a)
      expect(visible_quads(delta_b)).to eq visible_quads(full_b)
      expect(delta_a.version_vector).to eq full_a.version_vector
    end

    it "is idempotent under duplicate merges" do
      a.insert(s1)
      b.insert(s2)
      3.times do
        a.merge(b)
        b.merge(a)
        a.merge_delta(b.delta_since({}))
      end
      expect(a.count).to eq 2
      expect(b.count).to eq 2
    end

    it "rejects merging foreign objects" do
      expect { a.merge(RDF::Repository.new) }.to raise_error(ArgumentError)
    end
  end

  describe "tombstone compaction" do
    let(:a) { described_class.new(replica_id: "a") }
    let(:b) { described_class.new(replica_id: "b") }

    it "retains tombstones until a stable frontier is given" do
      a.insert(s1)
      a.delete(s1)
      expect(a.tombstone_count).to eq 1
      a.compact!({})
      expect(a.tombstone_count).to eq 1
      a.compact!(a.version_vector.reject { |k, _| k == "a" })
      expect(a.tombstone_count).to eq 1
    end

    it "collects tombstones covered by the frontier without changing visible state" do
      a.insert(s1)
      a.insert(s2)
      a.delete(s1)
      before = visible_quads(a)
      a.compact!(a.version_vector)
      expect(a.tombstone_count).to eq 0
      expect(visible_quads(a)).to eq before
      expect(a.count).to eq 1
    end

    it "stays convergent when merging after compaction" do
      a.insert(s1)
      a.delete(s1)
      b.merge(a)
      a.merge(b)
      frontier = a.version_vector.merge(b.version_vector) { |_k, x, y| [x, y].min }
      a.compact!(frontier)
      b.compact!(frontier)
      b.insert(s2)
      a.merge(b)
      b.merge(a)
      expect(visible_quads(a)).to eq [s2.to_quad.map(&:to_s)]
      expect(visible_quads(b)).to eq [s2.to_quad.map(&:to_s)]
      expect(a.tombstone_count).to eq 0
    end
  end

  describe "three replicas with out-of-order, duplicate merges" do
    it "converges to identical visible quads" do
      a = described_class.new(replica_id: "a")
      b = described_class.new(replica_id: "b")
      c = described_class.new(replica_id: "c")

      s4 = RDF::Statement.new(RDF::Node.new("shared"), uri("ex:p"), uri("ex:o4"))
      s5 = stmt("ex:s5", "ex:o5")

      # Offline edits on each replica.
      a.insert(s1)
      a.insert(s2)
      b.insert(s2)
      b.insert(s3)
      c.insert(s4)

      # Partial sync: a and b see each other; c stays offline.
      a.merge(b)
      b.merge(a)

      # Concurrent offline edits.
      a.delete(s2) # observes both a's and b's adds of s2
      b.insert(s2) # concurrent re-add: must survive
      b.delete(s3) # removes b's own observed add
      c.delete(s4) # removes c's own blank node statement
      c.insert(s5)

      # A delta captured now is delivered late (and twice) below.
      stale_delta = a.delta_since({})

      # Out-of-order, duplicate full-state merges.
      b.merge(a)
      c.merge(b)
      a.merge(c)
      c.merge(a)
      b.merge(c)
      a.merge(b)
      b.merge(a)
      c.merge(b)
      a.merge(c)

      # Late, duplicate delta deliveries.
      c.merge_delta(stale_delta)
      c.merge_delta(stale_delta)
      b.merge_delta(a.delta_since(b.version_vector))
      a.merge_delta(b.delta_since(a.version_vector))
      c.merge_delta(a.delta_since(c.version_vector))

      expected = [s1, s2, s5].map { |st| st.to_quad.map(&:to_s) }.sort
      expect(visible_quads(a)).to eq expected
      expect(visible_quads(b)).to eq expected
      expect(visible_quads(c)).to eq expected

      # Version vectors converge as well.
      expect(a.version_vector).to eq b.version_vector
      expect(b.version_vector).to eq c.version_vector

      # Tombstones are retained until a stable frontier is known...
      expect(a.tombstone_count).to be > 0

      # ...then compaction with the common stable frontier (the
      # element-wise minimum of all version vectors) collects every
      # tombstone without changing the visible quads.
      frontier = a.version_vector.keys.inject({}) do |memo, replica|
        memo.merge(replica => [a, b, c].map { |r| r.version_vector[replica] || 0 }.min)
      end
      [a, b, c].each { |r| r.compact!(frontier) }
      expect(a.tombstone_count).to eq 0
      expect(b.tombstone_count).to eq 0
      expect(c.tombstone_count).to eq 0
      expect(visible_quads(a)).to eq expected
      expect(visible_quads(b)).to eq expected
      expect(visible_quads(c)).to eq expected
    end
  end
end
