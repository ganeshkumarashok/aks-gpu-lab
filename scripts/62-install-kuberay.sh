#!/usr/bin/env bash
# Module 9 (capstone) -- install the KubeRay operator.
#
# Versions and the chart source follow the AKS Ray reference implementation
# (Azure/AKS examples/kueue-and-ray-on-aks). The chart is an OCI artifact on MCR,
# not the upstream kuberay.github.io repo.
#
# Kueue is NOT installed here. The AKS docs state twice that RayService is not
# admission-controlled by Kueue -- serving workloads are long-lived and want
# dedicated resources rather than batch queue semantics. Kueue matters for RayJob.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

: "${KUBERAY_CHART_VERSION:=1.6.1}"
: "${KUBERAY_OPERATOR_IMAGE:=mcr.microsoft.com/oss/v2/kuberay/operator}"
: "${KUBERAY_OPERATOR_TAG:=v1.6.1}"

step "Installing KubeRay operator $KUBERAY_CHART_VERSION"

command -v helm >/dev/null 2>&1 || { fail "helm not found. Install: https://helm.sh/docs/intro/install/"; exit 1; }

CTX=$(kubectl config current-context 2>/dev/null || echo "?")
info "kubectl context: $CTX"
case "$CTX" in
  "$CAP_CLUSTER") : ;;
  *) warn "Context is '$CTX', expected '$CAP_CLUSTER'. Run scripts/60-capstone-cluster.sh first." ;;
esac

if helm status kuberay-operator -n kuberay-system >/dev/null 2>&1; then
  ok "kuberay-operator already installed"
else
  # ENABLE_INIT_CONTAINER_INJECTION adds a wait-for-ray-gcs init container to
  # every Ray pod. GCS here is Ray's Global Control Store, not Google Cloud
  # Storage. The MCR Ray images depend on it for startup ordering.
  helm install kuberay-operator \
    "oci://mcr.microsoft.com/aks/ai-runtime/helm/kuberay-operator" \
    --version "$KUBERAY_CHART_VERSION" \
    --namespace kuberay-system \
    --create-namespace \
    --set "image.repository=$KUBERAY_OPERATOR_IMAGE" \
    --set "image.tag=$KUBERAY_OPERATOR_TAG" \
    --set "env[0].name=ENABLE_INIT_CONTAINER_INJECTION" \
    --set-string "env[0].value=true" \
    --wait --timeout 10m
  ok "kuberay-operator installed"
fi

step "Verify"
kubectl -n kuberay-system get pods
echo
info "CRDs registered:"
kubectl get crd 2>/dev/null | grep -E "ray(cluster|service|job)s\.ray\.io" || warn "No ray.io CRDs found"

step "Next"
info "Run scripts/63-deploy-rayservice.sh"
