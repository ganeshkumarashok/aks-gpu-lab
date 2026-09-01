#!/usr/bin/env python3
"""Decide whether each requested GPU SKU is actually usable in a region.

A SKU is usable only if it clears BOTH gates:
  1. availability -- an empty `restrictions` array in the Compute SKUs API
  2. quota        -- non-zero limit for its family in the usage API

Checking one alone is misleading: westus3 reports T4 quota of 0/300 while the
T4 SKU itself is NotAvailableForSubscription there.

Usage:
  _check_skus.py <skus.json> <usage.json> <sku> <role> [<sku> <role> ...]

Prints one `VERDICT|message` line per SKU, where VERDICT is OK, WARN, or FAIL.
"""
import json
import sys


def norm(name: str) -> str:
    """Quota family names are inconsistently spaced/underscored across regions."""
    return name.replace(" ", "").replace("_", "").lower()


def main() -> int:
    if len(sys.argv) < 5 or len(sys.argv) % 2 != 1:
        print("usage: _check_skus.py <skus.json> <usage.json> <sku> <role> ...", file=sys.stderr)
        return 2

    with open(sys.argv[1]) as fh:
        skus = {
            s["name"]: s
            for s in json.load(fh).get("value", [])
            if s.get("resourceType") == "virtualMachines"
        }
    with open(sys.argv[2]) as fh:
        quota = {
            norm(u["name"]["value"]): (int(u["currentValue"]), int(u["limit"]))
            for u in json.load(fh)
        }

    pairs = sys.argv[3:]
    for sku, role in zip(pairs[::2], pairs[1::2]):
        s = skus.get(sku)
        if not s:
            print(f"FAIL|{sku} ({role}): not offered in this region")
            continue

        restrictions = s.get("restrictions") or []
        if restrictions:
            codes = ",".join(r.get("reasonCode", "?") for r in restrictions)
            print(f"FAIL|{sku} ({role}): restricted -- {codes}")
            continue

        family = s.get("family", "")
        vcpu = int(
            next((c["value"] for c in s.get("capabilities", []) if c["name"] == "vCPUs"), 0) or 0
        )
        entry = quota.get(norm(family))
        if entry is None:
            print(f"WARN|{sku} ({role}): unrestricted, but quota family '{family}' not in usage list")
        elif entry[1] == 0:
            print(f"FAIL|{sku} ({role}): unrestricted but quota is 0. Request an increase for '{family}'.")
        else:
            current, limit = entry
            nodes = (limit - current) // vcpu if vcpu else 0
            print(f"OK|{sku} ({role}): {current}/{limit} vCPU in '{family}' -> room for {nodes} node(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
