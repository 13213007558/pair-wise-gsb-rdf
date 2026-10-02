require_relative 'spec_helper'

describe RDF::Query::Provenance do
  subject(:provenance) {RDF::Query::Provenance}

  let(:a) {provenance.atom(:a)}
  let(:b) {provenance.atom(:b)}
  let(:c) {provenance.atom(:c)}

  describe '.atom' do
    it 'interns atoms for equal symbols' do
      expect(provenance.atom(:a)).to equal provenance.atom(:a)
    end
  end

  describe '.sum and .product' do
    it 'flattens nested expressions' do
      expect(provenance.sum(provenance.sum(a, b), c)).to equal provenance.sum(a, b, c)
      expect(provenance.product(provenance.product(a, b), c)).to equal provenance.product(a, b, c)
    end

    it 'drops identities' do
      expect(a + provenance.zero).to equal a
      expect(a * provenance.one).to equal a
    end

    it 'returns identities for empty expressions' do
      expect(provenance.sum).to be_zero
      expect(provenance.product).to be_one
    end

    it 'does not simplify square terms' do
      expect((a * a).factors).to eq [a, a]
    end

    it 'does not deduplicate sum terms' do
      expect((a + a).terms).to eq [a, a]
    end
  end

  describe 'structural sharing' do
    it 'shares identical sub-expressions' do
      shared = a + b
      expr = shared * shared
      expect(expr.factors.first).to equal shared
      expect(expr.factors.last).to equal shared
    end
  end

  describe '#evaluate' do
    it 'substitutes counts' do
      expr = (a + b) * c
      expect(expr.evaluate({a: 1, b: 2, c: 3})).to eq 9
    end

    it 'counts derivations with a callable environment' do
      expr = (a * a) + (a * b)
      expect(expr.evaluate(->(symbol) { 1 })).to eq 2
    end

    it 'evaluates square terms without simplification' do
      expect((a * a).evaluate({a: 3})).to eq 9
    end

    it 'raises KeyError for missing symbols' do
      expect { a.evaluate({}) }.to raise_error(KeyError)
    end

    it 'evaluates identities' do
      expect(provenance.one.evaluate).to eq 1
      expect(provenance.zero.evaluate).to eq 0
    end
  end

  describe '#evaluate_boolean' do
    it 'substitutes booleans' do
      expr = (a * b) + c
      expect(expr.evaluate_boolean({a: true, b: false, c: true})).to be true
      expect(expr.evaluate_boolean({a: true, b: false, c: false})).to be false
    end
  end

  describe '#symbols' do
    it 'returns the distinct symbols used' do
      expect(((a * b) + (a * c)).symbols).to contain_exactly(:a, :b, :c)
    end
  end

  describe '#to_s' do
    it 'prints products binding tighter than sums' do
      expect(((a * b) + c).to_s).to eq 'a * b + c'
      expect((a * (b + c)).to_s).to eq 'a * (b + c)'
    end

    it 'prints identities' do
      expect(provenance.one.to_s).to eq '1'
      expect(provenance.zero.to_s).to eq '0'
    end
  end
end

