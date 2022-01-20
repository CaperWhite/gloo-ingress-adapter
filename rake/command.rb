# frozen_string_literal: true

require "cheetah"
require "json"

# Runs external commands
class Command
  # Forwards output to multiple streams
  class TeeIO
    def initialize(*outputs, verbose: false)
      @outputs = outputs
      @verbose = verbose
    end

    def write(data)
      @outputs.each { |output| output.write(data) }
    end

    def <<(data)
      @outputs.each { |output| output << data }
      self
    end

    def close
      @outputs.each(&:close)
    end
  end

  class << self
    def run(*command, stdout: nil, env: {}, exits: [0], verbose: false)
      new(*command, stdout:, env:, exits:, verbose:).run
    end
  end

  attr_reader :command, :output, :errors, :env

  def initialize(*command, stdout: nil, env: {}, exits: [0], verbose: false)
    @command = command.flatten.compact.map(&:to_s).freeze
    @stdout = stdout
    @env = env.dup.freeze
    @exits = exits.dup.freeze
    @verbose = verbose
    @output = nil
    @errors = nil
  end

  def run
    puts "Running #{@command.join(" ")}" if @verbose

    output = StringIO.new
    errors = StringIO.new

    options = {
      stdout: @stdout == :mute ? output : TeeIO.new($stdout, output),
      stderr: TeeIO.new($stderr, errors),
      env:,
      allowed_exitstatus: @exits,
    }

    Cheetah.run(*@command, **options)

    @output = output.string.freeze
    @errors = errors.string.freeze

    self
  end

  def json
    JSON.parse(@output) unless @output.nil? && @output.empty?
  end
end
