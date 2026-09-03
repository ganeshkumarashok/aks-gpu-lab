# Module 7: Ingress and routing

The service so far is `ClusterIP`: reachable only from inside the cluster. This
module puts a gateway in front of it.

```bash
az aks approuting enable --resource-group "$LAB_RG" --name "$LAB_CLUSTER"
kubectl apply -f manifests/gateway.yaml
```

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

## What the gateway handles

| Concern | Why it belongs at the gateway |
|---|---|
| Timeouts | generation takes tens of seconds; defaults elsewhere are far shorter |
| Load balancing | spreads requests across replicas without client awareness |
| TLS termination | one place to hold the certificate |
| Traffic splitting | shifting a percentage of traffic to a new model version |
| Path routing | `/v1` to the model server, health and metrics elsewhere |

## The timeout is the setting that bites

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

To confirm requests are reaching more than one replica:

```bash
kubectl logs -n inference -l app.kubernetes.io/name=vllm --prefix --tail=5 | grep -c "POST /v1"
```

## Production gaps this module leaves open

- **No TLS.** The listener is HTTP on port 80. See
  [Gateway API with DNS and TLS](https://learn.microsoft.com/azure/aks/app-routing-gateway-api-dns-tls).
- **No authentication.** Anyone who can reach the address can spend GPU time.
  Put an auth layer in front before exposing this anywhere real.
- **No rate limiting.** One client can occupy every replica's queue.

## Next

[Module 8: Scaling, and what it cannot fix](08-scaling.md)