describe 'RDF::Query provenance' do
  let(:ex) {RDF::Vocabulary.new('http://example.org/')}

  let(:count_derivations) {->(symbol) { 1 }}

  let(:graph) do
    graph = RDF::Graph.new
    graph << [ex.a, ex.p, ex.b]
    graph << [ex.b, ex.p, ex.c]
    graph << [ex.a, ex.p, ex.d]
    graph
  end

  context 'with a single pattern' do
    subject(:query) do
      ex_uri = ex
      RDF::Query.new { pattern [:s, ex_uri.p, :o] }
    end

    it 'annotates each solution with an atom per matched statement' do
      solutions = query.execute(graph, provenance: true)
      expect(solutions.size).to eq 3
      solutions.each do |solution|
        expect(solution.provenance).to be_a RDF::Query::Provenance::Atom
        expect(solution.provenance.evaluate(count_derivations)).to eq 1
      end
    end

    it 'leaves provenance unset without the option' do
      expect(query.execute(graph).map(&:provenance)).to all be_nil
    end
  end

  context 'with joined patterns' do
    subject(:query) do
      ex_uri = ex
      RDF::Query.new do
        pattern [:x, ex_uri.p, :y]
        pattern [:y, ex_uri.p, :z]
      end
    end

    it 'multiplies the provenance of joined statements' do
      solutions = query.execute(graph, provenance: true)
      expect(solutions.size).to eq 1
      provenance = solutions.first.provenance
      expect(provenance).to be_a RDF::Query::Provenance::Product
      expect(provenance.factors.size).to eq 2
      expect(provenance.evaluate(count_derivations)).to eq 1
      expect(provenance.symbols.size).to eq 2
    end
  end

  context 'with a self-join using the same statement twice' do
    subject(:query) do
      ex_uri = ex
      RDF::Query.new do
        pattern [:x, ex_uri.p, :y]
        pattern [:x, ex_uri.p, :y]
      end
    end

    it 'keeps a square term for the reused statement' do
      solutions = query.execute(graph, provenance: true)
      expect(solutions.size).to eq 3
      solutions.each do |solution|
        provenance = solution.provenance
        expect(provenance).to be_a RDF::Query::Provenance::Product
        expect(provenance.factors.size).to eq 2
        expect(provenance.factors.first).to equal provenance.factors.last
        statement = provenance.symbols.first
        expect(provenance.evaluate({statement => 2})).to eq 4
        expect(provenance.evaluate(count_derivations)).to eq 1
      end
    end
  end

  context 'with alternative derivations of equal bindings' do
    let(:repository) do
      repository = RDF::Repository.new
      repository << RDF::Statement(ex.a, ex.p, ex.b)
      repository << RDF::Statement(ex.a, ex.p, ex.b, graph_name: ex.g)
      repository
    end

    subject(:query) do
      ex_uri = ex
      RDF::Query.new { pattern [:s, ex_uri.p, :o] }
    end

    it 'merges provenance instead of dropping derivations' do
      solutions = query.execute(repository, provenance: true)
      expect(solutions.size).to eq 1
      provenance = solutions.first.provenance
      expect(provenance).to be_a RDF::Query::Provenance::Sum
      expect(provenance.terms.size).to eq 2
      expect(provenance.evaluate(count_derivations)).to eq 2
      expect(provenance.symbols.size).to eq 2
    end

    it 'keeps duplicate solutions without the option' do
      expect(query.execute(repository).size).to eq 2
    end
  end

  context 'with a custom symbol mapper' do
    it 'uses the mapped symbols' do
      ex_uri = ex
      query = RDF::Query.new { pattern [:s, ex_uri.p, :o] }
      solutions = query.execute(graph, provenance: ->(statement) { statement.subject })
      expect(solutions.map {|solution| solution.provenance.symbol}).to contain_exactly(ex.a, ex.b, ex.a)
    end
  end

  context 'with an unmatched optional pattern' do
    subject(:query) do
      ex_uri = ex
      RDF::Query.new do
        pattern [:s, ex_uri.p, :o]
        pattern [:s, ex_uri.q, :x], optional: true
      end
    end

    it 'keeps the provenance of the required matches' do
      solutions = query.execute(graph, provenance: true)
      expect(solutions.size).to eq 3
      solutions.each do |solution|
        expect(solution.provenance).to be_a RDF::Query::Provenance::Atom
        expect(solution.provenance.evaluate(count_derivations)).to eq 1
      end
    end
  end

  context 'with an empty query' do
    it 'annotates the empty solution with the multiplicative identity' do
      solutions = RDF::Query.new.execute(graph, provenance: true)
      expect(solutions.size).to eq 1
      expect(solutions.first.provenance).to be_one
      expect(solutions.first.provenance.evaluate).to eq 1
    end
  end
end

describe RDF::Query::Solution do
  describe '#merge' do
    it 'carries the provenance over to the merged solution' do
      expr = RDF::Query::Provenance.atom(:s)
      solution = RDF::Query::Solution.new(a: RDF::URI('http://example.org/a'))
      solution.provenance = expr
      expect(solution.merge(b: RDF::URI('http://example.org/b')).provenance).to equal expr
      expect(solution.dup.provenance).to equal expr
    end
  end
end
