# Module 7: Ingress and routing

The service so far is `ClusterIP`: reachable only from inside the cluster. This
module puts a gateway in front of it.

```bash
# 1. Install the managed Gateway API CRDs
az aks update --resource-group "$LAB_RG" --name "$LAB_CLUSTER" --enable-gateway-api

# 2. Enable the Gateway API implementation of the application routing add-on
az aks update --resource-group "$LAB_RG" --name "$LAB_CLUSTER" --enable-app-routing-istio

kubectl apply -f manifests/gateway.yaml
```

Both steps are required. Three similar-looking commands do different things;
only the first two run in this lab.

| Command | Result |
|---|---|
| `az aks update --enable-gateway-api` | installs the managed Gateway API CRDs. Self-managed CRDs are not supported with the add-on |
| `az aks update --enable-app-routing-istio` | the Gateway API implementation, backed by an Istio control plane |
| `az aks approuting enable` | managed **NGINX**, the implementation losing Azure support after November 2026 |

Skipping the first step leaves the add-on running with no CRDs, and applying a
`Gateway` fails with:

```
no matches for kind "Gateway" in version "gateway.networking.k8s.io/v1"
ensure CRDs are installed first
```

`az aks update` can return exit code 0 without applying the change when another
update is already in flight on the cluster. Confirm the resulting state rather
than trusting the exit code:

```bash
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get gatewayclass approuting-istio
```

The first confirms the CRDs from step 1 landed; the second confirms the Istio
implementation from step 2 registered its `GatewayClass`.

Requires `azure-cli` 2.86.0 or later.

## Why Gateway API rather than Ingress

The managed NGINX Ingress add-on stops receiving Azure support after
**November 2026**. The application routing add-on's Gateway API implementation
is its designated successor, and it provisions an Istio control plane to serve
Gateway API resources
([AKS documentation](https://learn.microsoft.com/azure/aks/app-routing-gateway-api)).

For inference specifically, Gateway API matters beyond replacing Ingress. The
Ingress API has no vocabulary for per-route timeouts, retries, or traffic
splitting without controller-specific annotations. Those are exactly the
controls an inference endpoint needs, and Gateway API expresses them as typed
fields.

## Concerns that belong at the gateway

This lab's `gateway.yaml` configures timeouts and path routing. TLS termination
and traffic splitting are listed here because Gateway API supports them, not
because this lab turns them on; TLS is an open gap (see below), and traffic
splitting is not exercised in this lab.

| Concern | Why it belongs at the gateway |
|---|---|
| Timeouts | generation takes tens of seconds; defaults elsewhere are far shorter |
| Load balancing | spreads requests across replicas without client awareness |
| TLS termination | one place to hold the certificate |
| Traffic splitting | shifting a percentage of traffic to a new model version |
| Path routing | `/v1` to the model server, health and metrics elsewhere |

## Setting the request timeout

```yaml
timeouts:
  request: 300s
  backendRequest: 300s
```

A long completion can run for minutes. Gateway and proxy defaults are typically
30 to 60 seconds, so without this a long generation is cut off after the compute
has already been spent on it. The failure looks like a client-side error rather
than a timeout, which makes it slow to diagnose.

## What this is not

This gateway load balances across replicas. It does **not** route based on model
awareness: it does not know which replica already holds a relevant KV cache
prefix, how deep each replica's queue is, or which replicas serve which LoRA
adapters.

That capability is what the
[Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/)
adds, through an `InferencePool` and an endpoint picker that reads live metrics
from each replica. Projects such as [llm-d](https://llm-d.ai) build on it.

AKS does not document the Inference Extension, and this lab does not deploy it.
Module 8 covers where plain load balancing stops being sufficient.

## Verify

Get the external address:

```bash
kubectl get gateway -n inference inference-gateway \
  -o jsonpath='{.status.addresses[0].value}'
```

Then call the model through it:

```bash
GW=$(kubectl get gateway -n inference inference-gateway -o jsonpath='{.status.addresses[0].value}')
curl -s "http://$GW/v1/models" | python3 -m json.tool
curl -s "http://$GW/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen","messages":[{"role":"user","content":"Say hello."}],"max_tokens":16}'
```

To confirm requests are reaching more than one replica, send several requests
through the gateway rather than checking after a single call:

```bash
for i in $(seq 1 10); do
  curl -s -o /dev/null -w '%{http_code}\n' "http://$GW/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen","messages":[{"role":"user","content":"Say hello."}],"max_tokens":16}'
done
```

Every line should read `200`. Then check which pods served them:

```bash
kubectl logs -n inference -l app.kubernetes.io/name=vllm --prefix --tail=5 | grep -c "POST /v1"
kubectl logs -n inference -l app.kubernetes.io/name=vllm --prefix --tail=5 | grep "POST /v1" | grep -oE '^\[[^]]+\]' | sort | uniq -c
```

The first command gives a total line count across both pods; the second breaks
it down by pod, so more than one distinct prefix confirms the gateway is
spreading load rather than pinning it to one replica. This architecture was
verified end to end: two replicas on separate nodes, sharing the model volume
over `ReadWriteMany`, with 10 requests through the gateway returning HTTP 200
split 6/5 across the replicas.

## Production gaps this module leaves open

- **No TLS.** The listener is HTTP on port 80. See
  [Gateway API with DNS and TLS](https://learn.microsoft.com/azure/aks/app-routing-gateway-api-dns-tls).
- **No authentication.** Anyone who can reach the address can spend GPU time.
  Put an auth layer in front before exposing this anywhere real.
- **No rate limiting.** One client can occupy every replica's queue.

## Next

[Module 8: Scaling, and what it cannot fix](08-scaling.md)
