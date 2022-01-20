# frozen_string_literal: true

require "kubeclient"

module GlooIngressAdapter
  # Factory for Kubernetes clients
  class ClientFactory
    KUBERNETES_API_URL = "https://kubernetes.default.svc"

    def initialize(kubeconfig:, logger:)
      @kubeconfig = kubeconfig.freeze
      @logger = logger
    end

    def create_client(version:, api: nil)
      suffix = api ? "/apis/#{api}" : ""

      options = {
        timeouts: { open: 30, read: 30 },
      }

      url = KUBERNETES_API_URL

      if @kubeconfig
        context = Kubeclient::Config.read(@kubeconfig).context

        url = context.api_endpoint

        options[:auth_options] = context.auth_options
        options[:ssl_options] = context.ssl_options
      else
        options[:auth_options] = { bearer_token_file: "/var/run/secrets/kubernetes.io/serviceaccount/token" }

        if File.exist?("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
          options[:ssl_options] = { ca_file: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" }
        end
      end

      Kubeclient::Client.new("#{url}#{suffix}", version, **options)
    end
  end
end
