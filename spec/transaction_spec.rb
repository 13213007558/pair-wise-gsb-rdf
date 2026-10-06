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
end

describe 'serializable snapshot transactions' do
  let(:repository) { RDF::Repository.new }

  let(:alice) { RDF::URI('http://example.org/alice') }
  let(:bob) { RDF::URI('http://example.org/bob') }
  let(:on_call) { RDF::URI('http://example.org/onCall') }
  let(:name) { RDF::URI('http://example.org/name') }

  def begin_serializable_transaction(repository, **options)
    repository.transaction(mutable: true, isolation: :serializable, **options)
  end

  def conflict_for
    yield
    nil
  rescue RDF::Transaction::ConflictError => error
    error
  end

  it 'detects write skew without relying on thread scheduling' do
    repository << [alice, on_call, true]
    repository << [bob, on_call, true]

    first = begin_serializable_transaction(repository)
    second = begin_serializable_transaction(repository)

    expect(first.query([nil, on_call, true]).to_a.size).to eq 2
    expect(second.query([nil, on_call, true]).to_a.size).to eq 2

    first.delete([alice, on_call, true])
    second.delete([bob, on_call, true])

    first.execute
    error = conflict_for { second.execute }

    expect(error).to be_a(RDF::Transaction::ConflictError)
    expect(error.conflict_type).to eq :write_skew
    expect(error.pattern).to eq RDF::Query::Pattern.new(nil, on_call, true)
    expect(error.statement).to eq RDF::Statement.new(alice, on_call, true)
    expect(repository.statement?(RDF::Statement.new(alice, on_call, true))).to be false
    expect(repository.statement?(RDF::Statement.new(bob, on_call, true))).to be true
  end

  it 'validates an empty query read set against a later matching insert' do
    first = begin_serializable_transaction(repository)
    second = begin_serializable_transaction(repository)

    expect(first.query([alice, name, nil]).to_a).to be_empty

    second.insert([alice, name, 'Alice'])
    second.execute

    error = conflict_for { first.execute }

    expect(error.conflict_type).to eq :phantom_read
    expect(error.pattern).to eq RDF::Query::Pattern.new(alice, name, nil)
    expect(error.statement).to eq RDF::Statement.new(alice, name, 'Alice')
    expect(repository.statement?(RDF::Statement.new(alice, name, 'Alice'))).to be true
  end

  it 'commits disjoint updates started from the same snapshot' do
    repository << [alice, on_call, true]

    first = begin_serializable_transaction(repository)
    second = begin_serializable_transaction(repository)

    first.insert([alice, name, 'Alice'])
    second.insert([bob, name, 'Bob'])

    expect { first.execute }.not_to raise_error
    expect { second.execute }.not_to raise_error

    expect(repository.statement?(RDF::Statement.new(alice, on_call, true))).to be true
    expect(repository.statement?(RDF::Statement.new(alice, name, 'Alice'))).to be true
    expect(repository.statement?(RDF::Statement.new(bob, name, 'Bob'))).to be true
  end

  it 'reports a direct write conflict with the conflicting statement pattern' do
    repository << [alice, on_call, true]

    first = begin_serializable_transaction(repository)
    second = begin_serializable_transaction(repository)

    first.delete([alice, on_call, true])
    second.delete([alice, on_call, true])

    first.execute
    error = conflict_for { second.execute }

    expect(error.conflict_type).to eq :write_conflict
    expect(error.pattern).to eq RDF::Query::Pattern.from(RDF::Statement.new(alice, on_call, true))
    expect(error.statement).to eq RDF::Statement.new(alice, on_call, true)
  end

  it 'keeps a stable read-only snapshot without copying the repository data' do
    repository << [alice, name, 'Alice']
    snapshot = repository.snapshot
    read_transaction = repository.transaction(isolation: :serializable)

    expect(read_transaction).to be_a(RDF::Transaction::SerializedTransaction)
    expect(read_transaction.mutable?).to be(false)
    expect(read_transaction.send(:read_target).send(:data)).to equal(snapshot.send(:data))
    expect(read_transaction.query([alice, name, nil]).to_a).to contain_exactly(
      RDF::Statement.new(alice, name, 'Alice')
    )

    repository.clear

    expect(read_transaction.query([nil, nil, nil]).to_a).to contain_exactly(
      RDF::Statement.new(alice, name, 'Alice')
    )
    expect(repository).to be_empty
  end

  it 'accepts the serializable shorthand option' do
    transaction = repository.transaction(serializable: true)

    expect(transaction).to be_a(RDF::Transaction::SerializedTransaction)
    expect(transaction.isolation_level).to eq :serializable
  end

  it 'does not retry a conflicting user transaction block' do
    attempts = 0
    repository << [alice, on_call, true]

    begin
      repository.transaction(mutable: true, isolation: :serializable) do |transaction|
        attempts += 1
        expect(transaction.query([alice, on_call, true]).to_a).not_to be_empty
        repository.insert([bob, on_call, true])
        transaction.insert([alice, name, 'Alice'])
      end
    rescue RDF::Transaction::ConflictError
    end

    expect(attempts).to eq 1
  end
end
