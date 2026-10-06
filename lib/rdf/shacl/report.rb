# frozen_string_literal: true

module RDF
  module SHACL
    class Report
      attr_reader :results

      def initialize(results = [])
        @results = results
      end

      def conforms?
        results.empty?
      end
      alias conform? conforms?

      def each_result(&block)
        results.each(&block)
      end

      def to_a
        results
      end
    end
  end
end
