require_relative 'spec_helper'

describe RDF::TemporalRepository do
  subject(:repo) { described_class.new }

  let(:s)  { RDF::URI('http://example.org/s') }
  let(:p)  { RDF::URI('http://example.org/p') }
  let(:p2) { RDF::URI('http://example.org/p2') }
  let(:o)  { RDF::URI('http://example.org/o') }
  let(:x)  { RDF::URI('http://example.org/x') }
  let(:statement)  { RDF::Statement.new(s, p, o) }
  let(:statement2) { RDF::Statement.new(o, p2, x) }

  def iv(start, finish)
    RDF::TemporalRepository::Interval.new(start, finish)
  end

  it "supports the :temporal feature" do
    expect(repo.supports?(:temporal)).to be true
  end

  it "is empty by default" do
    expect(repo).to be_empty
  end

  describe "inserting and retracting intervals" do
    it "records the valid interval of a quad" do
      repo.insert(statement, interval: [0, 10])
      expect(repo.intervals(statement)).to eq [iv(0, 10)]
      expect(repo).to have_statement(statement)
    end

    it "accepts Interval and Range objects" do
      repo.insert(statement, interval: iv(0, 5))
      repo.insert(statement2, interval: 0...5)
      expect(repo.intervals(statement)).to eq [iv(0, 5)]
      expect(repo.intervals(statement2)).to eq [iv(0, 5)]
    end

    it "rejects empty or negative intervals" do
      expect { repo.insert(statement, interval: [5, 5]) }.to raise_error(ArgumentError)
      expect { repo.insert(statement, interval: [7, 5]) }.to raise_error(ArgumentError)
    end

    it "merges overlapping intervals of the same quad" do
      repo.insert(statement, interval: [0, 10])
      repo.insert(statement, interval: [5, 15])
      expect(repo.intervals(statement)).to eq [iv(0, 15)]
    end

    it "merges adjacent intervals of the same quad" do
      repo.insert(statement, interval: [0, 5])
      repo.insert(statement, interval: [5, 10])
      expect(repo.intervals(statement)).to eq [iv(0, 10)]
    end

    it "keeps disjoint intervals separate and sorted" do
      repo.insert(statement, interval: [10, 15])
      repo.insert(statement, interval: [0, 5])
      expect(repo.intervals(statement)).to eq [iv(0, 5), iv(10, 15)]
    end

    it "tracks intervals per quad independently" do
      repo.insert(statement, interval: [0, 10])
      repo.insert(statement2, interval: [3, 7])
      expect(repo.intervals(statement)).to eq [iv(0, 10)]
      expect(repo.intervals(statement2)).to eq [iv(3, 7)]
    end

    it "splits an interval when a middle segment is retracted" do
      repo.insert(statement, interval: [0, 10])
      repo.delete(statement, interval: [3, 6])
      expect(repo.intervals(statement)).to eq [iv(0, 3), iv(6, 10)]
    end

    it "shrinks an interval when an edge is retracted" do
      repo.insert(statement, interval: [0, 10])
      repo.delete(statement, interval: [0, 3])
      expect(repo.intervals(statement)).to eq [iv(3, 10)]
    end

    it "ignores retracting a non-overlapping interval" do
      repo.insert(statement, interval: [0, 10])
      repo.delete(statement, interval: [20, 30])
      expect(repo.intervals(statement)).to eq [iv(0, 10)]
    end

    it "removes the quad when its last valid time is retracted" do
      repo.insert(statement, interval: [0, 10])
      repo.delete(statement, interval: [0, 10])
      expect(repo).to be_empty
      expect(repo.intervals(statement)).to eq []
    end

    it "retracts across multiple disjoint intervals" do
      repo.insert(statement, interval: [0, 5])
      repo.insert(statement, interval: [10, 15])
      repo.delete(statement, interval: [3, 12])
      expect(repo.intervals(statement)).to eq [iv(0, 3), iv(12, 15)]
    end

    it "retracts intervals from all quads matching a pattern" do
      repo.insert(statement, interval: [0, 10])
      repo.insert(statement2, interval: [0, 10])
      repo.delete([nil, nil, nil], interval: [0, 5])
      expect(repo.intervals(statement)).to eq [iv(5, 10)]
      expect(repo.intervals(statement2)).to eq [iv(5, 10)]
    end
  end

  describe "plain (non-temporal) inserts and deletes" do
    it "treats inserted statements as valid for all time" do
      repo << statement
      expect(repo.valid_at(-1_000_000).to_a).to eq [statement]
      expect(repo.valid_at(1_000_000).to_a).to eq [statement]
    end

    it "removes all valid time on delete" do
      repo.insert(statement, interval: [0, 10])
      repo.delete(statement)
      expect(repo).to be_empty
    end

    it "supports clear" do
      repo.insert(statement, interval: [0, 10])
      repo.clear
      expect(repo).to be_empty
    end
  end

  describe "point and interval queries" do
    before { repo.insert(statement, interval: [0, 10]) }

    it "finds statements valid at a point in time" do
      expect(repo.valid_at(0).to_a).to eq [statement]
      expect(repo.valid_at(9).to_a).to eq [statement]
    end

    it "uses half-open interval semantics" do
      expect(repo.valid_at(10).to_a).to be_empty
      expect(repo.valid_at(-1).to_a).to be_empty
    end

    it "finds statements valid during an interval" do
      expect(repo.valid_during(5, 15).to_a).to eq [statement]
      expect(repo.valid_during(-5, 0).to_a).to be_empty
      expect(repo.valid_during(10, 20).to_a).to be_empty
    end

    it "filters simple pattern queries by time" do
      expect(repo.query([s, p, o], at: 5).to_a).to eq [statement]
      expect(repo.query([s, p, o], at: 15).to_a).to be_empty
      expect(repo.query([s, p, o], during: [20, 30])).to be_empty
    end
  end

  describe "basic graph pattern joins" do
    let(:query) do
      pred1 = p
      pred2 = p2
      RDF::Query.new do
        pattern [:a, pred1, :mid]
        pattern [:mid, pred2, :b]
      end
    end

    it "joins patterns on the intersection of their valid intervals" do
      repo.insert(statement, interval: [0, 10])
      repo.insert(statement2, interval: [5, 15])
      solutions = repo.query(query).to_a
      expect(solutions.size).to eq 1
      expect(solutions.first[:a]).to eq s
      expect(solutions.first[:mid]).to eq o
      expect(solutions.first[:b]).to eq x
      expect(solutions.first.interval).to eq iv(5, 10)
    end

    it "produces no solution when the common valid time is empty" do
      repo.insert(statement, interval: [0, 10])
      repo.insert(statement2, interval: [10, 20])
      expect(repo.query(query).to_a).to be_empty
    end

    it "yields one solution per common interval" do
      repo.insert(statement, interval: [0, 5])
      repo.insert(statement, interval: [10, 15])
      repo.insert(statement2, interval: [3, 12])
      solutions = repo.query(query).to_a
      expect(solutions.map(&:interval)).to contain_exactly(iv(3, 5), iv(10, 12))
      expect(solutions.map { |sol| sol[:mid] }).to eq [o, o]
    end

    it "restricts joins to a point in time with at:" do
      repo.insert(statement, interval: [0, 10])
      repo.insert(statement2, interval: [5, 15])
      expect(repo.query(query, at: 7).to_a.size).to eq 1
      expect(repo.query(query, at: 12).to_a).to be_empty
    end

    it "clips joined intervals with during:" do
      repo.insert(statement, interval: [0, 10])
      repo.insert(statement2, interval: [5, 15])
      solutions = repo.query(query, during: [2, 8]).to_a
      expect(solutions.size).to eq 1
      expect(solutions.first.interval).to eq iv(5, 8)
    end

    it "annotates single-pattern queries with the valid interval" do
      repo.insert(statement, interval: [0, 10])
      solutions = repo.query(RDF::Query.new { pattern [:s, :p, :o] }).to_a
      expect(solutions.size).to eq 1
      expect(solutions.first.interval).to eq iv(0, 10)
    end

    it "intersects unbounded intervals from plain inserts" do
      repo << statement
      repo.insert(statement2, interval: [5, 15])
      solutions = repo.query(query).to_a
      expect(solutions.size).to eq 1
      expect(solutions.first.interval).to eq iv(5, 15)
    end
  end

  describe RDF::TemporalRepository::Interval do
    it "supports unbounded intervals" do
      eternal = described_class.new(nil, nil)
      expect(eternal).to be_eternal
      expect(eternal.contains?(0)).to be true
      expect(eternal.overlaps?(described_class.new(0, 1))).to be true
    end

    it "computes intersections" do
      expect(iv(0, 10).intersect(iv(5, 15))).to eq iv(5, 10)
      expect(iv(0, 10).intersect(iv(10, 20))).to be_nil
      expect(iv(0, 10).intersect(described_class.new(nil, nil))).to eq iv(0, 10)
    end

    it "subtracts intervals" do
      expect(iv(0, 10).subtract(iv(3, 6))).to eq [iv(0, 3), iv(6, 10)]
      expect(iv(0, 10).subtract(iv(20, 30))).to eq [iv(0, 10)]
      expect(iv(0, 10).subtract(iv(0, 10))).to eq []
    end
  end
end
