# Project

Use [Gloo Edge][gloo] gateways with Kubernetes ingress resources. Gloo Edge supports ingress, however it requires you
to deploy a separate gateway for this. With this adapter, you can integrate your Kubernetes ingresses into an existing
gateway.

The adapter works by monitoring ingress resources and automatically creating a Gloo route table for each ingress. You
can then mount the created route tables automatically in your gateway.

[gloo]: https://docs.solo.io/gloo-edge/latest/

## Install

Install a Gloo Edge gateway:

```bash
kubectl create namespace gloo-system
helm install gloo gloo --namespace gloo-system --repo https://storage.googleapis.com/solo-public-helm \
  --set gateway.readGatewaysFromAllNamespaces=true
```

You can also have a look at the [Gloo documentation][gloo-install] for detailed installation instructions.

[gloo-install]: https://docs.solo.io/gloo-edge/master/installation/gateway/kubernetes/

Install the ingress adapter into namespace `gloo-system`:

```bash
git checkout git@github.com:CaperWhite/gloo-ingress-adapter.git
cd gloo-ingress-adapter
helm --namespace gloo-system install gloo-ingress-adapter charts
```

After this, the ingress adapter should be up and running, and monitoring ingress resources. By default it will create
route tables for ingress resources with ingress class name `gloo-route`.

## Verify installation

Deploy a test service:

```bash
kubectl create namespace ingress-test
kubectl --namespace ingress-test apply --filename examples/test.yaml
```

Create an ingress resource for the test service:

```bash
cat <<-INGRESS | kubectl apply --namespace ingress-test --filename -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-test
spec:
  ingressClassName: gloo-route
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ingress-test
            port:
              number: 8080
INGRESS
```

Verify a route table has been created:

```bash
kubectl --namespace ingress-test get routetable ingress-test -o yaml
```

Create a virtual service resource that automatically mounts the created route tables:

```bash
cat <<-SERVICE | kubectl --namespace gloo-system apply --filename -
apiVersion: gateway.solo.io/v1
kind: VirtualService
metadata:
  name: ingress-test
spec:
  virtualHost:
    domains:
    - ingress-test.local
    routes:
    - matchers:
       - prefix: "/"
      delegateAction:
        selector:
          labels:
            ingress.caperwhite.com/protocol: http
          namespaces:
          - ingress-test
SERVICE
```

Make the gateway accessible locally:

```bash
kubectl --namespace gloo-system port-forward service/gateway-proxy 8080:80
```

Check if you can access the service:

```bash
curl -H 'Host: ingress-test.local' http://127.0.0.1:8080
```

should return

```json
{"result":true}
```

Delete the ingress:

```bash
kubectl --namespace ingress-test delete ingress ingress-test
```

Verify the route table is gone:

```bash
kubectl --namespace ingress-test get routetable -A
```

## Acknowledgements

"Gloo" is a trademark of [Solo.io, Inc.][solo].

[solo]: https://www.solo.io
