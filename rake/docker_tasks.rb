# frozen_string_literal: true

require "equatable"
require "ostruct"
require "pathname"
require "stringio"
require "time"
require "toml-rb"

require_relative "command"

# Rake docker tasks
module DockerTasks
  # Image name
  class ImageName
    attr_reader :name, :tag

    class << self
      def parse(image)
        name, tag = image.split(":")
        new(name:, tag: tag || "latest")
      end
    end

    def initialize(name:, tag:)
      @name = name
      @tag = tag
    end

    def to_s
      [@name, @tag].join(":")
    end

    def variant(platform:)
      ImageName.new(name: @name, tag: [@tag, platform.os, platform.cpu].compact.join("-"))
    end

    def pathname
      Pathname([@name, @tag].join("-"))
    end
  end

  # Platform
  class Platform
    include Equatable

    attr_reader :os, :cpu

    def initialize(spec)
      @os, @cpu = spec.split("/")
    end

    def to_s
      "#{@os}/#{@cpu}"
    end
  end

  def self.last_tag_time(name:)
    time = Command.run(%W[docker images --format {{.CreatedAt}} #{name}], stdout: :mute)

    Time.parse(time.output.chomp) unless time.output.empty?
  end

  def self.manifest_valid?(name:, platforms:)
    manifest = Command.run(%W[docker manifest inspect #{name}], stdout: :mute, exits: [0, 1]).json
    entries = manifest.fetch("manifests")

    if entries.length == platforms.length
      platforms.all? do |platform|
        entry = entries.find do |e|
          e["platform"] == { "os" => platform.os, "architecture" => platform.cpu }
        end

        if entry
          variant = name.variant(platform:)
          image = Command.run(%W[docker image inspect #{variant}], stdout: :mute, exits: [0, 1]).json.first

          if image
            image_digest = image&.[]("RepoDigests")&.first&.[](%r{@([a-z0-9]+:[a-z0-9]+)\z}i, 1)
            image_digest == entry["digest"]
          end
        end
      end
    end
  end

  # Image tasks
  class Image < Rake::TaskLib
    def initialize(gemspec:, image: nil, tag: nil, platforms: nil, verbose: Rake.verbose)
      super()

      image ||= "caperwhite/#{gemspec.name.dasherize}"
      tag ||= gemspec.version

      name = ImageName.new(name: image, tag:)
      platforms ||= gemspec.metadata["docker_platforms"].split(",").map { |a| Platform.new(a) }

      create_tasks(gemspec:, name:, platforms:, verbose:)
    end

    protected

    def create_tasks(gemspec:, name:, platforms:, verbose:)
      desc "Create Dockerfile"
      file "Dockerfile" => "Dockerfile.erb" do
        template = ERB.new(File.read("Dockerfile.erb"))
        context = { gemspec: }
        Pathname("Dockerfile").write(template.result_with_hash(context))
      end

      namespace "docker" do
        desc "Build docker images"
        task "build"

        desc "Push docker images"
        task "push" => ["docker:build", "docker:manifest:push"]

        desc "Save docker images"
        task "save"

        namespace "manifest" do
          desc "Create manifest"
          create_task = task "create" do
            create_manifest(name:, platforms:, verbose:)
          end

          create_task.singleton_class.define_method(:needed?) do
            !DockerTasks.manifest_valid?(name:, platforms:)
          end

          desc "Push manifest"
          task "push" => "docker:manifest:create" do
            push_manifest(name:, verbose:)
          end
        end

        platforms.each do |platform|
          archive = archive(name:, platform:)

          namespace platform.os do
            namespace platform.cpu do
              create_platform_tasks(gemspec:, name:, platform:, archive:, verbose:)
            end
          end

          task "build" => "docker:#{platform.os}:#{platform.cpu}:build"
          task "save" => archive.to_s
          task "push" => "docker:#{platform.os}:#{platform.cpu}:push"
          task "manifest:create" => "docker:#{platform.os}:#{platform.cpu}:push"
        end
      end
    end

    def archive(name:, platform:)
      Pathname("pkg/#{name.variant(platform:).pathname}.tar")
    end

    def create_platform_tasks(gemspec:, name:, platform:, archive:, verbose:)
      variant = name.variant(platform:)

      desc "Build Docker image #{variant}"
      build_task = task "build" => "Dockerfile" do
        build_image(name: variant, platform:, verbose:)
      end

      build_task.singleton_class.define_method(:timestamp) do
        DockerTasks.last_tag_time(name: variant)
      end

      desc "Push Docker image #{variant}"
      file "docker:#{platform.os}:#{platform.cpu}:push" => "docker:#{platform.os}:#{platform.cpu}:build" do
        push_image(name: variant, verbose:)
      end

      desc "Save Docker image #{variant}"
      file archive.to_s => "docker:#{platform.os}:#{platform.cpu}:build" do |task|
        save_image(name: variant, file: Pathname(task.name), verbose:)
      end

      desc "Upload Docker image #{archive} to Kubernetes server"
      task "upload", [:hosts] => archive.to_s do |_t, args|
        args[:hosts].split(":").map(&:chomp).each do |host|
          upload_image(host:, name:, platform:, archive:, verbose:)
        end
      end
    end

    def push_image(name:, verbose: Rake.verbose)
      puts "Push image #{name}" if verbose

      Command.run("docker", "push", name, verbose:)
    end

    def create_manifest(name:, platforms:, verbose: Rake.verbose)
      puts "Create manifest #{name}" if verbose

      images = platforms.flat_map { |p| ["--amend", name.variant(platform: p)] }

      Command.run("docker", "manifest", "rm", name, verbose:)
      Command.run("docker", "manifest", "create", name, *images, verbose:)
    end

    def push_manifest(name:, verbose: Rake.verbose)
      puts "Push manifest #{name}" if verbose

      Command.run("docker", "manifest", "push", name, verbose:)
    end

    def save_image(name:, file:, verbose: Rake.verbose)
      puts "Saving image #{name} to #{file}" if verbose

      file.dirname.mkpath

      Command.run("docker", "image", "save", "--output", file, name, verbose:)
    end

    def build_image(name:, platform: nil, verbose: Rake.verbose)
      puts "Building image #{name} for #{platform || "default platform"}" if verbose

      Command.run(
        "docker", "build",
        "--progress", "plain",
        verbose ? nil : "--quiet",
        "--platform", platform,
        "--tag", name,
        ".",
        verbose:
      )
    end

    def upload_image(host:, name:, platform:, archive:, verbose: Rake.verbose)
      puts "Uploading image #{archive} to #{host}" if verbose

      variant = name.variant(platform:)

      command = Command.run(
        "rsync",
        "--archive",
        "--compress",
        verbose ? ["--verbose", "--progress"] : nil,
        "--itemize-changes",
        archive,
        "#{host}:~",
        verbose:
      )

      changed = command.output =~ %r{^<}m

      if changed
        command = Command.run("ssh", host, "containerd", "config", "dump", stdout: :mute, verbose:)

        config = TomlRB.parse(command.output)
        snapshotter = config.dig("plugins", "io.containerd.grpc.v1.cri", "containerd", "snapshotter")

        puts "Using snapshotter #{snapshotter}" if snapshotter && verbose

        Command.run(
          "ssh", host,
          "ctr", "--namespace", "k8s.io",
          "images", "import",
          snapshotter ? ["--snapshotter", snapshotter] : nil,
          "~/#{archive.basename}",
          verbose:
        )

        Command.run(
          "ssh", host,
          "ctr", "--namespace", "k8s.io", "image", "tag", "--force", "docker.io/#{variant}", "docker.io/#{name}",
          verbose:
        )
      end
    end
  end
end
