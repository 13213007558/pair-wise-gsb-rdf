require 'spec_helper'
require 'rdf/turtle'

RSpec.describe RDF::SHACL::Validator do
  PREFIXES = <<~TTL
    @prefix sh:   <http://www.w3.org/ns/shacl#> .
    @prefix ex:   <http://example.com/> .
    @prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
  TTL

  SH = RDF::SHACL unless defined?(SH)

  def ex(name)
    RDF::URI("http://example.com/#{name}")
  end

  def parse_graph(turtle)
    graph = RDF::Repository.new
    RDF::Turtle::Reader.new(PREFIXES + turtle) { |reader| graph << reader }
    graph
  end

  def validate(shapes_ttl, data_ttl)
    described_class.new(shapes: parse_graph(shapes_ttl), data: parse_graph(data_ttl)).validate
  end

  def components(report)
    report.results.map(&:source_constraint_component)
  end

  describe 'targets' do
    it 'validates sh:targetNode focus nodes' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:minCount 1 ] .',
        'ex:a ex:q 1 .')
      expect(report.conforms?).to be false
      expect(report.results.first.focus_node).to eq ex('a')
    end

    it 'validates sh:targetClass instances' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetClass ex:Person ; sh:property [ sh:path ex:p ; sh:minCount 1 ] .',
        'ex:a a ex:Person . ex:b a ex:Person ; ex:p 1 .')
      expect(report.conforms?).to be false
      expect(report.results.map(&:focus_node)).to contain_exactly(ex('a'))
    end

    it 'treats instances of rdfs:subClassOf subclasses as sh:targetClass instances' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetClass ex:Person ; sh:property [ sh:path ex:p ; sh:minCount 1 ] .',
        'ex:Employee rdfs:subClassOf ex:Person . ex:a a ex:Employee .')
      expect(report.conforms?).to be false
      expect(report.results.map(&:focus_node)).to contain_exactly(ex('a'))
    end

    it 'skips deactivated shapes' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:deactivated true ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:minCount 1 ] .',
        'ex:a ex:q 1 .')
      expect(report.conforms?).to be true
    end
  end

  describe 'cardinality' do
    it 'reports sh:minCount violations' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:minCount 2 ] .',
        'ex:a ex:p 1 .')
      expect(components(report)).to eq [SH[:MinCountConstraintComponent]]
    end

    it 'reports sh:maxCount violations' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:maxCount 1 ] .',
        'ex:a ex:p 1, 2 .')
      expect(components(report)).to eq [SH[:MaxCountConstraintComponent]]
    end

    it 'conforms when counts are within range' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:minCount 1 ; sh:maxCount 2 ] .',
        'ex:a ex:p 1, 2 .')
      expect(report.conforms?).to be true
    end
  end

  describe 'value type constraints' do
    it 'reports sh:datatype violations for literals of the wrong datatype' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:age ; sh:datatype xsd:integer ] .',
        'ex:a ex:age "abc" .')
      expect(components(report)).to eq [SH[:DatatypeConstraintComponent]]
      expect(report.results.first.value).to eq RDF::Literal('abc')
    end

    it 'accepts literals with the required datatype' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:age ; sh:datatype xsd:integer ] .',
        'ex:a ex:age 42 .')
      expect(report.conforms?).to be true
    end

    it 'reports sh:class violations for values that are not instances' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:owner ; sh:class ex:Person ] .',
        'ex:a ex:owner ex:b . ex:b a ex:Robot .')
      expect(components(report)).to eq [SH[:ClassConstraintComponent]]
    end

    it 'accepts values typed as an rdfs:subClassOf subclass of sh:class' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:owner ; sh:class ex:Person ] .',
        'ex:Employee rdfs:subClassOf ex:Person . ex:a ex:owner ex:b . ex:b a ex:Employee .')
      expect(report.conforms?).to be true
    end

    it 'reports sh:class violations for literal values' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:owner ; sh:class ex:Person ] .',
        'ex:a ex:owner "bob" .')
      expect(components(report)).to eq [SH[:ClassConstraintComponent]]
    end
  end

  describe 'property paths' do
    let(:shape) { 'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path %s ; sh:minCount 1 ] .' }

    it 'evaluates predicate paths' do
      report = validate(format(shape, 'ex:p'), 'ex:a ex:p 1 .')
      expect(report.conforms?).to be true
    end

    it 'evaluates sh:inversePath' do
      report = validate(format(shape, '[ sh:inversePath ex:author ]'), 'ex:b ex:author ex:a .')
      expect(report.conforms?).to be true
    end

    it 'evaluates sequence paths' do
      report = validate(format(shape, '( ex:address ex:city )'),
        'ex:a ex:address [ ex:city "Springfield" ] .')
      expect(report.conforms?).to be true
    end

    it 'evaluates sh:alternativePath' do
      report = validate(format(shape, '[ sh:alternativePath ( ex:home ex:work ) ]'),
        'ex:a ex:work "555" .')
      expect(report.conforms?).to be true
    end

    it 'evaluates sh:zeroOrMorePath, including the focus node, and terminates on cycles' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:c ; sh:property [ sh:path [ sh:zeroOrMorePath ex:parent ] ; sh:class ex:Person ] .',
        'ex:c ex:parent ex:b . ex:b ex:parent ex:a . ex:a ex:parent ex:c . ex:a a ex:Person . ex:b a ex:Person . ex:c a ex:Person .')
      expect(report.conforms?).to be true
    end

    it 'evaluates sh:oneOrMorePath without including the focus node' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:c ; sh:property [ sh:path [ sh:oneOrMorePath ex:parent ] ; sh:minCount 2 ; sh:maxCount 2 ] .',
        'ex:c ex:parent ex:b . ex:b ex:parent ex:a .')
      expect(report.conforms?).to be true
    end

    it 'evaluates sh:zeroOrOnePath' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path [ sh:zeroOrOnePath ex:spouse ] ; sh:maxCount 1 ] .',
        'ex:a ex:spouse ex:b .')
      expect(components(report)).to eq [SH[:MaxCountConstraintComponent]]
    end
  end

  describe 'logical constraints' do
    it 'sh:and requires conformance to all member shapes' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:and ( [ sh:class ex:Person ] [ sh:node ex:Named ] ) .' \
        'ex:Named a sh:NodeShape ; sh:property [ sh:path ex:name ; sh:minCount 1 ] .',
        'ex:a a ex:Person .')
      expect(components(report)).to eq [SH[:AndConstraintComponent]]
    end

    it 'sh:or requires conformance to at least one member shape' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:id ; sh:or ( [ sh:datatype xsd:string ] [ sh:datatype xsd:integer ] ) ] .',
        'ex:a ex:id true .')
      expect(components(report)).to eq [SH[:OrConstraintComponent]]
    end

    it 'sh:not forbids conformance to the member shape' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:not [ sh:datatype xsd:string ] ] .',
        'ex:a ex:p "text" .')
      expect(components(report)).to eq [SH[:NotConstraintComponent]]
    end

    it 'sh:xone requires conformance to exactly one member shape' do
      shapes = 'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:xone ( [ sh:class ex:Person ] [ sh:class ex:Agent ] ) ] .'
      both   = validate(shapes, 'ex:a ex:p ex:b . ex:b a ex:Person, ex:Agent .')
      one    = validate(shapes, 'ex:a ex:p ex:b . ex:b a ex:Person .')
      expect(components(both)).to eq [SH[:XoneConstraintComponent]]
      expect(one.conforms?).to be true
    end
  end

  describe 'nested shapes' do
    it 'checks sh:node against nested node shapes' do
      report = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:friend ; sh:node ex:FriendShape ] .' \
        'ex:FriendShape a sh:NodeShape ; sh:property [ sh:path ex:name ; sh:minCount 1 ] .',
        'ex:a ex:friend ex:b .')
      expect(components(report)).to eq [SH[:NodeConstraintComponent]]
      expect(report.results.first.value).to eq ex('b')
    end
  end

  describe 'qualified value shapes' do
    let(:shapes) do
      'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:contact ; ' \
      '  sh:qualifiedValueShape ex:Reachable ; sh:qualifiedMinCount 2 ; sh:qualifiedMaxCount 3 ] .' \
      'ex:Reachable a sh:NodeShape ; sh:property [ sh:path ex:phone ; sh:minCount 1 ] .'
    end

    it 'counts only values conforming to the qualified shape for sh:qualifiedMinCount' do
      report = validate(shapes, 'ex:a ex:contact ex:b, ex:c . ex:b ex:phone "1" .')
      expect(components(report)).to eq [SH[:QualifiedMinCountConstraintComponent]]
    end

    it 'conforms when enough values conform to the qualified shape' do
      report = validate(shapes, 'ex:a ex:contact ex:b, ex:c . ex:b ex:phone "1" . ex:c ex:phone "2" .')
      expect(report.conforms?).to be true
    end

    it 'counts only values conforming to the qualified shape for sh:qualifiedMaxCount' do
      report = validate(shapes,
        'ex:a ex:contact ex:b, ex:c, ex:d, ex:e . ex:b ex:phone "1" . ex:c ex:phone "2" . ex:d ex:phone "3" . ex:e ex:phone "4" .')
      expect(components(report)).to eq [SH[:QualifiedMaxCountConstraintComponent]]
    end

    it 'honors sh:qualifiedValueShapesDisjoint across sibling qualified shapes' do
      disjoint_shapes =
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:child ; ' \
        '  sh:qualifiedValueShape ex:Son ; sh:qualifiedValueShape ex:Daughter ; ' \
        '  sh:qualifiedMinCount 1 ; sh:qualifiedValueShapesDisjoint true ] .' \
        'ex:Son a sh:NodeShape ; sh:class ex:SonC . ex:Daughter a sh:NodeShape ; sh:class ex:DaughterC .'
      data = 'ex:a ex:child ex:b . ex:b a ex:SonC, ex:DaughterC .'
      expect(validate(disjoint_shapes, data).conforms?).to be false

      overlapping = disjoint_shapes.sub('sh:qualifiedValueShapesDisjoint true', 'sh:qualifiedValueShapesDisjoint false')
      expect(validate(overlapping, data).conforms?).to be true
    end
  end

  describe 'recursive shapes' do
    let(:shapes) do
      'ex:PersonShape a sh:NodeShape ; sh:targetClass ex:Person ; ' \
      '  sh:property [ sh:path ex:name ; sh:minCount 1 ] ; ' \
      '  sh:property [ sh:path ex:friend ; sh:node ex:PersonShape ] .'
    end

    it 'terminates on cyclic data and conforms when the cycle is clean' do
      report = validate(shapes,
        'ex:a a ex:Person ; ex:name "A" ; ex:friend ex:b . ex:b a ex:Person ; ex:name "B" ; ex:friend ex:a .')
      expect(report.conforms?).to be true
    end

    it 'terminates on cyclic data and reports violations inside the cycle' do
      report = validate(shapes,
        'ex:a a ex:Person ; ex:name "A" ; ex:friend ex:b . ex:b a ex:Person ; ex:friend ex:a .')
      expect(report.conforms?).to be false
      expect(components(report)).to contain_exactly(
        SH[:MinCountConstraintComponent], SH[:NodeConstraintComponent])
    end
  end

  describe 'validation report' do
    let(:report) do
      validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:datatype xsd:integer ] .',
        'ex:a ex:p "oops" .')
    end

    it 'records focus node, result path, value and source constraint' do
      result = report.results.first
      expect(result.focus_node).to eq ex('a')
      expect(result.path).to eq ex('p')
      expect(result.value).to eq RDF::Literal('oops')
      expect(result.source_constraint_component).to eq SH[:DatatypeConstraintComponent]
      expect(result.severity).to eq SH[:Violation]
    end

    it 'serializes to a sh:ValidationReport graph' do
      graph = report.to_graph
      expect(graph.query({predicate: SH[:conforms]}).objects).to eq [RDF::Literal::FALSE]
      result_node = graph.first_object({predicate: SH[:result]})
      expect(graph.first_object({subject: result_node, predicate: SH[:focusNode]})).to eq ex('a')
      expect(graph.first_object({subject: result_node, predicate: SH[:resultPath]})).to eq ex('p')
      expect(graph.first_object({subject: result_node, predicate: SH[:value]})).to eq RDF::Literal('oops')
      expect(graph.first_object({subject: result_node, predicate: SH[:sourceConstraintComponent]}))
        .to eq SH[:DatatypeConstraintComponent]
    end

    it 'honors sh:severity and sh:message on the shape' do
      custom = validate(
        'ex:S a sh:NodeShape ; sh:targetNode ex:a ; sh:property [ sh:path ex:p ; sh:minCount 1 ; ' \
        '  sh:severity sh:Warning ; sh:message "custom message" ] .',
        'ex:a ex:q 1 .')
      expect(custom.conforms?).to be true
      expect(custom.results.first.severity).to eq SH[:Warning]
      expect(custom.results.first.message).to eq 'custom message'
    end
  end
end
