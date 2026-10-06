require_relative 'spec_helper'
require 'rdf/spec/transaction'

describe RDF::Transaction do
  let(:repository) { RDF::Repository.new }

  # @see lib/rdf/spec/transaction.rb in rdf-spec
  it_behaves_like "an RDF::Transaction", RDF::Transaction

  describe 'base implementation' do
    subject { described_class.new(repository, mutable: true) }

    describe "#insert" do
      let(:st) { RDF::Statement(:s, RDF::URI('p'), 'o') }
      
      it 'adds to inserts' do
        expect { subject.insert(st) }
          .to change { subject.changes.inserts }.to contain_exactly(st)
      end

      it 'adds multiple to inserts' do
        sts = [st] << RDF::Statement(:x, RDF::URI('y'), 'z')
        
        expect { subject.insert(*sts) }
          .to change { subject.changes.inserts }.to contain_exactly(*sts)
      end

      it 'adds enumerable to inserts' do
        sts = [st] << RDF::Statement(:x, RDF::URI('y'), 'z')
        sts.extend(RDF::Enumerable)

        expect { subject.insert(sts) }
          .to change { subject.changes.inserts }.to contain_exactly(*sts)
      end
    end
    
    describe '#delete' do
      let(:st) { RDF::Statement(:s, RDF::URI('p'), 'o') }

      it 'adds to deletes' do
        expect { subject.delete(st) }
          .to change { subject.changes.deletes }.to contain_exactly(st)
      end

      it 'adds multiple to deletes' do
        sts = [st] << RDF::Statement(:x, RDF::URI('y'), 'z')

        expect { subject.delete(*sts) }
          .to change { subject.changes.deletes }.to contain_exactly(*sts)
      end

      it 'adds enumerable to deletes' do
        sts = [st] << RDF::Statement(:x, RDF::URI('y'), 'z')
        sts.extend(RDF::Enumerable)

        expect { subject.delete(sts) }
          .to change { subject.changes.deletes }.to contain_exactly(*sts)
      end
    end

    describe 'mutated?' do
      it 'raises an error for subclasses' do
        class MyTx < described_class; end

        tx = MyTx.new(repository)

        expect { tx.mutated? }.to raise_error NotImplementedError
      end
    end

    describe '#execute' do
      it 'calls `changes#apply` with repository' do
        expect(subject.changes).to receive(:apply).with(subject.repository)
        subject.execute
      end
    end
  end
end

