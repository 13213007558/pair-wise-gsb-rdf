require "spec_helper"

describe RDF::Query::Provenance do
  let(:vocabulary) {RDF::Vocabulary.new("http://example.org/")}
  let(:statement) {RDF::Statement(vocabulary.a, vocabulary.p, vocabulary.b)}
  let(:builder) {described_class::Builder.new}

  it "uses multiplication for joins and reuses the shared expression" do
    first = builder.variable(statement)
    second = RDF::Statement(vocabulary.b, vocabulary.p, vocabulary.c)
    shared = builder.product(first, builder.variable(second))
    third = RDF::Statement(vocabulary.c, vocabulary.p, vocabulary.d)
    expression = builder.product(shared, builder.variable(third))

    expect(expression.left).to equal(shared)
    expect(expression.evaluate { |s| s == statement ? 2 : 3 }).to eq 18
    expect(expression.evaluate { true }).to be true
  end

  it "keeps repeated use of the same statement as a square" do
    variable = builder.variable(statement)
    expression = builder.product(variable, variable)

    expect(expression.left).to equal(variable)
    expect(expression.right).to equal(variable)
    expect(expression.evaluate { 7 }).to eq 49
  end

  it "sums alternative derivations with the same bindings" do
    first = builder.variable(statement)
    second = builder.variable(RDF::Statement(statement, graph_name: vocabulary.g))
    expression = builder.sum(first, second)

    expect(expression).to be_a(described_class::Sum)
    expect(expression.evaluate { 1 }).to eq 2
  end

  it "evaluates the multiplicative identity" do
    expect(described_class.one.evaluate({}, one: 1)).to eq 1
    expect(described_class.one.evaluate { true }).to be true
  end

  it "uses an explicit identity with non-empty expressions" do
    expression = builder.product(described_class.one, builder.variable(statement))
    expect(expression.evaluate(one: -99) { 0 }).to eq 0
  end

  it "rejects mixed boolean and numeric substitutions" do
    other = RDF::Statement(vocabulary.b, vocabulary.p, vocabulary.c)
    expression = builder.sum(builder.variable(statement), builder.variable(other))

    expect { expression.evaluate { |s| s == statement ? true : 1 } }
      .to raise_error(ArgumentError, /provenance values/)
  end
end

describe RDF::Query, "provenance" do
  let(:vocabulary) {RDF::Vocabulary.new("http://example.org/")}
  let(:ex) {vocabulary}

  it "does not attach provenance unless requested" do
    graph = RDF::Graph.new { |g| g << [ex.a, ex.p, ex.b] }
    query = RDF::Query.new { pattern [:s, :p, :o] }

    expect(query.execute(graph).first.provenance).to be_nil
  end

  it "can enable provenance for one execute call without changing the query default" do
    graph = RDF::Graph.new { |g| g << [ex.a, ex.p, ex.b] }
    query = RDF::Query.new { pattern [:s, :p, :o] }

    annotated = query.execute(graph, provenance: true)
    plain = query.execute(graph)

    expect(query.provenance).to be false
    expect(annotated.first.provenance).not_to be_nil
    expect(plain.first.provenance).to be_nil
  end

  it "multiplies statements in a join and evaluates count and boolean assignments" do
    graph = RDF::Graph.new do |g|
      g << [ex.a, ex.p, ex.b]
      g << [ex.b, ex.p, ex.c]
    end
    predicate = ex.p
    query = RDF::Query.new(provenance: true) do |q|
      q.pattern [:x, predicate, :y]
      q.pattern [:y, predicate, :z]
    end

    solution = query.execute(graph).first
    expect(solution.provenance).to be_a(RDF::Query::Provenance::Product)
    expect(solution.provenance.statements.length).to eq 2
    expect(solution.provenance.evaluate { 2 }).to eq 4
    expect(solution.provenance.evaluate { true }).to be true
  end

  it "creates a square when a self-join uses the same fact twice" do
    graph = RDF::Graph.new { |g| g << [ex.a, ex.p, ex.a] }
    predicate = ex.p
    query = RDF::Query.new(provenance: true) do |q|
      q.pattern [:x, predicate, :x]
      q.pattern [:x, predicate, :x]
    end

    solution = query.execute(graph).first
    expression = solution.provenance
    expect(expression).to be_a(RDF::Query::Provenance::Product)
    expect(expression.left).to equal(expression.right)
    expect(expression.evaluate { 7 }).to eq 49
    expect(expression.evaluate { false }).to be false
  end

  it "merges equal bindings from distinct derivations instead of dropping one" do
    repository = RDF::Repository.new do |r|
      r << [ex.a, ex.p, ex.b]
      r << [ex.a, ex.p, ex.b, ex.g]
    end
    query = RDF::Query.new(provenance: true) { pattern [:s, :p, :o] }

    solutions = query.execute(repository)
    expect(solutions.length).to eq 1
    expect(solutions.first.provenance).to be_a(RDF::Query::Provenance::Sum)
    expect(solutions.first.provenance.statements.length).to eq 2
    expect(solutions.first.provenance.evaluate { 1 }).to eq 2
  end

  it "supports hash assignments and empty positive BGPs" do
    graph = RDF::Graph.new
    query = RDF::Query.new(provenance: true)

    expect(query.execute(graph).first.provenance.evaluate({}, one: 1)).to eq 1
  end

  it "is available through Queryable#query and preserves chained expressions" do
    p = ex.p
    q = ex.q
    graph = RDF::Graph.new do |g|
      g << [ex.a, p, ex.b]
      g << [ex.b, q, ex.c]
    end
    first = RDF::Query.new { pattern [:s, p, :o] }
    second = RDF::Query.new { pattern [:o, q, :t] }

    intermediate = graph.query(first, provenance: true)
    final = second.execute(graph, solutions: intermediate, provenance: true)

    expect(intermediate.first.provenance).not_to be_nil
    expect(final.first.provenance.statements.length).to eq 2
    expect(final.first.provenance.evaluate { 1 }).to eq 1
  end

  it "merges repeated preliminary bindings before multiplying a matched fact" do
    predicate = ex.p
    graph = RDF::Graph.new { |g| g << [ex.a, predicate, ex.b] }
    query = RDF::Query.new { pattern [:s, predicate, :o] }

    solutions = query.execute(graph, bindings: {s: [ex.a, ex.a]}, provenance: true)
    expect(solutions.length).to eq 1
    expect(solutions.first.provenance.evaluate { 1 }).to eq 2
    expect(solutions.first.provenance.evaluate { true }).to be true
  end
end
