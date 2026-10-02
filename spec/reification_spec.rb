require 'spec_helper'

describe RDF::Reification do
  let(:ex) { RDF::Vocabulary.new('http://example.org/') }

  # <<(:a :knows :b)>>, referenced twice (default graph and named graph)
  let(:inner)  { RDF::Statement(ex.a, ex.knows, ex.b) }
  # <<(:c :believes <<(:a :knows :b)>>>>, a nested triple term
  let(:nested) { RDF::Statement(ex.c, ex.believes, inner) }
  let(:bnode)  { RDF::Node('shared') }
  # A triple term carrying a blank node, to check blank-node scope
  let(:bn_term) { RDF::Statement(bnode, ex.likes, ex.d) }
  # Native reification data present in the input, not to be consumed
  let(:user_reif) { RDF::Node('userReif') }

  let(:statements) do
    [
      RDF::Statement(ex.s1, ex.p1, inner,  graph_name: nil),
      RDF::Statement(ex.s2, ex.p2, inner,  graph_name: ex.g1),
      RDF::Statement(ex.s3, ex.p3, nested, graph_name: ex.g2),
      RDF::Statement(bnode, ex.p4, bn_term),
      RDF::Statement(ex.s5, ex.p5, ex.o5,  graph_name: ex.g1),
      # Native rdf:Statement reification data
      RDF::Statement(user_reif, RDF.type,      RDF[:Statement]),
      RDF::Statement(user_reif, RDF.subject,   ex.x),
      RDF::Statement(user_reif, RDF.predicate, ex.y),
      RDF::Statement(user_reif, RDF.object,    ex.z),
    ]
  end

  let(:dataset) { RDF::Dataset.new(statements: statements) }
  let(:result)  { described_class.transform(dataset) }
  let(:rdf11)   { result.first }
  let(:mapping) { result.last }

  describe '.transform' do
    it 'returns a dataset and a mapping' do
      expect(rdf11).to be_a(RDF::Dataset)
      expect(mapping).to be_a(Hash)
      expect(mapping.values).to all(be_a(RDF::Statement))
    end

    it 'removes all triple terms' do
      rdf11.each do |statement|
        expect(statement.subject).not_to be_a(RDF::Statement)
        expect(statement.object).not_to be_a(RDF::Statement)
      end
    end

    it 'reuses one resource for equal triple terms' do
      expect(mapping.values.count(inner)).to eq(1)
      resources = mapping.each_with_object({}) { |(r, t), h| h[t] = r }
      s1 = rdf11.query([ex.s1, ex.p1, nil]).first.object
      s2 = rdf11.query([ex.s2, ex.p2, nil]).first.object
      expect(s1).to eq(resources[inner])
      expect(s2).to eq(resources[inner])
      expect(s1).to eql(s2)
    end

    it 'reifies nested triple terms onto separate resources' do
      expect(mapping.values).to include(inner, nested, bn_term)
      outer = mapping.key(nested)
      inner_res = mapping.key(inner)
      # The outer reification refers to the inner resource, not a triple term
      expect(rdf11.query([outer, RDF.subject, nil]).first.object).to eq(ex.c)
      expect(rdf11.query([outer, RDF.object, nil]).first.object).to eq(inner_res)
    end

    it 'keeps statements in their named graphs' do
      expect(rdf11.query([ex.s2, ex.p2, nil]).first.graph_name).to eq(ex.g1)
      expect(rdf11.query([ex.s3, ex.p3, nil]).first.graph_name).to eq(ex.g2)
      expect(rdf11.query([ex.s1, ex.p1, nil]).first.graph_name).to be_nil
    end

    it 'adds reification quads to the graphs referencing the term' do
      res = mapping.key(inner)
      graphs = rdf11.each_statement.select { |st|
        st.subject.eql?(res) && st.predicate.eql?(RDF.type)
      }.map(&:graph_name)
      expect(graphs).to contain_exactly(nil, ex.g1, ex.g2)
    end

    it 'preserves blank node identity and scope' do
      res = mapping.key(bn_term)
      expect(rdf11.query([res, RDF.subject, nil]).first.object).to eql(bnode)
      expect(rdf11.query([bnode, ex.p4, nil]).count).to eq(1)
    end

    it 'leaves native reification data untouched' do
      expect(rdf11.query([user_reif, nil, nil]).count).to eq(4)
      expect(mapping).not_to have_key(user_reif)
    end
  end

  describe '.restore' do
    let(:restored) { described_class.restore(rdf11, mapping) }

    it 'round-trips the dataset' do
      expect(restored.each_statement.to_set).to eq(dataset.each_statement.to_set)
    end

    it 'restores nested and repeated references' do
      expect(restored.query([ex.s1, ex.p1, nil]).first.object).to eql(inner)
      expect(restored.query([ex.s3, ex.p3, nil]).first.object).to eql(nested)
    end

    it 'does not consume native rdf:Statement data' do
      expect(restored.query([user_reif, nil, nil]).count).to eq(4)
      expect(restored.query([user_reif, RDF.subject, nil]).first.object).to eq(ex.x)
    end

    it 'removes only the generated reification quads' do
      mapping.each_key do |resource|
        expect(restored.query([resource, nil, nil])).to be_empty
      end
    end
  end
end
