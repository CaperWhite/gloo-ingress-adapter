# frozen_string_literal: true

require "kubeclient"

module GlooIngressAdapter
  # Watcher for ingress resources
  class ResourceObserver
    HTTP_GONE = 410

    # Message sent to reset observation
    class ResetMessage
      attr_reader :observer

      def initialize(observer:)
        @observer = observer
      end
    end

    attr_reader :type, :name, :field_selector

    def initialize(client:, type:, name:, queue:, logger:, field_selector: nil)
      @client = client
      @type = type
      @name = name
      @queue = queue
      @logger = logger
      @field_selector = field_selector&.dup&.freeze
      @resource_version = nil
      @lock = Thread::Mutex.new
      @stopped = false
      @watcher = nil
      @thread = nil
    end

    def list
      logger.info("Listing #{type} resources#{field_selector && " with #{field_selector.to_json}"}")

      entities = client.get_entities(type, name, **watcher_options.except(:resource_version))
      self.resource_version = entities.resourceVersion
      entities
    end

    def start
      @lock.synchronize do
        raise "Observer already started" if @thread

        @thread = Thread.new do
          watch
        ensure
          self.thread = nil
        end

        @thread.name = "observer-#{name}"
        @thread.abort_on_exception = true

        @thread
      end
    end

    def stop
      @lock.synchronize do
        @stopped = true
        @watcher&.finish
      end
    end

    def stopped?
      @lock.synchronize do
        @stopped
      end
    end

    protected

    attr_reader :client, :queue, :logger

    def watch
      logger.info("Watching #{type} resources#{field_selector && " with #{field_selector.to_json}"}")

      retriable do
        run_watch
      end
    rescue StandardError => e
      logger.error("Error watching #{type} resources: #{e.full_message}")
      raise(e)
    end

    def watcher
      @lock.synchronize do
        @watcher
      end
    end

    def watcher=(watcher)
      @lock.synchronize do
        @watcher = watcher
      end
    end

    def resource_version
      @lock.synchronize do
        @resource_version
      end
    end

    def resource_version=(resource_version)
      @lock.synchronize do
        @resource_version = resource_version
      end
    end

    def thread
      @lock.synchronize do
        @thread
      end
    end

    def thread=(thread)
      @lock.synchronize do
        @thread = thread
      end
    end

    def run_watch
      watcher = client.watch_entities(name, **watcher_options)

      watcher.each do |event|
        logger.info("Received event: #{event.object.kind} #{event.object.metadata.name} #{event.type.downcase}")
        queue << event
        self.resource_version = event.resourceVersion
      end

      raise "Watcher thread #{Thread.current.name} silently failed" unless stopped?
    rescue KubeException => e
      if e.error_code == HTTP_GONE
        self.resource_version = nil
        queue << ResetMessage.new(observer: self)
      end

      raise(e)
    ensure
      self.watcher = nil
    end

    def retriable
      remaining_attempts = 5
      backoff_seconds = 1

      begin
        yield
      rescue StandardError => e
        logger.error("Error watching #{type} resources: #{e.message} (#{e.class})")

        if remaining_attempts.positive?
          sleep(backoff_seconds)

          remaining_attempts -= 1
          backoff_seconds *= 2

          retry
        end

        raise(e)
      end
    end

    def watcher_options
      {
        field_selector:,
        resource_version:,
      }.compact
    end
  end
end
