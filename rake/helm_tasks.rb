# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/string"

require_relative "command"

# Rake Helm tasks
module HelmTasks
  # Chart tasks
  class Chart < Rake::TaskLib
    def initialize(gemspec:, name: nil, version: nil, verbose: Rake.verbose)
      super()

      @name ||= gemspec.name.dasherize
      @version ||= gemspec.version
      @verbose = verbose

      @chart_dir = Pathname("build/helm-charts")
      @chart_repo = gemspec.metadata["helm_repo"]
      @github_project = gemspec.name.dasherize
      @github_user = gemspec.metadata["github_user"]
      @index_dir = Pathname("build/helm-index")

      create_tasks
    end

    protected

    attr_reader :name, :version, :chart_dir, :github_user, :github_project, :chart_repo, :index_dir

    def chart_file
      @chart_dir / "#{name}-#{version}.tgz"
    end

    def github_token
      @github_token ||= begin
        command = ["op", "get", "item", "GitHub Build Token", "--fields", "credential"]
        Command.run(*command, stdout: :mute).output.chomp
      end
    end

    def create_tasks
      namespace "helm" do
        desc "Create Helm chart package"
        file chart_file.to_s do
          chart_dir.mkpath
          Command.run(%W[cr package charts --package-path #{chart_dir}], verbose:)
        end

        desc "Upload Helm chart package"
        task "upload" => chart_file.to_s do
          chart_dir.mkpath
          Command.run(
            [
              "cr", "upload", "charts",
              "--release-name-template", "{{ .Version }}",
              "--package-path", chart_dir,
              "--owner", github_user,
              "--git-repo", github_project,
              "--skip-existing",
            ],
            env: { "CR_TOKEN" => github_token },
            verbose:
          )
        end

        desc "Create Helm chart index"
        task "index" => "helm:upload" do
          index_dir.mkpath

          Command.run(
            [
              "cr", "index",
              "--release-name-template", "{{ .Version }}",
              "--charts-repo", chart_repo,
              "--git-repo", github_project,
              "--owner", github_user,
              "--index-path", index_dir,
              "--package-path", chart_dir,
              "--push",
            ],
            env: { "CR_TOKEN" => github_token },
            verbose:
          )
        end
      end
    end
  end
end
