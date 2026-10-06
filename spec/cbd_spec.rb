require_relative 'spec_helper'

describe RDF::CBD do
  let(:ex) { RDF::Vocabulary.new('http://example.org/') }

  def statement(s, p, o, graph_name: nil)
    RDF::Statement.new(s, p, o, graph_name: graph_name)
  end

  describe '.extract' do
    it 'raises ArgumentError unless the subject is a resource' do
      expect { described_class.extract(RDF::Dataset.new, 'not-a-term') }
        .to raise_error(ArgumentError)
    end

    it 'extracts all statements having the subject as subject' do
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p1, ex.o1),
        statement(ex.s, ex.p2, 'literal'),
        statement(ex.other, ex.p1, ex.o2),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.subject).to eq ex.s
      expect(result.statements).to contain_exactly(
        statement(ex.s, ex.p1, ex.o1),
        statement(ex.s, ex.p2, 'literal'),
      )
    end

    it 'keeps URI objects as references and reports them as boundary' do
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p, ex.o),
        statement(ex.o, ex.p, ex.unrelated),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.statements).to contain_exactly(statement(ex.s, ex.p, ex.o))
      expect(result.boundary).to contain_exactly(ex.o)
    end

    it 'does not report the root subject as a boundary reference' do
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p, ex.o),
        statement(ex.s, ex.p, ex.s),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.boundary).to contain_exactly(ex.o)
    end

    it 'recursively expands blank node objects' do
      node = RDF::Node.new
      leaf = RDF::Node.new
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p, node),
        statement(node, ex.name, 'blank'),
        statement(node, ex.knows, leaf),
        statement(leaf, ex.name, 'leaf'),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.statements).to contain_exactly(
        statement(ex.s, ex.p, node),
        statement(node, ex.name, 'blank'),
        statement(node, ex.knows, leaf),
        statement(leaf, ex.name, 'leaf'),
      )
      expect(result.boundary).to be_empty
    end

    it 'reports blank nodes having no description as boundary' do
      node = RDF::Node.new
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p, node),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.statements).to contain_exactly(statement(ex.s, ex.p, node))
      expect(result.boundary).to contain_exactly(node)
    end

    it 'terminates on blank node cycles' do
      a = RDF::Node.new('a')
      b = RDF::Node.new('b')
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p, a),
        statement(a, ex.p, b),
        statement(b, ex.p, a),
      ])

      result = nil
      expect { result = described_class.extract(dataset, ex.s) }.not_to raise_error
      expect(result.statements).to contain_exactly(
        statement(ex.s, ex.p, a),
        statement(a, ex.p, b),
        statement(b, ex.p, a),
      )
    end

    it 'includes the description of a shared blank node exactly once' do
      shared = RDF::Node.new('shared')
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p1, shared),
        statement(ex.s, ex.p2, shared),
        statement(shared, ex.name, 'shared'),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.statements).to contain_exactly(
        statement(ex.s, ex.p1, shared),
        statement(ex.s, ex.p2, shared),
        statement(shared, ex.name, 'shared'),
      )
      expect(result.statements.count(statement(shared, ex.name, 'shared'))).to eq 1
    end

    it 'includes classic reifications of statements in the description' do
      reifier = RDF::Node.new('r')
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p, ex.o),
        statement(reifier, RDF.type, RDF[:Statement]),
        statement(reifier, RDF.subject, ex.s),
        statement(reifier, RDF.predicate, ex.p),
        statement(reifier, RDF.object, ex.o),
        statement(reifier, ex.certainty, 0.5),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.statements).to contain_exactly(
        statement(ex.s, ex.p, ex.o),
        statement(reifier, RDF.type, RDF[:Statement]),
        statement(reifier, RDF.subject, ex.s),
        statement(reifier, RDF.predicate, ex.p),
        statement(reifier, RDF.object, ex.o),
        statement(reifier, ex.certainty, 0.5),
      )
    end

    it 'ignores incomplete classic reifications' do
      reifier = RDF::Node.new('r')
      dataset = RDF::Dataset.new(statements: [
        statement(ex.s, ex.p, ex.o),
        statement(reifier, RDF.subject, ex.s),
        statement(reifier, RDF.predicate, ex.p),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.statements).to contain_exactly(statement(ex.s, ex.p, ex.o))
    end

    it 'includes triple-term descriptions of statements in the description' do
      embedded = statement(ex.s, ex.p, ex.o)
      annotator = RDF::Node.new('a')
      dataset = RDF::Dataset.new(statements: [
        embedded,
        statement(annotator, ex.source, embedded),
        statement(annotator, ex.retrieved, 'today'),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.statements).to contain_exactly(
        embedded,
        statement(annotator, ex.source, embedded),
        statement(annotator, ex.retrieved, 'today'),
      )
    end

    it 'closes over shared blank nodes and triple-term descriptions' do
      shared = RDF::Node.new('shared')
      embedded = statement(ex.s, ex.p, shared)
      annotator = RDF::Node.new('a')
      dataset = RDF::Dataset.new(statements: [
        embedded,
        statement(ex.s, ex.q, shared),
        statement(shared, ex.name, 'shared'),
        statement(shared, ex.link, ex.outside),
        statement(annotator, ex.source, embedded),
        statement(annotator, ex.verified, true),
      ])

      result = described_class.extract(dataset, ex.s)

      expect(result.statements).to contain_exactly(
        embedded,
        statement(ex.s, ex.q, shared),
        statement(shared, ex.name, 'shared'),
        statement(shared, ex.link, ex.outside),
        statement(annotator, ex.source, embedded),
        statement(annotator, ex.verified, true),
      )
      expect(result.boundary).to contain_exactly(ex.outside)
    end

    context 'with multiple named graphs' do
      let(:g1) { ex.g1 }
      let(:g2) { ex.g2 }
      let(:node) { RDF::Node.new('n') }
      let!(:dataset) do
        RDF::Dataset.new(statements: [
          statement(ex.s, ex.p1, ex.o1, graph_name: g1),
          statement(ex.s, ex.p2, node, graph_name: g2),
          statement(ex.s, ex.p3, ex.o3),
          statement(node, ex.name, 'in g1', graph_name: g1),
          statement(node, ex.name, 'in g2', graph_name: g2),
        ])
      end

      it 'applies dataset semantics by default, preserving graph attribution' do
        result = described_class.extract(dataset, ex.s)

        expect(result.statements).to contain_exactly(
          statement(ex.s, ex.p1, ex.o1, graph_name: g1),
          statement(ex.s, ex.p2, node, graph_name: g2),
          statement(ex.s, ex.p3, ex.o3),
          statement(node, ex.name, 'in g1', graph_name: g1),
          statement(node, ex.name, 'in g2', graph_name: g2),
        )
        expect(result.statements.map(&:graph_name)).to contain_exactly(g1, g2, nil, g1, g2)
      end

      it 'restricts extraction to a single named graph on demand' do
        result = described_class.extract(dataset, ex.s, graph_name: g1)

        expect(result.statements).to contain_exactly(
          statement(ex.s, ex.p1, ex.o1, graph_name: g1),
        )
        expect(result.boundary).to contain_exactly(ex.o1)
      end

      it 'expands blank nodes within the selected graph only' do
        result = described_class.extract(dataset, ex.s, graph_name: g2)

        expect(result.statements).to contain_exactly(
          statement(ex.s, ex.p2, node, graph_name: g2),
          statement(node, ex.name, 'in g2', graph_name: g2),
        )
        expect(result.boundary).to be_empty
      end

      it 'restricts extraction to the default graph with graph_name: false' do
        result = described_class.extract(dataset, ex.s, graph_name: false)

        expect(result.statements).to contain_exactly(
          statement(ex.s, ex.p3, ex.o3),
        )
        expect(result.boundary).to contain_exactly(ex.o3)
      end
    end
  end

  describe RDF::CBD::Result do
    let(:dataset) do
      RDF::Dataset.new(statements: [
        statement(ex.s, ex.p, ex.o, graph_name: ex.g),
      ])
    end
    subject(:result) { RDF::CBD.extract(dataset, ex.s) }

    it 'is enumerable over the extracted statements' do
      expect(result.to_a).to eq result.statements
      expect(result.count).to eq 1
    end

    it 'converts to a dataset preserving graph attribution' do
      converted = result.to_dataset
      expect(converted).to be_a(RDF::Dataset)
      expect(converted.to_a).to contain_exactly(
        statement(ex.s, ex.p, ex.o, graph_name: ex.g),
      )
    end
  end

  describe RDF::Queryable do
    it 'extracts a CBD through the #cbd convenience method' do
      repository = RDF::Repository.new
      repository << statement(ex.s, ex.p, ex.o)

      result = repository.cbd(ex.s)

      expect(result).to be_a(RDF::CBD::Result)
      expect(result.statements).to contain_exactly(statement(ex.s, ex.p, ex.o))
      expect(result.boundary).to contain_exactly(ex.o)
    end
  end
end