describe RDF::Transaction::SerializedTransaction do
  let(:repository) { RDF::Repository.new }

  # @see lib/rdf/spec/transaction.rb in rdf-spec
  it_behaves_like "an RDF::Transaction",  RDF::Transaction::SerializedTransaction

  describe 'serializable snapshot isolation' do
    let(:alice) { RDF::URI('http://example.org/alice') }
    let(:bob) { RDF::URI('http://example.org/bob') }
    let(:on_call) { RDF::URI('http://example.org/on-call') }
    let(:name) { RDF::Vocab::RDFS.label }

    def statement(subject, predicate, object)
      RDF::Statement.new(subject, predicate, object)
    end

    it 'keeps reading a stable snapshot after another transaction commits' do
      repository << statement(alice, name, 'Alice')
      transaction = described_class.new(repository)

      repository.transaction(mutable: true) do |other|
        other.insert(statement(bob, name, 'Bob'))
      end

      expect(transaction.statements).to contain_exactly(statement(alice, name, 'Alice'))
      expect(repository.statements).to include(statement(bob, name, 'Bob'))
      expect(transaction.read_set).to be_empty
      expect(transaction.execute).to be(true)
    end

    it 'does not copy the shared repository data for a read-only transaction' do
      repository << statement(alice, name, 'Alice')
      transaction = described_class.new(repository)

      expect(transaction.base_data).to equal(repository.send(:data))
      expect(transaction.mutable?).to be(false)
      expect(transaction.writable?).to be(false)
      transaction.statements
      expect(transaction.read_set).to be_empty
      expect(transaction.execute).to be(true)
    end

    it 'detects write skew through a non-empty predicate read' do
      repository << statement(alice, on_call, true)
      repository << statement(bob, on_call, true)
      pattern = RDF::Query::Pattern.new(nil, on_call, true)

      first = described_class.new(repository, mutable: true)
      second = described_class.new(repository, mutable: true)

      expect(first.query(pattern).count).to eq 2
      expect(second.query(pattern).count).to eq 2

      first.delete(statement(alice, on_call, true))
      second.delete(statement(bob, on_call, true))

      expect(first.execute).to be true
      error = nil
      begin
        second.execute
      rescue RDF::Transaction::SerializationError => error
      end

      expect(error).to be_a(RDF::Transaction::SerializationError)
      expect(error.conflicts.map { |conflict| conflict[:type] }).to contain_exactly(:read)
      expect(error.conflicts.map { |conflict| conflict[:pattern] }).to include(pattern)
      expect(repository).to have_statement(statement(bob, on_call, true))
      expect(repository).not_to have_statement(statement(alice, on_call, true))
    end

    it 'detects a phantom through a query that was empty when evaluated' do
      pattern = RDF::Query::Pattern.new(nil, name, nil)

      first = described_class.new(repository, mutable: true)
      second = described_class.new(repository, mutable: true)

      expect(first.query(pattern).to_a).to be_empty
      expect(second.query(pattern).to_a).to be_empty

      first.insert(statement(alice, name, 'Alice'))
      second.insert(statement(bob, name, 'Bob'))

      expect(second.execute).to be true
      error = nil
      begin
        first.execute
      rescue RDF::Transaction::SerializationError => error
      end

      expect(error).to be_a(RDF::Transaction::SerializationError)
      expect(error.conflicts).to contain_exactly(
        a_hash_including(
          type: :phantom,
          pattern: pattern,
          statement: statement(bob, name, 'Bob')
        )
      )
      expect(repository).not_to have_statement(statement(alice, name, 'Alice'))
      expect(repository).to have_statement(statement(bob, name, 'Bob'))
    end

    it 'detects a phantom after a constant existence read returned false' do
      pattern = RDF::Query::Pattern.from(statement(bob, name, 'Bob'))

      first = described_class.new(repository, mutable: true)
      second = described_class.new(repository, mutable: true)

      expect(first.statement?(statement(bob, name, 'Bob'))).to be(false)
      expect(second.statement?(statement(bob, name, 'Bob'))).to be(false)

      first.insert(statement(alice, name, 'Alice'))
      second.insert(statement(bob, name, 'Bob'))

      expect(second.execute).to be true
      expect { first.execute }.to raise_error(RDF::Transaction::SerializationError) do |error|
        expect(error.conflicts).to contain_exactly(
          a_hash_including(type: :phantom, pattern: pattern)
        )
      end
    end

    it 'scopes phantom checks to the transaction graph' do
      pattern = RDF::Query::Pattern.new(bob, name, nil, graph_name: false)

      first = described_class.new(repository, mutable: true, graph_name: false)
      second = described_class.new(repository, mutable: true, graph_name: false)

      expect(first.query(pattern).to_a).to be_empty
      expect(second.query(pattern).to_a).to be_empty

      first.insert(statement(alice, name, 'Alice'))
      second.insert(statement(bob, name, 'Bob'))

      expect(second.execute).to be true
      expect { first.execute }.to raise_error(RDF::Transaction::SerializationError) do |error|
        expect(error.conflicts.map { |conflict| conflict[:type] }).to contain_exactly(:phantom)
      end
    end

    it 'commits updates that touch disjoint statements' do
      repository << statement(alice, name, 'Alice')
      repository << statement(bob, name, 'Bob')
      alice_pattern = RDF::Query::Pattern.new(alice, name, nil)
      bob_pattern = RDF::Query::Pattern.new(bob, name, nil)

      first = described_class.new(repository, mutable: true)
      second = described_class.new(repository, mutable: true)

      expect(first.query(alice_pattern).count).to eq 1
      expect(second.query(bob_pattern).count).to eq 1

      first.delete(statement(alice, name, 'Alice'))
      second.insert(statement(bob, name, 'Robert'))

      expect(first.execute).to be true
      expect(second.execute).to be true
      expect(repository).to have_statement(statement(bob, name, 'Robert'))
      expect(repository).not_to have_statement(statement(alice, name, 'Alice'))
    end
  end
end
