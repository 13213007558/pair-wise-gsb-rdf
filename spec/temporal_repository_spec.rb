require_relative 'spec_helper'

describe RDF::TemporalRepository do
  subject(:repository) { described_class.new }

  let(:graph) { RDF::URI('http://example.org/graph') }
  let(:alice) { RDF::URI('http://example.org/alice') }
  let(:bob) { RDF::URI('http://example.org/bob') }
  let(:knows) { RDF::URI('http://example.org/knows') }
  let(:employed_by) { RDF::URI('http://example.org/employedBy') }
  let(:acme) { RDF::URI('http://example.org/Acme') }
  let(:person) { RDF::URI('http://example.org/Person') }
  let(:type) { RDF.type }

  describe '#insert_valid and #retract' do
    it 'merges overlapping intervals for the same quad' do
      repository.insert_valid([alice, knows, bob, graph], 1...10)
      repository.insert_valid([alice, knows, bob, graph], 8...15)

      expect(repository.statements.first.options[:valid_intervals]).to eq [1...15]
    end

    it 'splits an interval when retracting its middle' do
      repository.insert_valid(alice, employed_by, acme, graph_name: graph,
                                                 valid_time: 1...20)
      repository.retract([alice, employed_by, acme, graph], 8...12)

      expect(repository.statements.first.options[:valid_intervals]).to eq [1...8, 12...20]
    end

    it 'keeps intervals of different quads separate' do
      repository.insert_valid([alice, knows, bob], 1...10)
      repository.insert_valid([alice, knows, bob, graph], 1...10)
      repository.insert_valid([alice, employed_by, acme], 1...10)

      expect(repository.count).to eq 3
    end

    it 'accepts half-open intervals given as start and finish pairs' do
      repository.insert_valid([alice, knows, bob, graph], [4, 8])
      repository.retract([alice, knows, bob, graph], [6, 7])

      expect(repository.statements.first.options[:valid_intervals]).to eq [4...6, 7...8]
    end

    it 'applies one interval to multiple statements' do
      repository.insert([alice, knows, bob], [alice, employed_by, acme], valid_time: 1...5)

      expect(repository.statements.map(&:valid_time)).to contain_exactly(1...5, 1...5)
    end

    it 'accepts a statement carrying a single valid_time option' do
      statement = RDF::Statement.new(alice, knows, bob, valid_time: 1...5)
      repository.insert(statement)

      expect(repository.statements.first.valid_time).to eq 1...5
    end

    it 'rejects closed or empty intervals' do
      expect { repository.insert_valid([alice, knows, bob], 1..10) }
        .to raise_error(ArgumentError)
      expect { repository.insert_valid([alice, knows, bob], 5...5) }
        .to raise_error(ArgumentError)
      expect { repository.insert_valid([alice, knows, bob], 10...1) }
        .to raise_error(ArgumentError)
    end
  end

  describe '#query' do
    before do
      repository.insert_valid([alice, employed_by, acme], 1...8)
      repository.insert_valid([alice, employed_by, acme], 12...20)
    end

    it 'queries facts valid at a point using half-open interval boundaries' do
      expect(repository.query([nil, employed_by, nil], at: 0)).to be_empty
      expect(repository.query([nil, employed_by, nil], at: 1).count).to eq 1
      expect(repository.query([nil, employed_by, nil], at: 8)).to be_empty
      expect(repository.query([nil, employed_by, nil], at: 12).count).to eq 1
      expect(repository.query([nil, employed_by, nil], at: 20)).to be_empty
    end

    it 'returns each common fragment when querying an interval' do
      results = repository.query([alice, employed_by, acme], during: 5...15)

      expect(results.map { |statement| statement.options[:valid_intervals] })
        .to eq [[5...8], [12...15]]
    end

    it 'accepts valid_time as an alias for during' do
      results = repository.query([alice, employed_by, acme], valid_time: 5...15)

      expect(results.map { |statement| statement.valid_time }).to eq [5...8, 12...15]
    end

    it 'accepts time and valid_during query aliases' do
      expect(repository.query([alice, employed_by, acme], time: 12).count).to eq 1
      expect(repository.query([alice, employed_by, acme], valid_during: 12...13).first.valid_time)
        .to eq 12...13
    end

    it 'omits facts with no overlap with the queried interval' do
      expect(repository.query([alice, employed_by, acme], during: 8...12)).to be_empty
    end

    it 'queries named and default graphs independently' do
      repository.insert_valid([alice, employed_by, acme, graph], 1...10)

      expect(repository.query([nil, nil, nil, graph], at: 5).count).to eq 1
      expect(repository.query([nil, nil, nil, false], at: 5).count).to eq 1
      expect(repository.query([nil, nil, nil, nil], at: 5).count).to eq 2
    end
  end

  describe 'basic graph patterns' do
    before do
      repository.insert_valid([alice, type, person], 1...20)
      repository.insert_valid([alice, employed_by, acme], 1...10)
      repository.insert_valid([alice, employed_by, acme], 15...25)
      repository.insert_valid([bob, type, person], 3...18)
      repository.insert_valid([bob, employed_by, acme], 5...22)
    end

    let(:query) do
      RDF::Query.new do |pattern|
        pattern.pattern [:person, type, person]
        pattern.pattern [:person, employed_by, acme]
      end
    end

    it 'intersects valid intervals across all patterns' do
      solutions = repository.query(query)
      results = solutions.map { |solution| [solution.person, solution.valid_time] }

      expect(results).to contain_exactly(
        [alice, [1...10, 15...20]],
        [bob, 5...18]
      )
    end

    it 'clips the common intervals to the query interval' do
      solutions = repository.query(query, during: 8...16)
      results = solutions.map { |solution| [solution.person, solution.valid_time] }

      expect(results).to contain_exactly(
        [alice, [8...10, 15...16]],
        [bob, 8...16]
      )
    end

    it 'filters by a point without pairing unrelated intersecting records' do
      solutions = repository.query(query, at: 12)
      people = solutions.map(&:person)
      intervals = solutions.map(&:valid_intervals)

      expect(people).to contain_exactly(bob)
      expect(intervals).to contain_exactly([5...18])
    end

    it 'does not merge interval fragments into one broad solution' do
      alice_solutions = repository.query(query, during: 0...30).to_a.select do |solution|
        solution.person == alice
      end

      expect(alice_solutions.map(&:valid_time)).to eq [[1...10, 15...20]]
    end

    it 'returns a temporal solution for an empty query' do
      result = described_class.new.query(RDF::Query.new)

      expect(result.count).to eq 1
      expect(result.first).to be_a(RDF::Repository::TemporalImplementation::TemporalSolution)
    end
  end

  describe 'ordinary repository compatibility' do
    it 'is opt-in through the temporal option' do
      expect(described_class.new.supports?(:temporal)).to be true
      expect(RDF::Repository.new.supports?(:temporal)).to be false
      expect(RDF::Repository.new(temporal: true).supports?(:temporal)).to be true
    end

    it 'freezes snapshots without reading through future mutations' do
      repository.insert_valid([alice, knows, bob], 1...10)
      snapshot = repository.snapshot
      repository.retract([alice, knows, bob], 1...10)

      expect(snapshot.query([alice, knows, bob], at: 5).count).to eq 1
      expect(repository.query([alice, knows, bob], at: 5)).to be_empty
    end

    it 'supports temporal statements in serializable transactions' do
      statement = RDF::Statement.new(alice, knows, bob, valid_intervals: [1...10])

      repository.transaction(mutable: true) do |transaction|
        transaction.insert(statement)
      end

      expect(repository.query([alice, knows, bob], at: 5).count).to eq 1
    end
  end
end
