# frozen_string_literal: true

require "kubeclient"
require "zeitwerk"

# Main module
module GlooIngressAdapter
end

loader = Zeitwerk::Loader.for_gem
loader.setup

Enumerable.include(GlooIngressAdapter::Util::EnumerableExtensions)
Kubeclient::Resource.include(GlooIngressAdapter::Util::ResourceExtensions)
