#!/usr/bin/env bash
# Preflight for the AKS GPU lab. Read-only: creates nothing, costs nothing.
# Run this FIRST. Every check maps to a documented prerequisite -- see
# docs/accuracy.md for the citation behind each version number.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ERRORS=0
note_fail() { fail "$1"; ERRORS=$((ERRORS + 1)); }

step "Tooling"

if ! command -v az >/dev/null 2>&1; then
  note_fail "azure-cli not found. See https://learn.microsoft.com/cli/azure/install-azure-cli"
else
  AZ_VER=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "0.0.0")
  if version_ge "$AZ_VER" "$MIN_AZ_VERSION"; then
    ok "azure-cli $AZ_VER (need >= $MIN_AZ_VERSION)"
  else
    note_fail "azure-cli $AZ_VER is older than $MIN_AZ_VERSION. Run: $(az_upgrade_hint)"
  fi
fi

if ! command -v kubectl >/dev/null 2>&1; then
  note_fail "kubectl not found. Run: az aks install-cli"
else
  ok "kubectl present"
fi

step "aks-preview extension"

# The managed GPU experience is preview-only: gpuProfile.nvidia.managementMode
# exists solely on preview API versions, so the aks-preview extension is required.
EXT_VER=$(az extension show --name aks-preview --query version -o tsv 2>/dev/null || true)
if [ -z "$EXT_VER" ]; then
  note_fail "aks-preview not installed. Run: az extension add --name aks-preview"
elif version_ge "$EXT_VER" "$MIN_AKS_PREVIEW"; then
  ok "aks-preview $EXT_VER (need >= $MIN_AKS_PREVIEW)"
else
  note_fail "aks-preview $EXT_VER < $MIN_AKS_PREVIEW. Run: az extension update --name aks-preview"
fi

step "Subscription and feature registration"

SUB_NAME=$(az account show --query name -o tsv 2>/dev/null || true)
SUB_ID=$(az account show --query id -o tsv 2>/dev/null || true)
if [ -z "$SUB_ID" ]; then
  note_fail "Not logged in. Run: az login"
else
  ok "Subscription: $SUB_NAME ($SUB_ID)"

  FEAT_STATE=$(az feature show --namespace "$FEATURE_NS" --name "$FEATURE_NAME" \
                 --query properties.state -o tsv 2>/dev/null || echo "NotFound")
  case "$FEAT_STATE" in
    Registered)  ok "Feature $FEATURE_NAME: Registered" ;;
    Registering) warn "Feature $FEATURE_NAME: Registering (propagation takes minutes)" ;;
    *)
      warn "Feature $FEATURE_NAME: $FEAT_STATE"
      info "The docs instruct registering it:"
      info "  az feature register --namespace $FEATURE_NS --name $FEATURE_NAME"
      info "This lab warns rather than fails here -- an unregistered subscription"
      info "may still work. See docs/accuracy.md D4."
      ;;
  esac
fi

step "GPU SKU availability and quota in $LAB_LOCATION"

# A SKU is usable only if it clears BOTH gates: an empty `restrictions` array
# (offerable to this subscription) AND non-zero family quota. Checking one alone
# is misleading -- westus3 shows T4 quota 0/300 while the T4 SKU itself is
# NotAvailableForSubscription there.
#
# This uses the Compute REST API rather than `az vm list-skus`: the CLI command
# filters client-side and takes over 7 minutes per call, against about 7 seconds
# for the REST call.
if [ -n "${SUB_ID:-}" ]; then
  SKU_URL="https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location%20eq%20'$LAB_LOCATION'"

  TMPD=$(mktemp -d)
  trap 'rm -rf "$TMPD"' EXIT

  az rest --method get --url "$SKU_URL" -o json > "$TMPD/skus.json" 2>/dev/null \
    || echo '{"value":[]}' > "$TMPD/skus.json"
  az vm list-usage --location "$LAB_LOCATION" -o json > "$TMPD/usage.json" 2>/dev/null \
    || echo '[]' > "$TMPD/usage.json"

  while IFS='|' read -r verdict msg; do
    [ -z "$verdict" ] && continue
    case "$verdict" in
      OK)   ok "$msg" ;;
      WARN) warn "$msg" ;;
      *)    note_fail "$msg" ;;
    esac
  done <<EOF
$("$(dirname "$0")/_check_skus.py" "$TMPD/skus.json" "$TMPD/usage.json" \
    "$LAB_SKU_T4"   "entry / modules 1-4" \
    "$LAB_SKU_A10"  "driver comparison / module 2" \
    "$LAB_SKU_A100" "inference / module 5")
EOF
fi

step "Result"
if [ "$ERRORS" -eq 0 ]; then
  ok "Preflight passed. Next: scripts/10-create-cluster.sh"
else
  fail "$ERRORS blocking issue(s). Resolve them before continuing."
fi
exit "$ERRORS"
