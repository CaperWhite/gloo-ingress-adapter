# frozen_string_literal: true

require "kubeclient/resource"

module GlooIngressAdapter
  # Builder responsible to create a route table for an ingress
  class RouteTableBuilder
    def build(ingress:)
      attributes = {
        apiVersion: "gateway.solo.io/v1",
        kind: "RouteTable",
        metadata: {
          name: ingress.metadata.name,
          namespace: ingress.metadata.namespace,
          labels: build_labels(ingress:),
          ownerReferences: [
            {
              apiVersion: "networking.k8s.io/v1",
              kind: "Ingress",
              name: ingress.metadata.name,
              uid: ingress.metadata.uid,
            },
          ],
        },
        spec: {
          routes: build_routes(ingress:),
        },
      }

      Kubeclient::Resource.new(attributes)
    end

    protected

    def build_labels(ingress:)
      {
        "ingress.caperwhite.com/protocol" => ingress.spec.tls ? "https" : "http",
      }
    end

    def build_routes(ingress:)
      ingress.spec.rules.flat_map do |rule|
        rule.http&.paths&.map do |path|
          build_matcher(ingress:, rule:, path:)
        end
      end.compact
    end

    def build_matcher(ingress:, rule:, path:)
      service = path.backend.service

      {
        matchers: [
          {
            headers: headers_matcher(rule:),
            path_type(path.pathType) => path.path,
          }.compact,
        ],
        routeAction: {
          single: {
            kube: {
              ref: {
                name: service.name,
                namespace: service.namespace || ingress.metadata.namespace,
              },
              port: service.port.number || service.port.name,
            },
          },
        },
      }
    end

    HOST_PATTERN =

      def headers_matcher(rule:)
        if rule.host
          unless %r{\A(?<star>\*\.)?(?<host>(?:[-a-z0-9]+\.)*[-a-z0-9]+)\z}i =~ rule.host
            raise "Illegal host name '#{rule.host}'"
          end

          if star
            [{ name: "Host", regex: true, value: "^[^.]+\\.#{host.gsub(".", "\\.")}$" }]
          else
            [{ name: "Host", value: host }]
          end
        end
      end

    def convert_host(host); end

    def path_type(type)
      case type.downcase
      when "exact"
        :exact
      when "prefix", "implementationspecific"
        :prefix
      else
        raise "Unknown path type '#{type}'"
      end
    end
  end
end
