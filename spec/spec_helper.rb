# frozen_string_literal: true

require "gloo_ingress_adapter"
require "hashdiff"

module SpecHelper
  def kube_resource(yaml)
    data = YAML.safe_load(yaml)
    Kubeclient::Resource.new(data.to_h)
  end

  def yaml(string)
    YAML.safe_load(string)
  end
end

RSpec.configure do |config|
  config.include(SpecHelper)
end
