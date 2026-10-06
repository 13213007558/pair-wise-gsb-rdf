require_relative 'spec_helper'
require 'rdf/spec/queryable'

describe RDF::Queryable do
  # @see lib/rdf/spec/queryable.rb in rdf-spec
  it_behaves_like 'an RDF::Queryable' do
    let(:queryable) { RDF::Spec.quads.extend(RDF::Enumerable, RDF::Queryable) }
  end

  context "Examples" do
    subject { RDF::Repository.new.insert(RDF::Spec.quads.extend(RDF::Enumerable)) }

    context "Querying for statements having a given predicate" do
      it "calls #query_pattern" do
        is_expected.to receive(:query_pattern)
        is_expected.not_to receive(:query_execute)
        subject.query(%i(s p o)) {}
      end
      it "with array" do
        expect(subject.query([nil, RDF::Vocab::DOAP.developer, nil]).to_a).not_to be_empty
        subject.query([nil, RDF::Vocab::DOAP.developer, nil]) {|s| expect(s).to be_a_statement}
        expect{|b| subject.query([nil, RDF::Vocab::DOAP.developer, nil], &b)}.to yield_control.at_least(1).times
      end
      it "with hash" do
        expect(subject.query({predicate: RDF::Vocab::DOAP.developer}).to_a).not_to be_empty
        subject.query({predicate: RDF::Vocab::DOAP.developer}) {|s| expect(s).to be_a_statement}
        expect{|b| subject.query({predicate: RDF::Vocab::DOAP.developer}, &b)}.to yield_control.at_least(1).times
      end
    end

    context "Querying for solutions from a BGP" do
      let(:query) { RDF::Query.new {pattern %i(s p o)} }
      it "calls #query_execute" do
        is_expected.to receive(:query_execute)
        is_expected.not_to receive(:query_pattern)
        subject.query(query) {}
      end

      it "returns solutions" do
        expect(subject.query(query).to_a).not_to be_empty
        subject.query(query) {|s| expect(s).to be_a RDF::Query::Solution}
        expect{|b| subject.query(query, &b)}.to yield_control.exactly(subject.count).times
      end
    end
  end

  context "Concise Bounded Description" do
    def ex(term)
      RDF::URI("http://example.org/#{term}")
    end

    let(:s)     { ex("s") }
    let(:other) { ex("other") }
    let(:g1)    { ex("g1") }
    let(:g2)    { ex("g2") }
    let(:b)     { RDF::Node.new("b") }  # shared blank node
    let(:b2)    { RDF::Node.new("b2") }
    let(:r)     { RDF::Node.new("r") }  # reification node

    let(:default_statement) { RDF::Statement.new(s, ex("note"), "default") }
    let(:other_statement)   { RDF::Statement.new(other, ex("name"), "other", graph_name: g1) }

    let(:g1_statements) do
      [
        RDF::Statement.new(s, ex("p1"), b, graph_name: g1),
        RDF::Statement.new(s, ex("seeAlso"), other, graph_name: g1),
        RDF::Statement.new(b, ex("name"), "label", graph_name: g1),
        RDF::Statement.new(b, ex("next"), b, graph_name: g1), # blank node cycle
        # Reification of (s, ex("p1"), b): a description of the triple
        RDF::Statement.new(r, RDF.type, RDF.Statement, graph_name: g1),
        RDF::Statement.new(r, RDF.subject, s, graph_name: g1),
        RDF::Statement.new(r, RDF.predicate, ex("p1"), graph_name: g1),
        RDF::Statement.new(r, RDF.object, b, graph_name: g1),
        RDF::Statement.new(r, ex("certainty"), 0.9, graph_name: g1),
        other_statement,
      ]
    end

    let(:g2_statements) do
      [
        RDF::Statement.new(s, ex("p2"), b, graph_name: g2), # shares blank node b
        RDF::Statement.new(b, ex("link"), b2, graph_name: g2),
        RDF::Statement.new(b2, ex("name"), "nested", graph_name: g2),
      ]
    end

    let(:repository) do
      RDF::Repository.new do |repo|
        (g1_statements + g2_statements + [default_statement]).each {|st| repo << st}
      end
    end

    let(:cbd_statements) do
      g1_statements + g2_statements + [default_statement] - [other_statement]
    end

    context "with dataset semantics" do
      subject(:cbd) { repository.concise_bounded_description(s) }

      it "closes over shared blank nodes, cycles, and reifications exactly once" do
        expect(cbd.subject).to eq s
        expect(cbd.statements).to match_array(cbd_statements)
        expect(cbd.statements.count).to eq cbd_statements.count # no duplicates
      end

      it "preserves graph provenance" do
        expect(cbd.statements.map(&:graph_name).uniq).to match_array([g1, g2, nil])
      end

      it "does not expand ordinary URI objects" do
        expect(cbd.statements).not_to include(other_statement)
      end

      it "reports out-of-boundary references" do
        expect(cbd.references).to include(other)
        expect(cbd.references).not_to include(s) # described, not a reference
        expect(cbd.references.count).to eq cbd.references.uniq.count
      end

      it "is enumerable over its statements" do
        expect(cbd.to_a).to match_array(cbd_statements)
        expect(cbd).not_to be_empty
      end

      it "is aliased as #cbd" do
        expect(repository.cbd(s).statements).to match_array(cbd_statements)
      end
    end

    context "with single-graph semantics" do
      it "restricts extraction to the given named graph" do
        cbd = repository.concise_bounded_description(s, graph_name: g1)
        expect(cbd.statements).to match_array(g1_statements - [other_statement])
        expect(cbd.statements.map(&:graph_name).uniq).to eq [g1]
      end

      it "does not reach blank nodes described only in other graphs" do
        cbd = repository.concise_bounded_description(s, graph_name: g1)
        expect(cbd.statements.map(&:subject)).not_to include(b2)
      end

      it "supports the default graph with graph_name: false" do
        cbd = repository.concise_bounded_description(s, graph_name: false)
        expect(cbd.statements).to eq [default_statement]
      end
    end
  end
end
