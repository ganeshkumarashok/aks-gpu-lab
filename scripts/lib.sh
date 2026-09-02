#!/usr/bin/env bash
# Shared config and helpers for the AKS GPU lab.
# Source this from every script: . "$(dirname "$0")/lib.sh"
#
# Every constant and helper here is consumed by the numbered scripts that
# source it. shellcheck cannot follow usage across a source boundary, so
# SC2034 would fire on all of them.
# shellcheck disable=SC2034

set -euo pipefail

# ---- Lab configuration -------------------------------------------------------
# westus2 is the only region in this subscription where all three lab SKUs clear
# BOTH gates: unrestricted for the subscription (empty `restrictions` in
# `az vm list-skus`) AND non-zero family quota (`az vm list-usage`). Checking
# only quota is misleading -- westus3 shows T4 quota 0/300 but the SKU itself is
# NotAvailableForSubscription there. preflight.sh checks both.
: "${LAB_LOCATION:=westus2}"
: "${LAB_RG:=aks-gpu-lab-rg}"
: "${LAB_CLUSTER:=aks-gpu-lab}"

# Entry SKU: 1x T4 16GB. Matches the headline example in aks-managed-gpu-nodes.md.
: "${LAB_SKU_T4:=Standard_NC4as_T4_v3}"
# Driver-comparison SKU: 1x A10 24GB. Not the inference SKU -- see module 5 for
# why its GRID vGPU profile rules it out.
: "${LAB_SKU_A10:=Standard_NV36ads_A10_v5}"
# Inference SKU: 1x A100 80GB. Used by module 5 (vLLM); see the node pool
# comment below for why.
: "${LAB_SKU_A100:=Standard_NC24ads_A100_v4}"

: "${LAB_NODEPOOL_T4:=gpunp}"
: "${LAB_NODEPOOL_A10:=infnp}"
# NC-series A100. Used for the inference module because NV-series runs a GRID
# vGPU profile where DCGM cannot report power, temperature, or any
# DCGM_FI_PROF_* field. NC-series gets the datacenter driver and full telemetry.
: "${LAB_NODEPOOL_A100:=a100np}"

# ---- Capstone (module 6) -- separate region and cluster ---------------------
# The H100 RDMA SKU has quota only in swedencentral, which has no T4 or A10
# quota at all, so the capstone cannot share a cluster with modules 0-5.
: "${CAP_LOCATION:=swedencentral}"
: "${CAP_RG:=aks-gpu-lab-capstone-rg}"
: "${CAP_CLUSTER:=aks-gpu-capstone}"
: "${CAP_SKU:=Standard_ND96isrf_H100_v5}"   # 8x H100 80GB, RdmaEnabled=True
: "${CAP_NODEPOOL:=h100np}"
: "${CAP_NODE_COUNT:=2}"                     # 2 x 96 vCPU = the entire family quota

# The GPU node taint used throughout. AKS does NOT apply this automatically;
# every GPU pod in this lab carries the matching toleration.
: "${LAB_GPU_TAINT:=sku=gpu:NoSchedule}"

# Minimum versions. Sourced from the docs, with the discrepancy noted in
# docs/accuracy.md -- we enforce the documented (stricter) numbers.
readonly MIN_AZ_VERSION="2.85.0"          # aks-managed-gpu-nodes.md "Before you begin"
readonly MIN_AKS_PREVIEW="19.0.0b29"      # same; extension HISTORY.rst logs b28 for the
                                          # base flag and b29 for the MIG flags
readonly FEATURE_NAME="ManagedGPUExperiencePreview"
readonly FEATURE_NS="Microsoft.ContainerService"

# ---- Output helpers ----------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi

ok()   { printf '%s  PASS%s  %s\n' "$C_OK" "$C_OFF" "$1"; }
warn() { printf '%s  WARN%s  %s\n' "$C_WARN" "$C_OFF" "$1"; }
fail() { printf '%s  FAIL%s  %s\n' "$C_ERR" "$C_OFF" "$1"; }
info() { printf '%s        %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
step() { printf '\n=== %s ===\n' "$1"; }

# azure-cli upgrades differently depending on how it was installed. `az upgrade`
# refuses to run on Homebrew and most distro-package installs, so tell the reader
# the command that actually works for them.
az_upgrade_hint() {
  az_path=$(command -v az 2>/dev/null || echo "")
  case "$az_path" in
    /opt/homebrew/*|/usr/local/Cellar/*|/home/linuxbrew/*) echo "brew upgrade azure-cli" ;;
    *)
      if [ -f /etc/debian_version ]; then echo "sudo apt-get update && sudo apt-get install --only-upgrade azure-cli"
      elif [ -f /etc/redhat-release ]; then echo "sudo dnf update azure-cli"
      else echo "az upgrade"
      fi ;;
  esac
}

# Compare dotted versions including PEP440-style b suffixes (19.0.0b29).
# Returns 0 (true) if $1 >= $2. Requires version-aware sort (GNU coreutils or
# macOS 13+); falls back to a string compare with a warning if unavailable.
version_ge() {
  [ "$1" = "$2" ] && return 0
  if printf '1.0\n1.1\n' | sort -V >/dev/null 2>&1; then
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
  else
    warn "sort -V unavailable; version comparison is approximate"
    [ "$1" \> "$2" ] || [ "$1" = "$2" ]
  fi
}
