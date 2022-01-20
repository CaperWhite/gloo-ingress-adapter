# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/hash"

module GlooIngressAdapter
  module Util
    # Extensions to Resource
    module ResourceExtensions
      def to_json(*args)
        to_h.to_json(*args)
      end

      def to_nice_yaml
        to_h.deep_stringify_keys.to_yaml
      end
    end
  end
end
