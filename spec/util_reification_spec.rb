require_relative 'spec_helper'

describe RDF::Util::Reification do
  def uri(name)
    RDF::URI("http://example.org/#{name}")
  end

  # A triple term referenced twice (in the default graph and in a named
  # graph), a nested triple term, a blank node, and native reification
  # data which must survive the round-trip untouched.
  let(:inner)  {RDF::Statement(uri(:s1), uri(:p1), uri(:o1), tripleTerm: true)}
  let(:nested) {RDF::Statement(uri(:s2), uri(:p2), inner, tripleTerm: true)}
  let(:bnode)  {RDF::Node.new(:keep)}
  let(:native) {uri(:native)}
  let(:graph)  {uri(:g1)}

  let(:native_quads) do
    [
      RDF::Statement(native, RDF[:type],      RDF[:Statement]),
      RDF::Statement(native, RDF[:subject],   uri(:s1)),
      RDF::Statement(native, RDF[:predicate], uri(:p1)),
      RDF::Statement(native, RDF[:object],    uri(:o1)),
    ]
  end

  let(:statements) do
    [
      RDF::Statement(uri(:a), uri(:believes), inner),
      RDF::Statement(uri(:b), uri(:believes), inner, graph_name: graph),
      RDF::Statement(uri(:c), uri(:claims),   nested, graph_name: graph),
      RDF::Statement(bnode,   uri(:p),        RDF::Literal(1)),
      *native_quads,
    ]
  end

  let(:original)  {RDF::Dataset.new(statements: statements)}
  let(:converted_and_mapping) {described_class.convert(original)}
  let(:converted) {converted_and_mapping.first}
  let(:mapping)   {converted_and_mapping.last}
  let(:restored)  {described_class.restore(converted, mapping)}

  def quads(dataset)
    dataset.each_statement.map(&:to_quad)
  end

  describe ".convert" do
    it "removes all triple terms" do
      converted.each_statement do |statement|
        expect(statement.subject).not_to be_a(RDF::Statement)
        expect(statement.object).not_to be_a(RDF::Statement)
      end
    end

    it "reuses the same resource for equal triple terms" do
      objects = converted.each_statement.select {|s| s.predicate == uri(:believes)}.map(&:object)
      expect(objects.length).to eq 2
      expect(objects.first).to eq objects.last
      expect(objects.first).to be_node
    end

    it "emits reification quads for each referenced triple term" do
      resource = converted.each_statement.find {|s| s.subject == uri(:a)}.object
      expect(converted).to have_statement(RDF::Statement(resource, RDF[:type],      RDF[:Statement]))
      expect(converted).to have_statement(RDF::Statement(resource, RDF[:subject],   uri(:s1)))
      expect(converted).to have_statement(RDF::Statement(resource, RDF[:predicate], uri(:p1)))
      expect(converted).to have_statement(RDF::Statement(resource, RDF[:object],    uri(:o1)))
    end

    it "emits reification quads only once per graph for repeated references" do
      resource = converted.each_statement.find {|s| s.subject == uri(:a)}.object
      types = converted.each_statement.select do |s|
        s.subject == resource && s.predicate == RDF[:type]
      end
      expect(types.map {|s| s.graph_name || false}.sort_by(&:to_s)).to eq [false, graph]
    end

    it "reifies nested triple terms recursively" do
      outer = converted.each_statement.find {|s| s.subject == uri(:c)}.object
      inner_resource = converted.each_statement.find {|s|
        s.subject == outer && s.predicate == RDF[:object]
      }.object
      expect(inner_resource).to be_node
      expect(converted).to have_statement(
        RDF::Statement(inner_resource, RDF[:subject], uri(:s1), graph_name: graph))
    end

    it "preserves graph names" do
      statement = converted.each_statement.find {|s| s.subject == uri(:b)}
      expect(statement.graph_name).to eq graph
    end

    it "preserves blank nodes" do
      expect(converted).to have_statement(RDF::Statement(bnode, uri(:p), RDF::Literal(1)))
    end

    it "returns a mapping from generated resources to original triple terms" do
      expect(mapping.values).to contain_exactly(inner, nested)
      resource = converted.each_statement.find {|s| s.subject == uri(:a)}.object
      expect(mapping[resource]).to eq inner
    end
  end

  describe ".restore" do
    it "round-trips the dataset exactly" do
      expect(quads(restored)).to match_array(quads(original))
    end

    it "restores nested triple terms" do
      statement = restored.each_statement.find {|s| s.subject == uri(:c)}
      expect(statement.object).to eq nested
      expect(statement.object.object).to eq inner
    end

    it "does not consume native rdf:Statement data" do
      native_quads.each do |quad|
        expect(restored).to have_statement(quad)
      end
    end

    it "only restores what is in the mapping" do
      dataset = RDF::Dataset.new(statements: native_quads)
      expect(quads(described_class.restore(dataset, {}))).to match_array(quads(dataset))
    end
  end
end

