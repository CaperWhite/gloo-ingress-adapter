# frozen_string_literal: true

require "kubeclient/resource"

require "spec_helper"

require "yaml"

describe GlooIngressAdapter::RouteTableBuilder do
  subject { GlooIngressAdapter::RouteTableBuilder.new }

  let(:rules) do
    yaml <<-RULES
      - host: my-app.domain.local
        http:
          paths:
          - backend:
              service:
                name: my-service
                port:
                  number: 8080
            path: /my-service
            pathType: Exact
    RULES
  end

  let(:tls) do
    yaml <<-TLS
      - hosts:
        - my-app.domain.local
        secretName: my-app-tls
    TLS
  end

  let(:ingress) do
    ingress = kube_resource <<-INGRESS
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: my-ingress
        namespace: my-app
      spec:
        ingressClassName: gloo
    INGRESS

    ingress.spec.rules = rules

    ingress
  end

  let(:route_table) do
    route_table = kube_resource <<-ROUTES
      apiVersion: gateway.solo.io/v1
      kind: RouteTable
      metadata:
        name: my-ingress
        namespace: my-app
        labels:
          ingress.caperwhite.com/protocol: http
        ownerReferences:
        - apiVersion: networking.k8s.io/v1
          kind: Ingress
          name: my-ingress
          uid:
      spec: {}
    ROUTES

    route_table.spec.routes = routes

    route_table
  end

  let(:routes) do
    yaml <<-ROUTES
      - matchers:
        - headers:
          - name: Host
            value: my-app.domain.local
          exact: /my-service
        routeAction:
          single:
            kube:
              ref:
                name: my-service
                namespace: my-app
              port: 8080
    ROUTES
  end

  it "builds a route table from a HTTP ingress resource" do
    result = subject.build(ingress:)

    expect(result.to_h).to match(route_table.to_h)
  end

  it "builds a route table from a HTTPS ingress resource" do
    ingress.spec.tls = tls

    result = subject.build(ingress:)

    expect(result.metadata.labels["ingress.caperwhite.com/protocol"]).to eq("https")
  end

  it "maps exact routes" do
    ingress.spec.rules.first.http.paths.first.pathType = "Exact"

    result = subject.build(ingress:)

    expect(result.spec.routes.first.matchers.first.exact).to eq("/my-service")
  end

  it "maps prefix routes" do
    ingress.spec.rules.first.http.paths.first.pathType = "Prefix"

    result = subject.build(ingress:)

    expect(result.spec.routes.first.matchers.first.prefix).to eq("/my-service")
  end

  it "maps implementation specific routes to prefix matcher" do
    ingress.spec.rules.first.http.paths.first.pathType = "ImplementationSpecific"

    result = subject.build(ingress:)

    expect(result.spec.routes.first.matchers.first.prefix).to eq("/my-service")
  end

  it "maps routes without host name" do
    ingress.spec.rules.first.host = nil

    result = subject.build(ingress:)

    expect(result.spec.routes.first.matchers.first.headers).to be_nil
  end

  it "maps routes with host name" do
    ingress.spec.rules.first.host = "my-app.domain.local"

    result = subject.build(ingress:)
    expected = { name: "Host", value: "my-app.domain.local" }

    expect(result.spec.routes.first.matchers.first.headers.first.to_h).to eq(expected)
  end

  it "maps routes with wildcard host" do
    ingress.spec.rules.first.host = "*.domain.local"

    result = subject.build(ingress:)
    expected = { name: "Host", regex: true, value: "^[^.]+\\.domain\\.local$" }

    expect(result.spec.routes.first.matchers.first.headers.first.to_h).to eq(expected)
  end
end
