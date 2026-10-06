# frozen_string_literal: true

require 'rdf'
require 'rdf/ntriples'

module QualifiedCountExample
  def self.uri(name)
    RDF::URI("http://example.org/#{name}")
  end

  def self.triple(subject, predicate, object)
    RDF::Statement.new(subject, predicate, object)
  end

  def self.graph(*triples)
    RDF::Graph.new.tap do |result|
      triples.each { |statement| result << statement }
    end
  end

  def self.data
    graph(
      triple(uri('alice'), RDF.type, uri('Person')),
      triple(uri('alice'), uri('knows'), uri('bob')),
      triple(uri('alice'), uri('knows'), uri('carol')),
      triple(uri('bob'), RDF.type, uri('Adult')),
      triple(uri('carol'), RDF.type, uri('Child'))
    )
  end

  def self.shape_graph(qualified:)
    triples = [
      triple(uri('PersonShape'), RDF.type, RDF::SHACL.NodeShape),
      triple(uri('PersonShape'), RDF::SHACL.targetClass, uri('Person')),
      triple(uri('PersonShape'), RDF::SHACL.property, uri('FriendShape')),
      triple(uri('FriendShape'), RDF.type, RDF::SHACL.PropertyShape),
      triple(uri('FriendShape'), RDF::SHACL.path, uri('knows')),
      triple(uri('FriendShape'), RDF::SHACL.minCount, RDF::Literal(2))
    ]

    if qualified
      triples.concat([
        triple(uri('FriendShape'), RDF::SHACL.qualifiedValueShape, uri('AdultShape')),
        triple(uri('FriendShape'), RDF::SHACL.qualifiedMinCount, RDF::Literal(2)),
        triple(uri('AdultShape'), RDF.type, RDF::SHACL.NodeShape),
        triple(uri('AdultShape'), RDF::SHACL[:class], uri('Adult'))
      ])
    end

    graph(*triples)
  end

  def self.print_report(label, report)
    puts "\n== #{label} =="
    puts "conforms: #{report.conforms?}"
    report.results.each do |result|
      parameter = result.constraint_parameter
      puts [
        "focus=#{result.focus_node}",
        "path=#{result.result_path}",
        "value=#{result.value.inspect}",
        "shape=#{result.source_shape}",
        "constraint=#{result.source_constraint}",
        "actual=#{parameter[:actual]}",
        "expected=#{parameter[:expected]}"
      ].join(' ')
    end
  end

  def self.run
    data_graph = data
    print_report('ordinary sh:minCount', RDF::SHACL.validate(shape_graph(qualified: false), data_graph))
    print_report('qualified sh:qualifiedMinCount', RDF::SHACL.validate(shape_graph(qualified: true), data_graph))
  end
end

QualifiedCountExample.run if __FILE__ == $PROGRAM_NAME
