# frozen_string_literal: true

require "stringio"

module GlooIngressAdapter
  module Util
    # Extensions to Array
    module EnumerableExtensions
      def fuse(separator, empty:)
        output = StringIO.new

        each do |item|
          empty = false
          output << item.to_s << separator
        end

        if output.length.positive?
          output.truncate(output.length - separator.length)
          output.string
        else
          empty
        end
      end
    end
  end
end
