# frozen_string_literal: true

require "active_support/core_ext/string"
require "gloo_ingress_adapter/resource_observer"
require "kubeclient"
require "logger"
require "retriable"
require "set"
require "yaml"

module GlooIngressAdapter
  # Controller responsible for creating virtual services from ingress resources
  class Controller
    CONTROLLER_NAME = "caperwhite.com/gloo-ingress-adapter"

    RETRY_ON = {
      StandardError: nil,
    }.freeze

    def initialize(kubeconfig:, logger:, route_table_builder:)
      @client_factory = ClientFactory.new(kubeconfig:, logger:).freeze
      @logger = logger
      @route_table_builder = route_table_builder
      @ingress_classes = {}
      @ingresses = {}
    end

    def run
      logger.info("Running ingress adapter")
    end

    def watch
      logger.info("Starting ingress adapter")

      queue = Thread::Queue.new

      ingress_class_observer = create_ingress_class_observer

      ingress_class_observer.start(queue:)

      ingress_observer = create_ingress_observer

      ingress_observer.start(queue:)

      loop do
        event = queue.shift
        handle_event(event)
      end
    rescue StandardError => e
      log_exception(e)
    end

    protected

    attr_reader :logger, :queue, :client_factory, :ingress_classes, :ingresses

    def update_ingress_class(ingress_class)
      logger.info("Updating ingress class #{ingress_class.metadata.name}")

      existing_ingress_class = @ingress_classes[ingress_class.metadata.uid]

      @ingress_classes[ingress_class.metadata.uid] = ingress_class

      if @ingress_classes.empty?
        logger.warn("Now handling no ingress classes")
      else
        logger.info("Now handling ingress classes #{@ingress_classes.values.map { |c| c.metadata.name }.join(", ")}")
      end

      controller_changed = existing_ingress_class.nil? ||
                           ingress_class.spec.controller != existing_ingress_class.spec.controller

      ingress_class_name_changed = existing_ingress_class.nil? ||
                                   existing_ingress_class.metadata.name != ingress_class.metadata.name

      if controller_changed
        if ingress_class.spec.controller == CONTROLLER_NAME
          update_ingresses(ingress_class:)
        elsif existing_ingress_class && existing_ingress_class.spec.controller == CONTROLLER_NAME
          delete_ingresses(ingress_class:) if controller_changed
        end
      elsif ingress_class_name_changed
        update_ingresses(ingress_class:)
      end
    end

    def update_ingresses(ingress_class:)
      @ingresses.values.filter do |u|
        u.spec.ingressClassName == ingress_class.metadata.name
      end.each do |ingress|
        update_ingress(ingress)
      end
    end

    def delete_ingressses(ingress_class:)
      @ingresses.values.filter do |u|
        u.spec.ingressClassName == ingress_class.metadata.name
      end.each do |ingress|
        networking_client.delete_ingress(ingress.metadata.name, ingress.metadata.namespace)
      end
    end

    def remove_ingress_class(uid:)
      ingress_class = @ingress_classes.delete(uid) || raise("Unknown ingress class uid '#{uid}'")

      logger.info("Removing ingress class #{ingress_class.metadata.name}")

      delete_ingresses(ingress_class:) if ingress_class.spec.controller == CONTROLLER_NAME

      ingress_class
    end

    def update_ingress(ingress)
      @ingresses[ingress.metadata.uid] = ingress

      msg = <<~MSG.squish
        #{ingress.metadata.name} (namespace: #{ingress.metadata.namespace},
        ingressClass: #{ingress.spec.ingressClassName || "(none)"})
      MSG

      if ingress_class_names.include?(ingress.spec.ingressClassName)
        logger.info("Updating ingress #{msg}")

        update_route_table(ingress:)
      else
        logger.info("Ignoring ingress #{msg}")
      end
    end

    def remove_ingress(uid:)
      ingress = @ingress_classes.delete(uid) || raise("Unknown ingress class uid '#{uid}'")

      logger.info("Removed ingress #{ingress.metadata.name} (namespace: #{ingress.metadata.namespace})")

      ingress
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
        update_ingress_class(event.object)
      when "DELETED"
        remove_ingress_class(event.object.metadata.name)
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
      metadata = ingress.metadata

      logger.info "Updating route table for ingress '#{metadata.name}' (namespace: '#{metadata.namespace}')"
      logger.debug { ingress.to_nice_yaml }

      route_table = @route_table_builder.build(ingress:)

      logger.debug { route_table.to_nice_yaml }

      gateway_client.apply_route_table(route_table, field_manager: "gloo-ingress-adapter", force: true)
    end

    def create_ingress_class_observer
      ResourceObserver.new(
        kind: "ingressclasses",
        client: client_factory.create_client(version: "v1", api: "networking.k8s.io"),
        logger:
      )
    end

    def create_ingress_observer
      ResourceObserver.new(
        kind: "ingresses",
        client: client_factory.create_client(version: "v1", api: "networking.k8s.io"),
        logger:
      )
    end

    def ingress_class_names
      @ingress_classes.values.map { |c| c.metadata.name }
    end

    def log_exception(exception)
      logger.error("#{exception.message} (#{exception.class}/#{exception.class.ancestors})")
      logger.debug(exception.backtrace.join("\n"))
    end

    def failsafe
      yield
    rescue StandardError => e
      log_exception(e)
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
  end
end
