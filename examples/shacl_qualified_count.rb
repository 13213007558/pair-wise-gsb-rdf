#!/usr/bin/env ruby
##
# Why sh:qualifiedMinCount cannot be replaced by sh:minCount.
#
# Scenario: an employee must have at least two *reachable* emergency
# contacts, i.e. contacts that have a phone number.
#
#   * sh:minCount 2 only counts *how many* values ex:emergencyContact
#     has. It cannot express "two values that are reachable contacts".
#   * sh:qualifiedMinCount 2 with sh:qualifiedValueShape counts only
#     the values that conform to the given shape.
#
# The data below has two emergency contacts, but only one of them has
# a phone number. The plain minCount check passes (a false sense of
# safety); the qualifiedMinCount check catches the problem.
#
# Run with:
#
#     BUNDLE_GEMFILE=.gsb/Gemfile bundle exec ruby -Ilib examples/shacl_qualified_count.rb

require 'rdf'
require 'rdf/turtle'

PREFIXES = <<~TTL
  @prefix sh:  <http://www.w3.org/ns/shacl#> .
  @prefix ex:  <http://example.com/> .
  @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
TTL

# The shapes graph and the data graph are two separate repositories.
SHAPES_TTL = PREFIXES + <<~TTL
  ex:EmployeeShape a sh:NodeShape ;
    sh:targetClass ex:Employee ;

    # Naive attempt: "at least two emergency contacts". This only
    # counts values, it cannot look *inside* them.
    sh:property [
      sh:path ex:emergencyContact ;
      sh:minCount 2 ;
      sh:message "needs at least two emergency contacts" ;
    ] ;

    # What is actually meant: "at least two emergency contacts that
    # are reachable". Only values conforming to ex:ReachableContact
    # are tallied.
    sh:property [
      sh:path ex:emergencyContact ;
      sh:qualifiedValueShape ex:ReachableContact ;
      sh:qualifiedMinCount 2 ;
      sh:message "needs at least two REACHABLE emergency contacts" ;
    ] .

  ex:ReachableContact a sh:NodeShape ;
    sh:property [
      sh:path ex:phone ;
      sh:minCount 1 ;
      sh:datatype xsd:string ;
    ] .
TTL

DATA_TTL = PREFIXES + <<~TTL
  ex:alice a ex:Employee ;
    ex:emergencyContact ex:bob, ex:carol .

  ex:bob   ex:phone "555-0100" .
  ex:carol ex:name  "Carol" .   # no phone: not reachable
TTL

def parse(turtle)
  RDF::Repository.new.tap do |graph|
    RDF::Turtle::Reader.new(turtle) { |reader| graph << reader }
  end
end

shapes = parse(SHAPES_TTL)
data   = parse(DATA_TTL)

report = RDF::SHACL::Validator.new(shapes: shapes, data: data).validate

puts "ex:alice has 2 emergency contacts, but only 1 is reachable."
puts
puts "conforms? #{report.conforms?}"
puts
report.results.each do |result|
  component = result.source_constraint_component.to_s.split('#').last
  puts "#{component}:"
  puts "  focus node: #{result.focus_node}"
  puts "  result path: #{result.path}"
  puts "  value: #{result.value.inspect}" if result.value
  puts "  source shape: #{result.source_shape.to_ntriples}"
  puts "  message: #{result.message}"
  puts
end

# The MinCountConstraintComponent is notably absent above: the plain
# sh:minCount 2 check passed, because ex:alice *does* have two values
# for ex:emergencyContact. Only the qualified check
# (QualifiedMinCountConstraintComponent) detects that fewer than two
# of them are reachable contacts.

