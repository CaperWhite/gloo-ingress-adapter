# frozen_string_literal: true

$LOAD_PATH << File.expand_path("#{__dir__}/lib")

Gem::Specification.new do |spec|
  spec.name = "gloo_ingress_adapter"
  spec.version = "0.1.0"
  spec.authors = ["CaperWhite GmbH"]
  spec.email = ["info@caperwhite.com"]
  spec.summary = "Use ingress resources with Gloo gateways"
  spec.homepage = "https://github.com/CaperWhite/gloo-ingress-adapter"
  spec.required_ruby_version = ">= 3.1.0"
  spec.license = "AGPL-3.0-or-later"

  spec.metadata["docker_platforms"] = "linux/arm64,linux/amd64"
  spec.metadata["github_user"] = "CaperWhite"
  spec.metadata["helm_repo"] = "https://caperwhite.github.io/gloo-ingress-adapter"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.description = <<-DESCRIPTION
    This controller allows to integrate routes created from ingresses into a normal (non-ingress) Gloo gateway, thus
    making deploying a separate ingress gateway obsolete. The controller does this by creating route table resources
    from ingress objects in the cluster. These route tables then can be automatically mounted in a Gloo virtual service.
  DESCRIPTION

  spec.files = Dir[
    "*.md",
    "lib/**/*.rb",
  ]

  spec.bindir = "cmd"
  spec.executables = spec.files.grep(%r{^cmd/}) { |f| File.basename(f) }
  spec.require_paths = %w[lib]

  spec.add_dependency "activesupport", "~> 7.0"
  spec.add_dependency "kubeclient", "~> 4.9"
  spec.add_dependency "retriable", "~> 3.1"
  spec.add_dependency "zeitwerk", "~> 2.4"

  spec.add_development_dependency "cheetah", "~> 1.0"
  spec.add_development_dependency "debase", "~> 0.2", ">= 0.2.5.beta2"
  spec.add_development_dependency "equatable", "~> 0.7"
  spec.add_development_dependency "hashdiff", "~> 1.0"
  spec.add_development_dependency "memery", "~> 1.4"
  spec.add_development_dependency "pry", "~> 0.12"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.10"
  spec.add_development_dependency "rubocop", "~> 1.12"
  spec.add_development_dependency "rubocop-rspec", "~> 2.2"
  spec.add_development_dependency "ruby-debug-ide", "~> 0.7"
  spec.add_development_dependency "simplecov", "~> 0.21"
  spec.add_development_dependency "solargraph", "~> 0.40"
  spec.add_development_dependency "toml-rb", "~> 2.1"
end
