require 'rdf'
require 'rdf/ntriples' # for RDF::Value#to_ntriples

module RDF
  ##
  # A pure-Ruby validator for a practical subset of W3C SHACL Core.
  #
  # The shapes graph and the data graph are always two separate
  # RDF::Queryable instances; shapes are never looked up in the data
  # graph and vice versa:
  #
  #     validator = RDF::SHACL::Validator.new(shapes: shapes_graph, data: data_graph)
  #     report    = validator.validate
  #     report.conforms?  #=> true or false
  #     report.results    #=> [RDF::SHACL::ValidationResult, ...]
  #
  # Supported SHACL Core features:
  #
  # * Targets: sh:targetClass (including rdfs:subClassOf inference
  #   over the data graph) and sh:targetNode.
  # * Property paths: predicate IRIs, sh:inversePath,
  #   sh:alternativePath, sequence paths (RDF lists),
  #   sh:zeroOrMorePath, sh:oneOrMorePath and sh:zeroOrOnePath.
  # * Cardinality: sh:minCount / sh:maxCount.
  # * Value types: sh:datatype and sh:class.
  # * Logical operators: sh:and, sh:or, sh:not, sh:xone.
  # * Nested shapes: sh:node, sh:property.
  # * Qualified value shapes: sh:qualifiedValueShape with
  #   sh:qualifiedMinCount / sh:qualifiedMaxCount and
  #   sh:qualifiedValueShapesDisjoint.
  # * sh:deactivated, sh:severity and sh:message.
  #
  # == Recursive shapes
  #
  # The SHACL Core specification deliberately leaves the meaning of
  # recursive shapes undefined, and a naive validator would recurse
  # forever on them. This validator guarantees termination with an
  # explicit, deterministic strategy: validation state is threaded
  # through every check as a stack of [shape, focus_node] pairs. When
  # a pair that is already on the stack would be validated again, the
  # re-entrant check is treated as *conforming* (a coinductive,
  # greatest-fixed-point reading) and produces no validation results.
  # Recursion is therefore never evaluated by unbounded method
  # recursion; a shape cycle such as "every friend of a valid person is
  # a valid person" terminates and is accepted exactly when no
  # non-recursive constraint in the cycle is violated.
  module SHACL
    autoload :Validator,        'rdf/shacl/validator'
    autoload :ValidationReport, 'rdf/shacl/validation_report'
    autoload :ValidationResult, 'rdf/shacl/validation_report'
    autoload :Path,             'rdf/shacl/path'

    # The SHACL namespace IRI.
    BASE = 'http://www.w3.org/ns/shacl#'.freeze

    ##
    # Returns the SHACL vocabulary term for +name+.
    #
    # @param  [String, Symbol] name
    # @return [RDF::URI]
    def self.[](name)
      RDF::URI(BASE + name.to_s)
    end
  end # SHACL
end # RDF
