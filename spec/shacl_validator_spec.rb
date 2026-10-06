# frozen_string_literal: true

require_relative 'spec_helper'

describe RDF::SHACL do
  let(:ex) { RDF::Vocabulary.new('http://example/') }

  def triple(*terms)
    RDF::Statement.new(*terms)
  end

  def graph(*triples)
    RDF::Graph.new.tap do |result|
      triples.flatten.each { |statement| result << statement }
    end
  end

  def list(shape_graph, values)
    return RDF.nil if values.empty?

    head = RDF::Node.new
    current = head
    values.each_with_index do |value, index|
      shape_graph << triple(current, RDF.first, value)
      shape_graph << triple(current, RDF.rest, index == values.length - 1 ? RDF.nil : RDF::Node.new)
      current = shape_graph.query([current, RDF.rest, nil]).first.object
    end
    head
  end

  def blank_path(shape_graph, predicate, value)
    node = RDF::Node.new
    shape_graph << triple(node, predicate, value)
    node
  end

  describe '.validate' do
    it 'selects targetClass and targetNode nodes and reports counts, datatype and class' do
      shapes = graph(
        triple(ex.PersonShape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.PersonShape, RDF::SHACL.targetClass, ex.Person),
        triple(ex.PersonShape, RDF::SHACL.targetNode, ex.bob),
        triple(ex.PersonShape, RDF::SHACL[:class], ex.Person),
        triple(ex.PersonShape, RDF::SHACL.property, ex.NameProperty),
        triple(ex.NameProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.NameProperty, RDF::SHACL.path, ex.name),
        triple(ex.NameProperty, RDF::SHACL.minCount, RDF::Literal(1)),
        triple(ex.NameProperty, RDF::SHACL.maxCount, RDF::Literal(1)),
        triple(ex.NameProperty, RDF::SHACL.datatype, RDF::XSD.string)
      )
      data = graph(
        triple(ex.alice, RDF.type, ex.Employee),
        triple(ex.Employee, RDF::RDFS.subClassOf, ex.Person),
        triple(ex.alice, ex.name, RDF::Literal('Alice')),
        triple(ex.bob, ex.name, RDF::Literal(42)),
        triple(ex.bob, ex.name, RDF::Literal('B')),
        triple(ex.carol, ex.name, RDF::Literal('Carol'))
      )

      report = described_class.validate(shapes, data)

      expect(report.conforms?).to be false
      expect(report.results.map(&:focus_node).tally).to eq(ex.bob => 3)
      expect(report.results.map(&:source_constraint)).to contain_exactly(:class, :maxCount, :datatype)
      expect(report.results.find { |result| result.source_constraint == :datatype }).to have_attributes(
        focus_node: ex.bob,
        result_path: ex.name,
        value: RDF::Literal(42),
        source_shape: ex.NameProperty
      )
    end

    it 'evaluates inverse, alternative, sequence and repeated property paths' do
      shapes = RDF::Graph.new
      inverse_path = blank_path(shapes, RDF::SHACL.inverse, ex.parent)
      alternative_list = list(shapes, [ex.name, ex.nick])
      alternative_path = blank_path(shapes, RDF::SHACL.alternativePath, alternative_list)
      sequence_path = list(shapes, [ex.knows, ex.name])
      repeat_path = blank_path(shapes, RDF::SHACL.oneOrMorePath, ex.knows)
      [
        triple(ex.InverseShape, RDF::SHACL.property, ex.InverseProperty),
        triple(ex.InverseProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.InverseProperty, RDF::SHACL.path, inverse_path),
        triple(ex.InverseProperty, RDF::SHACL.minCount, RDF::Literal(1)),
        triple(ex.AlternativeShape, RDF::SHACL.property, ex.AlternativeProperty),
        triple(ex.AlternativeProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.AlternativeProperty, RDF::SHACL.path, alternative_path),
        triple(ex.AlternativeProperty, RDF::SHACL.maxCount, RDF::Literal(1)),
        triple(ex.SequenceShape, RDF::SHACL.property, ex.SequenceProperty),
        triple(ex.SequenceProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.SequenceProperty, RDF::SHACL.path, sequence_path),
        triple(ex.SequenceProperty, RDF::SHACL.datatype, RDF::XSD.string),
        triple(ex.RepeatShape, RDF::SHACL.property, ex.RepeatProperty),
        triple(ex.RepeatProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.RepeatProperty, RDF::SHACL.path, repeat_path),
        triple(ex.RepeatProperty, RDF::SHACL.minCount, RDF::Literal(2))
      ].each { |statement| shapes << statement }
      [ex.InverseShape, ex.AlternativeShape, ex.SequenceShape, ex.RepeatShape].each do |node|
        shapes << triple(node, RDF.type, RDF::SHACL.NodeShape)
        shapes << triple(node, RDF::SHACL.targetNode, ex.root)
      end
      data = graph(
        triple(ex.root, ex.parent, ex.parent_value),
        triple(ex.child, ex.parent, ex.parent_value),
        triple(ex.child, ex.parent, ex.root),
        triple(ex.root, ex.name, RDF::Literal('Root')),
        triple(ex.root, ex.nick, RDF::Literal('R')),
        triple(ex.root, ex.knows, ex.middle),
        triple(ex.middle, ex.knows, ex.leaf),
        triple(ex.middle, ex.name, RDF::Literal(7))
      )

      report = described_class.validate(shapes, data)
      constraints = report.results.map(&:source_constraint)

      expect(constraints).to contain_exactly(:maxCount, :datatype)
      expect(report.results.find { |result| result.source_constraint == :maxCount }.result_path).to eq(
        alternative: [ex.name, ex.nick]
      )
      expect(report.results.find { |result| result.source_constraint == :datatype }.result_path).to eq(
        sequence: [ex.knows, ex.name]
      )
    end

    it 'validates sh:and, sh:or, sh:not and sh:xone' do
      shapes = RDF::Graph.new
      and_path = list(shapes, [ex.PersonShape, ex.NotBannedNode])
      or_path = list(shapes, [ex.AdultShape, ex.ChildShape])
      xone_path = list(shapes, [ex.AdultShape, ex.ChildShape])
      [
        triple(ex.RootShape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.RootShape, RDF::SHACL.targetNode, ex.good),
        triple(ex.RootShape, RDF::SHACL.targetNode, ex.banned),
        triple(ex.RootShape, RDF::SHACL.targetNode, ex.both),
        triple(ex.RootShape, RDF::SHACL.and, and_path),
        triple(ex.RootShape, RDF::SHACL.or, or_path),
        triple(ex.RootShape, RDF::SHACL.xone, xone_path),
        triple(ex.RootShape, RDF::SHACL.not, ex.BannedShape),
        triple(ex.PersonShape, RDF::SHACL[:class], ex.Person),
        triple(ex.AdultShape, RDF::SHACL[:class], ex.Adult),
        triple(ex.ChildShape, RDF::SHACL[:class], ex.Child),
        triple(ex.BannedShape, RDF::SHACL[:class], ex.Banned),
        triple(ex.NotBannedNode, RDF::SHACL.not, ex.BannedShape)
      ].each { |statement| shapes << statement }
      data = graph(
        triple(ex.good, RDF.type, ex.Person),
        triple(ex.good, RDF.type, ex.Child),
        triple(ex.banned, RDF.type, ex.Person),
        triple(ex.banned, RDF.type, ex.Child),
        triple(ex.banned, RDF.type, ex.Banned),
        triple(ex.both, RDF.type, ex.Person),
        triple(ex.both, RDF.type, ex.Child),
        triple(ex.both, RDF.type, ex.Adult)
      )

      report = described_class.validate(shapes, data)

      expect(report.results.map(&:focus_node).tally).to eq(ex.banned => 2, ex.both => 1)
      expect(report.results.map(&:source_constraint)).to contain_exactly(:not, :not, :xone)
    end

    it 'uses an explicit recursion stack instead of unbounded recursive calls' do
      shapes = graph(
        triple(ex.RecursiveShape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.RecursiveShape, RDF::SHACL.targetNode, ex.root),
        triple(ex.RecursiveShape, RDF::SHACL.property, ex.KnowsProperty),
        triple(ex.KnowsProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.KnowsProperty, RDF::SHACL.path, ex.knows),
        triple(ex.KnowsProperty, RDF::SHACL.node, ex.RecursiveShape)
      )
      data = graph(
        triple(ex.root, ex.knows, ex.middle),
        triple(ex.middle, ex.knows, ex.middle)
      )

      expect { described_class.validate(shapes, data) }.not_to raise_error
      expect(described_class.validate(shapes, data).conforms?).to be true

      negated = graph(
        triple(ex.NegatedShape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.NegatedShape, RDF::SHACL.targetNode, ex.root),
        triple(ex.NegatedShape, RDF::SHACL.not, ex.NegatedShape)
      )
      report = described_class.validate(negated, graph)
      
      expect(report.results.map(&:source_constraint)).to eq [:unsupportedRecursion]
      expect(report.results.first.constraint_parameter.fetch(:strategy)).to include('negated')

      wrapped = RDF::Graph.new
      or_list = list(wrapped, [ex.WrappedNegatedShape, ex.GoodShape])
      [
        triple(ex.WrappedShape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.WrappedShape, RDF::SHACL.targetNode, ex.root),
        triple(ex.WrappedShape, RDF::SHACL.or, or_list),
        triple(ex.WrappedNegatedShape, RDF::SHACL.not, ex.WrappedNegatedShape),
        triple(ex.GoodShape, RDF::SHACL[:class], ex.Person)
      ].each { |statement| wrapped << statement }
      expect(described_class.validate(wrapped, graph).results.map(&:source_constraint)).to(
        include(:unsupportedRecursion)
      )
    end

    it 'reports qualifiedMinCount when ordinary minCount sees enough unqualified values' do
      ordinary = graph(
        triple(ex.PersonShape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.PersonShape, RDF::SHACL.targetClass, ex.Person),
        triple(ex.PersonShape, RDF::SHACL.property, ex.FriendProperty),
        triple(ex.FriendProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.FriendProperty, RDF::SHACL.path, ex.knows),
        triple(ex.FriendProperty, RDF::SHACL.minCount, RDF::Literal(2))
      )
      qualified = graph(
        triple(ex.PersonShape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.PersonShape, RDF::SHACL.targetClass, ex.Person),
        triple(ex.PersonShape, RDF::SHACL.property, ex.FriendProperty),
        triple(ex.FriendProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.FriendProperty, RDF::SHACL.path, ex.knows),
        triple(ex.FriendProperty, RDF::SHACL.minCount, RDF::Literal(2)),
        triple(ex.FriendProperty, RDF::SHACL.qualifiedValueShape, ex.AdultShape),
        triple(ex.FriendProperty, RDF::SHACL.qualifiedMinCount, RDF::Literal(2)),
        triple(ex.AdultShape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.AdultShape, RDF::SHACL[:class], ex.Adult)
      )
      data = graph(
        triple(ex.alice, RDF.type, ex.Person),
        triple(ex.alice, ex.knows, ex.bob),
        triple(ex.alice, ex.knows, ex.carol),
        triple(ex.bob, RDF.type, ex.Adult),
        triple(ex.carol, RDF.type, ex.Child)
      )

      expect(described_class.validate(ordinary, data).conforms?).to be true
      report = described_class.validate(qualified, data)
      result = report.results.find { |entry| entry.source_constraint == :qualifiedMinCount }

      expect(report.conforms?).to be false
      expect(result).to have_attributes(
        focus_node: ex.alice,
        result_path: ex.knows,
        value: nil,
        source_shape: ex.FriendProperty
      )
      expect(result.constraint_parameter).to include(
        qualified_value_shape: ex.AdultShape,
        expected: 2,
        actual: 1
      )
    end

    it 'supports qualifiedMaxCount and qualifiedValueShapesDisjoint' do
      shape_graph = RDF::Graph.new
      shapes = graph(
        shape_graph,
        triple(ex.Shape, RDF.type, RDF::SHACL.NodeShape),
        triple(ex.Shape, RDF::SHACL.targetClass, ex.Person),
        triple(ex.Shape, RDF::SHACL.property, ex.RoleProperty),
        triple(ex.RoleProperty, RDF.type, RDF::SHACL.PropertyShape),
        triple(ex.RoleProperty, RDF::SHACL.path, ex.hasRole),
        triple(ex.RoleProperty, RDF::SHACL.qualifiedValueShape, ex.AdminRoleShape),
        triple(ex.RoleProperty, RDF::SHACL.qualifiedValueShape, ex.UserRoleShape),
        triple(ex.RoleProperty, RDF::SHACL.qualifiedValueShapesDisjoint, RDF::Literal(true)),
        triple(ex.RoleProperty, RDF::SHACL.qualifiedMinCount, RDF::Literal(1)),
        triple(ex.RoleProperty, RDF::SHACL.qualifiedMaxCount, RDF::Literal(1)),
        triple(ex.AdminRoleShape, RDF::SHACL[:class], ex.Admin),
        triple(ex.UserRoleShape, RDF::SHACL[:class], ex.User)
      )
      data = graph(
        triple(ex.alice, RDF.type, ex.Person),
        triple(ex.alice, ex.hasRole, ex.admin),
        triple(ex.alice, ex.hasRole, ex.user),
        triple(ex.alice, ex.hasRole, ex.guest),
        triple(ex.admin, RDF.type, ex.Admin),
        triple(ex.admin, RDF.type, ex.User),
        triple(ex.user, RDF.type, ex.User),
        triple(ex.guest, RDF.type, ex.User)
      )

      report = described_class.validate(shapes, data)

      expect(report.results.map(&:source_constraint)).to contain_exactly(:qualifiedMinCount, :qualifiedMaxCount)
      expect(report.results.map { |result| result.constraint_parameter.fetch(:actual) }).to contain_exactly(0, 2)
    end
  end
end
