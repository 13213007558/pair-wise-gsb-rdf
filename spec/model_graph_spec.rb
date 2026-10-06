require_relative 'spec_helper'
require 'rdf/spec/enumerable'

describe RDF::Graph do
  describe ".load" do
    it "creates an unnamed graph" do
      expect(described_class).to receive(:new).with(graph_name: nil, base_uri: "http://example/")
      described_class.load("http://example/", base_uri: "http://example/")
    end

    it "loads into an unnamed graph" do
      expect_any_instance_of(described_class).to receive(:load).with("http://example/", graph_name: nil, base_uri: "http://example/")
      described_class.load("http://example/", base_uri: "http://example/")
    end
  end

  context "as method" do
    it "with keyword arg" do
      expect(described_class).to receive(:new).with(graph_name: "https://ruby-rdf.github.io/rdf/etc/doap.nt")
      RDF::Graph(graph_name: "https://ruby-rdf.github.io/rdf/etc/doap.nt")
    end

    it "with positional arg (removed)" do
      expect {
        RDF::Graph("https://ruby-rdf.github.io/rdf/etc/doap.nt")
      }.to raise_error(ArgumentError)
    end
  end

  context "unnamed graphs" do
    subject {described_class.new}

    it "should be instantiable" do
      expect { subject }.not_to raise_error
    end

    it "should be unnamed" do
      expect(subject).to be_unnamed
      expect(subject).not_to be_named
    end

    it "should not have a graph_name" do
      expect(subject.graph_name).to be_nil
      expect(subject.graph_names.size).to eq 0
    end
  end

  context "named graphs" do
    subject {
      described_class.new(graph_name: "https://ruby-rdf.github.io/rdf/etc/doap.nt", data: RDF::Repository.new)
    }
    it "should be instantiable" do
      expect { subject }.to_not raise_error
    end

    it "should not be instantiable with positional arg" do
      expect {
        described_class.new("https://ruby-rdf.github.io/rdf/etc/doap.nt", data: RDF::Repository.new)
      }.to raise_error(ArgumentError)
    end

    it "should not be instantiable by default" do
      expect { described_class.new(graph_name: "https://rubygems.org/gems/rdf") }.to raise_error(ArgumentError)
    end

    it "has statement in default graph" do
      st = RDF::Statement(RDF::URI('s'), RDF::URI('p'), RDF::URI('o'))
      subject << st
      expect(subject).to have_statement(st)
    end

    it "has statement with the same graph name" do
      st = RDF::Statement(RDF::URI('s'), RDF::URI('p'), RDF::URI('o'), graph_name: RDF::URI(subject.graph_name))
      subject << st
      expect(subject).to have_statement(st)
    end

    it "ignores graph name when finding statements" do
      st = RDF::Statement(RDF::URI('s'), RDF::URI('p'), RDF::URI('o'), graph_name: RDF::URI(RDF::URI('g')))
      subject << st
      expect(subject).to have_statement(st)
    end

    its(:named?) {is_expected.to be_truthy}
    its(:unnamed?) {is_expected.to be_falsey}
    its(:name) {is_expected.not_to be_nil}
    its(:graph_name) {is_expected.not_to be_nil}
    its(:graph_names) {expect(subject.graph_names.size).to eq 1}
    it {is_expected.not_to be_anonymous}

    context "with anonymous graph_name" do
      subject {described_class.new(graph_name: RDF::Node.new, data: RDF::Repository.new)}
      it {is_expected.to be_anonymous}
    end
  end

  context "with Repository as data" do
    let(:repo) {
      r = RDF::Repository.new
      r << [RDF::URI('s'), RDF::URI('p'), RDF::URI('o1')]
      r << [RDF::URI('s'), RDF::URI('p'), RDF::URI('o2'), RDF::URI('c')]
      r
    }
    it "should access default graph" do
      graph = described_class.new(data: repo)
      expect(graph.count).to eq 1
      expect(graph.statements.first.object).to eq RDF::URI('o1')
    end

    it "should access named graph" do
      graph = described_class.new(graph_name: RDF::URI('c'), data: repo)
      expect(graph.count).to eq 1
      expect(graph.statements.first.object).to eq RDF::URI('o2')
    end

    it "should not load! default graph" do
      graph = described_class.new(data: repo)
      expect {graph.load!}.to raise_error(ArgumentError)
    end

    it "should reload named graph" do
      graph = described_class.new(graph_name: RDF::URI("http://example/doc.nt"), data: repo)
      expect(graph).to receive(:load).with("http://example/doc.nt", base_uri: "http://example/doc.nt")
      graph.load!
    end

    it "should insert multiple statements as enumerable" do
      graph = described_class.new(graph_name: RDF::URI("http://example/doc.nt"), data: repo)
      expect(repo).to receive(:insert_statements).with(responding_to(:each))

      statements = [RDF::Statement(RDF::URI('s'), RDF::URI('p'), RDF::URI('o')),
                    RDF::Statement(RDF::URI('x'), RDF::URI('y'), RDF::URI('z'))]
      statements.extend(RDF::Enumerable)

      graph << statements
    end
  end

  it "should maintain arbitrary options" do
    graph = described_class.new(foo: :bar)
    expect(graph.options).to include(foo: :bar)
  end

  let(:countable)  { RDF::Graph.new }
  let(:enumerable) { RDF::Graph.new }
  let(:queryable)  { RDF::Graph.new }
  let(:mutable)    { RDF::Graph.new }

  context "when updating" do
    require 'rdf/spec/mutable'

    before { mutable.clear }
    it_behaves_like 'an RDF::Mutable'
  end

  context "when counting statements" do
    require 'rdf/spec/countable'
    it_behaves_like 'an RDF::Countable'
  end

  context "when enumerating statements" do
    require 'rdf/spec/enumerable'
    it_behaves_like 'an RDF::Enumerable'
  end

  context "as a transactable" do
    require 'rdf/spec/transactable'

    let(:transactable) { RDF::Graph.new }
    it_behaves_like 'an RDF::Transactable'

    context 'with graph_name' do
      let(:transactable) do 
        RDF::Graph.new graph_name: name, data: RDF::Repository.new
      end

      let(:name) { RDF::URI('g') }
      
      it_behaves_like 'an RDF::Transactable'

      it 'inserts to graph' do
        st = [RDF::URI('s'), RDF::URI('p'), 'o']
        expect { transactable.transaction(mutable: true) { insert(st) } }
          .to change { transactable.statements }.to contain_exactly(RDF::Statement.from(st, graph_name: name))
      end
      
      it 'deletes from graph' do
        st = [RDF::URI('s'), RDF::URI('p'), 'o']
        transactable.insert(st)

        expect { transactable.transaction(mutable: true) { delete(st) } }
          .to change { transactable.statements }.to be_empty
      end
    end
  end

  context "when querying statements" do
    require 'rdf/spec/queryable'
    it_behaves_like 'an RDF::Queryable'

    context 'with graph_name' do
      require 'rdf/spec/queryable'
      it_behaves_like 'an RDF::Queryable' do
        let(:queryable) do
          RDF::Graph.new(graph_name: RDF::URI('g'), data: RDF::Repository.new)
        end
      end
    end
  end

  context "Examples" do
    let(:graph) {described_class.new}

    it "Creating an empty unnamed graph" do
      expect {described_class.new}.not_to raise_error
    end

    it "Creating an empty named graph" do
      expect {described_class.new(graph_name: "https://rubygems.org/", data: RDF::Repository.new)}.not_to raise_error
    end

    it "Loading graph data from a URL (1)", skip: "requires RDF/XML" do
      require 'rdf/rdfxml'
      expect(RDF::Util::File).to receive(:open_file).
        with("http://www.bbc.co.uk/programmes/b0081dq5.rdf", an_instance_of(Hash)).
        and_yield(File.open(File.expand_path("../data/programmes.rdf", __FILE__)))
      graph = described_class.new(graph_name: "http://www.bbc.co.uk/programmes/b0081dq5.rdf", data: RDF::Repository.new)
      graph.load!
      expect(graph).not_to be_empty
    end

    it "Loading graph data from a URL (2)", skip: "requires RDF/XML" do
      require 'rdf/rdfxml'
      expect(RDF::Util::File).to receive(:open_file).
        with("http://www.bbc.co.uk/programmes/b0081dq5.rdf", an_instance_of(Hash)).
        and_yield(File.open(File.expand_path("../data/programmes.rdf", __FILE__)))
      graph = described_class.load("http://www.bbc.co.uk/programmes/b0081dq5.rdf")
      expect(graph).not_to be_empty
    end
  end

  context "#reified" do
    let(:ex) {RDF::Vocabulary.new("http://example.org/")}
    let(:quoted) {RDF::Statement(ex.a, ex.b, ex.c, tripleTerm: true)}
    let(:graph) do
      g = described_class.new
      g << RDF::Statement(ex.s, ex.p, quoted)
      g
    end

    it "replaces quoted statements with reification nodes" do
      reified = graph.reified
      node = reified.first_object(RDF::Statement(ex.s, ex.p, nil))
      expect(node).to be_a_node
      expect(reified.statement?(RDF::Statement(node, RDF.type, RDF[:Statement]))).to be true
      expect(reified.statement?(RDF::Statement(node, RDF.subject, ex.a))).to be true
      expect(reified.statement?(RDF::Statement(node, RDF.predicate, ex.b))).to be true
      expect(reified.statement?(RDF::Statement(node, RDF.object, ex.c))).to be true
    end

    it "does not assert quoted statements" do
      expect(graph.reified.statement?(RDF::Statement(ex.a, ex.b, ex.c))).to be false
    end

    it "leaves plain statements untouched" do
      graph << RDF::Statement(ex.s, ex.q, ex.o)
      expect(graph.reified.statement?(RDF::Statement(ex.s, ex.q, ex.o))).to be true
    end

    it "expands nested quoted statements into controlled reification nodes" do
      nested = RDF::Statement(ex.x, ex.y, quoted, tripleTerm: true)
      graph << RDF::Statement(ex.s, ex.q, nested)
      reified = graph.reified
      reified.each_statement do |st|
        expect(st.object).not_to be_a_statement
      end
      inner_node = reified.first_object(RDF::Statement(ex.s, ex.p, nil))
      outer_node = reified.first_object(RDF::Statement(ex.s, ex.q, nil))
      expect(reified.first_object(RDF::Statement(outer_node, RDF.object, nil))).to eq inner_node
    end

    it "shares a caller-provided identity table across batches" do
      map = {}
      graph.reified(map: map)
      other = described_class.new
      other << RDF::Statement(ex.s2, ex.p, quoted)
      reified = other.reified(map: map)
      expect(reified.first_object(RDF::Statement(ex.s2, ex.p, nil))).to eq map[quoted]
    end

    it "round-trips through #dereified" do
      expect(graph.reified.dereified).to eq graph
    end
  end

  context "#dereified" do
    let(:ex) {RDF::Vocabulary.new("http://example.org/")}
    let(:node) {RDF::Node.new}
    let(:graph) do
      g = described_class.new
      g << RDF::Statement(node, RDF.type, RDF[:Statement])
      g << RDF::Statement(node, RDF.subject, ex.a)
      g << RDF::Statement(node, RDF.predicate, ex.b)
      g << RDF::Statement(node, RDF.object, ex.c)
      g
    end

    it "restores quoted statements from reification descriptions" do
      graph << RDF::Statement(ex.s, ex.p, node)
      dereified = graph.dereified
      expect(dereified.count).to eq 1
      statement = dereified.first
      expect(statement.subject).to eq ex.s
      expect(statement.object).to be_a_statement
      expect(statement.object).to eq RDF::Statement(ex.a, ex.b, ex.c)
      expect(statement.object).to be_tripleTerm
    end

    it "replaces references in subject position" do
      graph << RDF::Statement(node, ex.rating, 5)
      statement = graph.dereified.first
      expect(statement.subject).to eq RDF::Statement(ex.a, ex.b, ex.c)
    end

    it "resolves nested reification nodes recursively" do
      outer = RDF::Node.new
      graph << RDF::Statement(outer, RDF.type, RDF[:Statement])
      graph << RDF::Statement(outer, RDF.subject, ex.x)
      graph << RDF::Statement(outer, RDF.predicate, ex.y)
      graph << RDF::Statement(outer, RDF.object, node)
      graph << RDF::Statement(ex.s, ex.p, outer)
      statement = graph.dereified.first
      expect(statement.object).to eq RDF::Statement(ex.x, ex.y, RDF::Statement(ex.a, ex.b, ex.c))
    end

    it "raises AmbiguousReification for incomplete descriptions" do
      incomplete = described_class.new
      incomplete << RDF::Statement(node, RDF.type, RDF[:Statement])
      incomplete << RDF::Statement(node, RDF.subject, ex.a)
      incomplete << RDF::Statement(node, RDF.predicate, ex.b)
      expect {incomplete.dereified}.to raise_error(RDF::Statement::AmbiguousReification)
    end

    it "raises AmbiguousReification for contradictory descriptions" do
      graph << RDF::Statement(node, RDF.object, ex.other)
      expect {graph.dereified}.to raise_error(RDF::Statement::AmbiguousReification)
    end

    it "raises AmbiguousReification for cyclic descriptions" do
      other = RDF::Node.new
      cyclic = described_class.new
      cyclic << RDF::Statement(node, RDF.subject, other)
      cyclic << RDF::Statement(node, RDF.predicate, ex.b)
      cyclic << RDF::Statement(node, RDF.object, ex.c)
      cyclic << RDF::Statement(other, RDF.subject, node)
      cyclic << RDF::Statement(other, RDF.predicate, ex.b)
      cyclic << RDF::Statement(other, RDF.object, ex.c)
      expect {cyclic.dereified}.to raise_error(RDF::Statement::AmbiguousReification)
    end

    it "leaves graphs without reification untouched" do
      plain = described_class.new
      plain << RDF::Statement(ex.s, ex.p, ex.o)
      expect(plain.dereified).to eq plain
    end

    it "adds recovered mappings to a caller-provided identity table" do
      map = {}
      graph.dereified(map: map)
      expect(map[RDF::Statement(ex.a, ex.b, ex.c, tripleTerm: true)]).to eq node
    end
  end
end
