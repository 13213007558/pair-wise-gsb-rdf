# frozen_string_literal: true

require 'set'

module RDF
  ##
  # A small, dependency-free subset of SHACL Core.
  module SHACL
    autoload :Path, 'rdf/shacl/path'
    autoload :Report, 'rdf/shacl/report'
    autoload :Result, 'rdf/shacl/result'
    autoload :Validator, 'rdf/shacl/validator'

    NAMESPACE = RDF::URI('http://www.w3.org/ns/shacl#').freeze

    TERMS = %i[
      NodeShape PropertyShape
      targetClass targetNode deactivated
      path class datatype minCount maxCount
      inverse alternativePath zeroOrMorePath oneOrMorePath zeroOrOnePath
      and or not xone node property
      qualifiedValueShape qualifiedValueShapesDisjoint
      qualifiedMinCount qualifiedMaxCount
    ].to_h { |term| [term, RDF::URI("#{NAMESPACE}#{term}").freeze] }.freeze

    TERMS.each_key do |term|
      next if term == :class

      define_singleton_method(term) { TERMS[term] }
    end

    def self.[](term)
      TERMS.fetch(term)
    end

    MalformedShapeError = Class.new(StandardError)
    UnsupportedRecursionError = Class.new(StandardError)

    def self.validate(shape_graph, data_graph, **options)
      Validator.new(shape_graph, **options).validate(data_graph)
    end
  end
end
