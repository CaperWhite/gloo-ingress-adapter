# frozen_string_literal: true

require "active_support/core_ext/string"
require "gloo_ingress_adapter/resource_observer"
require "kubeclient"
require "logger"
require "set"
require "yaml"

module GlooIngressAdapter
  # Controller responsible for creating virtual services from ingress resources
  class Controller
    CONTROLLER_NAME = "caperwhite.com/gloo-ingress-adapter"

    StopMessage = Class.new

    def initialize(kubeconfig:, logger:, route_table_builder:)
      @client_factory = ClientFactory.new(kubeconfig:, logger:).freeze
      @logger = logger
      @route_table_builder = route_table_builder
      @active_ingress_classes = Set.new
      @lock = Thread::Mutex.new
      @queue = Thread::Queue.new

      @ingress_class_observer = ResourceObserver.new(
        type: "IngressClass",
        name: "ingressclasses",
        client: client_factory.create_client(version: "v1", api: "networking.k8s.io"),
        queue:,
        logger:
      )

      @ingress_observer = ResourceObserver.new(
        type: "Ingress",
        name: "ingresses",
        client: client_factory.create_client(version: "v1", api: "networking.k8s.io"),
        queue:,
        logger:
      )
    end

    def run(watch: true)
      logger.info("Running ingress adapter version #{VERSION}")

      reset

      if watch
        ingress_class_observer.start
        ingress_observer.start

        keep_watch
      end
    end

    def stop
      @lock.synchronize do
        @queue << StopMessage.new
      end
    end

    protected

    attr_reader :logger, :queue, :client_factory, :ingress_classes, :ingress_class_observer, :ingress_observer

    def reset
      @ingress_classes = ingress_class_observer.list

      @active_ingress_classes = ingress_classes.select do |ingress_class|
        ingress_class.spec.controller == CONTROLLER_NAME
      end.map do |ingress_class|
        ingress_class.metadata.name
      end.to_set

      logger.info("Active ingress classes: #{@active_ingress_classes.fuse(", ", empty: "<none>")}")

      ingresses = ingress_observer.list

      ingresses.each do |ingress|
        update_ingress(ingress)
      end
    end

    def keep_watch
      loop do
        event = queue.shift

        case event
        when Kubeclient::Resource
          handle_event(event)
        when ResourceObserver::ResetMessage
          reset
        when StopMessage
          break
        else
          raise "Unknown event #{event}"
        end
      end
    rescue StandardError => e
      logger.error(e)
    ensure
      failsafe do
        ingress_class_observer.stop
      end

      failsafe do
        ingress_observer.stop
      end
    end

    def activate_ingress_class(ingress_class)
      logger.info("Activating or updating ingress class #{ingress_class.metadata.name}")

      if ingress_class.spec.controller == CONTROLLER_NAME
        @active_ingress_classes << ingress_class.metadata.name
      else
        @active_ingress_classes.delete(ingress_class.metadata.name)
      end

      logger.info("Active ingress classes: #{@active_ingress_classes.fuse(", ", empty: "<none>")}")

      activate_ingresses(ingress_class:) if ingress_class.spec.controller == CONTROLLER_NAME
    end

    def activate_ingresses(ingress_class:)
      networking_client.get_ingresses.select do |ingress|
        ingress.spec.ingressClassName == ingress_class.metadata.name
      end.each do |ingress|
        activate_ingress(ingress)
      end
    end

    def deactivate_ingresses(ingress_class:)
      networking_client.get_ingresses.select do |ingress|
        ingress.spec.ingressClassName == ingress_class.metadata.name
      end.each do |ingress|
        deactivate_ingress(ingress)
      end
    end

    def deactivate_ingress_class(ingress_class)
      logger.info("Deactivating ingress class #{ingress_class.metadata.name}")

      deactivate_ingresses(ingress_class:) if ingress_class.spec.controller == CONTROLLER_NAME
    end

    def update_ingress(ingress)
      if handle_ingress(ingress)
        activate_ingress(ingress)
      else
        deactivate_ingress(ingress)
      end
    end

    def activate_ingress(ingress)
      logger.info("Activating or updating ingress #{ingress_info(ingress)}")

      update_route_table(ingress:)
    end

    def deactivate_ingress(ingress)
      logger.info("Deactivating ingress #{ingress_info(ingress)}")

      remove_route_table(ingress:)
    end

    def handle_event(event)
      raise("Received error event: #{event.to_nice_yaml}") if event.type == "ERROR"

      logger.info("Handling event: #{event.object.kind} #{event.object.metadata.name} #{event.type.downcase}")
      logger.debug { "Event object: #{event.to_nice_yaml}" }

      raise "Unknown API version '#{event.object.apiVersion}'" if event.object.apiVersion != "networking.k8s.io/v1"

      case event.object.kind
      when "IngressClass"
        handle_ingress_class_event(event)
      when "Ingress"
        handle_ingress_event(event)
      else
        raise "Received event for unknown object kind '#{event.object.kind}'"
      end
    end

    def handle_ingress_class_event(event)
      case event.type
      when "ADDED", "MODIFIED"
        activate_ingress_class(event.object)
      when "DELETED"
        deactivate_ingress_class(event.object)
      else
        logger.error("Unknown event type '#{event.type}'")
      end
    end

    def handle_ingress_event(event)
      case event.type
      when "ADDED", "MODIFIED"
        update_ingress(event.object)
      when "DELETED"
        # Do nothing
      else
        logger.error("Unknown event type '#{event.type}'")
      end
    end

    def update_route_table(ingress:)
      logger.info "Updating route table for ingress #{ingress_info(ingress)}"
      logger.debug { ingress.to_nice_yaml }

      route_table = @route_table_builder.build(ingress:)

      logger.debug { route_table.to_nice_yaml }

      gateway_client.apply_route_table(route_table, field_manager: "gloo-ingress-adapter", force: true)
    end

    def remove_route_table(ingress:)
      route_table = begin
        gateway_client.get_route_table(ingress.metadata.name, ingress.metadata.namespace)
      rescue Kubeclient::ResourceNotFoundError
        nil
      end

      if route_table && route_table.metadata.ownerReferences.any? { |owner| owner.uid == ingress.metadata.uid }
        logger.info "Deleting route table for ingress #{ingress_info(ingress)}"
        logger.debug { ingress.to_nice_yaml }
        gateway_client.delete_route_table(ingress.metadata.name, ingress.metadata.namespace)
      end
    end

    def failsafe
      yield
    rescue StandardError => e
      logger.error(e)
      nil
    end

    def client
      @client ||= client_factory.create_client(version: "v1")
    end

    def networking_client
      @networking_client ||= client_factory.create_client(version: "v1", api: "networking.k8s.io")
    end

    def gateway_client
      @gateway_client ||= client_factory.create_client(version: "v1", api: "gateway.solo.io")
    end

    def handle_ingress(ingress)
      @active_ingress_classes.include?(ingress.spec.ingressClassName)
    end

    def ingress_info(ingress)
      <<~MSG.squish
        #{ingress.metadata.name}
          (namespace: #{ingress.metadata.namespace},
          ingressClassName: #{ingress.spec.ingressClassName || "<none>"})
      MSG
    end
  end
end
