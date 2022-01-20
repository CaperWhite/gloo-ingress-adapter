# frozen_string_literal: true

begin
  require "bundler/setup"

  require "active_support"
  require "active_support/core_ext/string"
  require "erb"
  require "gloo_ingress_adapter/version"
  require "open3"
  require "pathname"
  require "rake/phony"
  require "rspec/core/rake_task"

  require_relative "rake/docker_tasks"
  require_relative "rake/helm_tasks"
rescue StandardError => e
  warn "Could not load required libraries. Please run 'bundle setup'."
  warn e.message
  exit 1
end

namespace "gem" do
  Bundler::GemHelper.define_method(:version_tag) do
    version
  end

  Bundler::GemHelper.install_tasks
end

gemspec = Bundler::GemHelper.instance.gemspec

RSpec::Core::RakeTask.new(:spec) do |t|
  t.verbose = Rake.verbose
end

DockerTasks::Image.new(gemspec:)
HelmTasks::Chart.new(gemspec:)
