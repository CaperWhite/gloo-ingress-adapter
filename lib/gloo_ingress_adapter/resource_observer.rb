# frozen_string_literal: true

require "kubeclient"

module GlooIngressAdapter
  # Watcher for ingress resources
  class ResourceObserver
    # Thread running an observer
    class ObserverThread < Thread
      attr_reader :observer

      def initialize(observer:, queue:)
        @observer = observer

        super { observer.watch(queue:) }

        self.abort_on_exception = true
        self.name = "observer-#{observer.kind}"
      end

      def finish
        observer.watcher.finish
      end
    end

    attr_reader :kind

    def initialize(kind:, client:, logger:, field_selector: nil)
      @kind = kind
      @client = client
      @logger = logger
      @field_selector = field_selector
      @watcher = nil
      @lock = Mutex.new
    end

    def start(queue:)
      ObserverThread.new(observer: self, queue:)
    end

    def watch(queue:)
      logger.info("Watching #{kind}#{field_selector && " with #{field_selector.to_json}"}")

      retriable do
        self.watcher = client.watch_entities(kind, field_selector:, as: :ros)

        watcher.each do |event|
          logger.info("Received event: #{event.object.kind} #{event.object.metadata.name} #{event.type.downcase}")
          queue << event
        end
      end
    rescue StandardError => e
      logger.error("Error observing #{kind} resources: #{e.full_message}")
      raise(e)
    ensure
      self.watcher = nil
    end

    def stop
      watcher&.finish
    end

    protected

    attr_reader :client, :logger, :field_selector

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

    def retriable(&)
      retry_proc = proc do |exception|
        logger.error(exception.full_message)
      end

      Retriable.retriable(tries: 10, base_interval: 1, on_retry: retry_proc, &)
    end
  end
end
