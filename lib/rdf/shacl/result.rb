# frozen_string_literal: true

module RDF
  module SHACL
    Result = Struct.new(:focus_node, :result_path, :value, :source_shape, :source_constraint, :constraint_parameter, :detail, keyword_init: true) do
      def initialize(*args, **kwargs)
        kwargs[:detail] ||= []
        super
      end

      def conforms?
        false
      end
    end
  end
end
