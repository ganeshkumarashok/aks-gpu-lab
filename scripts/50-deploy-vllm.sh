#!/usr/bin/env bash
# Module 6 -- deploy the inference service on the A100 node pool.
# Requires the a100 pool and staged model weights:
#   scripts/20-add-managed-gpu-nodepool.sh a100
#   kubectl apply -f manifests/model-storage.yaml
#   kubectl apply -f manifests/model-stage-job.yaml

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step "Deploying vLLM"
kubectl apply -f "$ROOT/manifests/vllm-serving.yaml"

step "Waiting for rollout"
info "First start downloads ~15 GB and loads the model. Budget 10-25 minutes."
info "Follow along in another shell with:"
info "  kubectl logs -n gpu-lab -l app.kubernetes.io/name=vllm -f"

if kubectl rollout status deployment/vllm -n gpu-lab --timeout=3600s; then
  ok "vLLM is ready"
else
  fail "Rollout did not complete. Diagnostics:"
  kubectl get pods -n gpu-lab -o wide
  kubectl describe pod -n gpu-lab -l app.kubernetes.io/name=vllm | tail -30
  exit 1
fi

# `kubectl run --rm -i` races the pod deletion against log retrieval and can
# return an empty body plus a non-zero exit even when the request succeeded.
# Run the pod, wait for Succeeded, read logs, then delete.
probe() {
  name="$1"; shift
  kubectl delete pod "$name" -n gpu-lab --ignore-not-found >/dev/null 2>&1
  kubectl run "$name" -n gpu-lab --restart=Never \
    --image=mcr.microsoft.com/azurelinux/base/core:3.0 \
    --command -- /bin/sh -c "$1" >/dev/null 2>&1
  if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" \
       -n gpu-lab --timeout=180s >/dev/null 2>&1; then
    kubectl logs -n gpu-lab "$name"
  else
    fail "probe '$name' did not succeed"
    kubectl logs -n gpu-lab "$name" 2>&1 | head -5
  fi
  kubectl delete pod "$name" -n gpu-lab --ignore-not-found >/dev/null 2>&1
}

step "Smoke test -- list models"
probe vllm-models 'curl -s --max-time 30 http://vllm:8000/v1/models' \
  | python3 -m json.tool 2>/dev/null | head -12

step "Smoke test -- completion"
probe vllm-chat 'curl -s --max-time 90 http://vllm:8000/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"Qwen/Qwen2.5-7B-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: GPU lab online.\"}],\"max_tokens\":16,\"temperature\":0}"' \
  | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print('  response      :', repr(d['choices'][0]['message']['content']))
    print('  finish_reason :', d['choices'][0]['finish_reason'])
    print('  usage         :', d['usage'])
except Exception as e:
    print('  could not parse response:', e)"

step "GPU utilization during inference"
info "vLLM exposes its own Prometheus metrics on :8000/metrics; DCGM exposes"
info "device-level metrics on :19400. Compare them -- they answer different questions."
info "  vLLM  : queue depth, tokens/sec, TTFT   (is the SERVER busy?)"
info "  DCGM  : SM utilization, memory, power   (is the GPU busy?)"
