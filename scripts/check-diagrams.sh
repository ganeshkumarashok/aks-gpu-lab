#!/usr/bin/env bash
# Validate the Mermaid architecture diagrams.
#
# Two checks:
#   1. Every ```mermaid block parses and renders.
#   2. Facts asserted in the diagrams still match the manifests and scripts, so
#      a topology change cannot land without the diagram being updated too.
#
# Run after changing any manifest, node pool SKU, port, or resource name.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0
note_fail() { fail "$1"; ERRORS=$((ERRORS + 1)); }

step "Extracting Mermaid blocks"
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

python3 - "$ROOT" "$TMPD" <<'PY'
import re, sys, pathlib
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
n = 0
for md in sorted(root.rglob("*.md")):
    if ".git" in md.parts:
        continue
    for i, block in enumerate(re.findall(r"```mermaid\n(.*?)```", md.read_text(), re.S)):
        n += 1
        (out / f"{md.stem}-{i}.mmd").write_text(block)
        print(f"{md.relative_to(root)} block {i}")
print(f"TOTAL {n}")
PY

COUNT=$(find "$TMPD" -name '*.mmd' | wc -l | tr -d ' ')
[ "$COUNT" -gt 0 ] || { note_fail "No Mermaid blocks found"; exit 1; }
ok "$COUNT diagram(s) found"

step "Check 1: diagrams render"
for f in "$TMPD"/*.mmd; do
  name=$(basename "$f" .mmd)
  payload=$(python3 -c "
import base64, json, sys
src = open(sys.argv[1]).read()
print(base64.urlsafe_b64encode(json.dumps({'code': src}).encode()).decode())
" "$f")
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 45 "https://mermaid.ink/svg/$payload" 2>/dev/null || echo 000)
  case "$code" in
    200) ok "$name renders" ;;
    000) warn "$name: could not reach mermaid.ink (offline?), skipping render check" ;;
    *)   note_fail "$name: render failed (HTTP $code) -- the block will show as raw text on GitHub" ;;
  esac
done

step "Check 2: diagrams match the manifests"
# Each entry is: <description>|<string the diagrams claim>|<file that must also contain it>
while IFS='|' read -r desc needle source; do
  [ -z "$desc" ] && continue

  # Matching is case-insensitive: a diagram may write "NFS" where a manifest
  # writes "nfs". `--` terminates option parsing: needles like
  # --enable-managed-gpu=true are
  # otherwise read by grep as flags, and BOTH lookups fail in a way that looks
  # like agreement.
  if ! [ -e "$ROOT/$source" ]; then
    note_fail "$desc: $source does not exist"
    continue
  fi
  in_diagram=$(grep -rqiF -- "$needle" "$TMPD" && echo yes || echo no)
  in_source=$(grep -rqiF -- "$needle" "$ROOT/$source" && echo yes || echo no)

  if [ "$in_diagram" = "no" ] && [ "$in_source" = "no" ]; then
    note_fail "$desc: '$needle' found in neither the diagrams nor $source"
  elif [ "$in_diagram" = "yes" ] && [ "$in_source" = "no" ]; then
    note_fail "$desc: diagrams say '$needle' but $source no longer contains it"
  elif [ "$in_diagram" = "no" ] && [ "$in_source" = "yes" ]; then
    note_fail "$desc: $source contains '$needle' but no diagram shows it"
  else
    ok "$desc: consistent"
  fi
done <<EOF
DCGM exporter port|19400|scripts/30-verify-managed-stack.sh
GPU resource name|nvidia.com/gpu|manifests/vllm-serving.yaml
Managed GPU flag|--enable-managed-gpu=true|scripts/20-add-managed-gpu-nodepool.sh
Capstone SKU|ND96isrf_H100_v5|scripts/lib.sh
Ray Serve endpoint port|8000|manifests/rayservice-glm-h100.yaml
Shared model storage over NFS|nfs|manifests/model-storage.yaml
ReadWriteMany access mode|ReadWriteMany|manifests/model-storage.yaml
Gateway implementation|approuting-istio|manifests/gateway.yaml
EOF

step "Result"
if [ "$ERRORS" -eq 0 ]; then
  ok "Diagrams are valid and consistent with the code"
else
  fail "$ERRORS diagram problem(s)"
fi
exit "$ERRORS"
