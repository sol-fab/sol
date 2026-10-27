#!/usr/bin/env python3
"""Check GCP SSD quota headroom before provisioning a production target."""

from __future__ import annotations

import argparse
import json
import re
import sys
import pathlib


class QuotaError(Exception):
    pass


def tfvars_int(path: str, name: str) -> int | None:
    """Read a simple integer assignment from a Terraform variable file.

    Terraform variables may be expressions; this check refuses rather than
    silently substituting a different value the deployment will not use.
    """
    try:
        lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise QuotaError(f"cannot read tfvars {path}: {error}") from error
    pattern = re.compile(rf"^\s*{re.escape(name)}\s*=\s*(\d+)\s*(?:#.*)?$")
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not re.match(rf"^\s*{re.escape(name)}\s*=", line):
            continue
        match = pattern.match(line)
        if not match:
            raise QuotaError(
                f"{path}: {name} is not a literal integer; cannot verify the storage footprint"
            )
        return int(match.group(1))
    return None


def ssd_quota(document: object) -> tuple[float, float]:
    if not isinstance(document, dict):
        raise QuotaError("gcloud quota output is not an object")
    quotas = document.get("quotas")
    if not isinstance(quotas, list):
        raise QuotaError("gcloud quota output has no quotas list")
    for quota in quotas:
        if not isinstance(quota, dict) or quota.get("metric") != "SSD_TOTAL_GB":
            continue
        try:
            limit = float(quota["limit"])
            usage = float(quota["usage"])
        except (KeyError, TypeError, ValueError) as error:
            raise QuotaError(f"SSD_TOTAL_GB has no numeric limit/usage: {error}") from error
        return limit, usage
    raise QuotaError("the region reports no SSD_TOTAL_GB quota")


def assess(document: object, required: float) -> tuple[bool, str]:
    limit, usage = ssd_quota(document)
    available = limit - usage
    line = f"SSD_TOTAL_GB: limit {limit:g}, used {usage:g}, available {available:g}, required {required:g}"
    return available >= required, line


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quota-json", required=True)
    parser.add_argument("--tfvars")
    parser.add_argument("--node-count", type=int, default=4)
    parser.add_argument("--node-disk-gb", type=int, default=100)
    parser.add_argument("--surge-nodes", type=int, default=1)
    parser.add_argument("--broker-gb", type=int, default=60)
    parser.add_argument("--platform-gb", type=int, default=20)
    parser.add_argument("--out")
    args = parser.parse_args(argv[1:])
    node_count = args.node_count
    node_disk = args.node_disk_gb
    try:
        if args.tfvars:
            override_count = tfvars_int(args.tfvars, "node_count")
            override_disk = tfvars_int(args.tfvars, "node_disk_gb")
            if override_count is not None:
                node_count = override_count
            if override_disk is not None:
                node_disk = override_disk
    except QuotaError as error:
        print(f"gcp-quota-preflight: {error}", file=sys.stderr)
        return 1
    required = node_count * node_disk + args.broker_gb + args.platform_gb
    try:
        with open(args.quota_json, encoding="utf-8") as handle:
            document = json.load(handle)
        ok, line = assess(document, required)
        limit, usage = ssd_quota(document)
        surge_required = required + args.surge_nodes * node_disk
        surge_ok = limit - usage >= surge_required
    except (OSError, json.JSONDecodeError, QuotaError) as error:
        print(f"gcp-quota-preflight: {error}", file=sys.stderr)
        return 1
    report = (
        f"{line}\n"
        f"required = {node_count} nodes x {node_disk}GB + {args.broker_gb}GB brokers + "
        f"{args.platform_gb}GB platform PVCs\n"
        f"upgrade surge = {args.surge_nodes} x {node_disk}GB node disk; "
        f"surge total {surge_required:g}GB ("
        + ("fits" if surge_ok else "does not fit")
        + ")\n"
    )
    print(report, end="")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(report)
    if not ok:
        print(
            "gcp-quota-preflight: insufficient regional SSD quota; increase SSD_TOTAL_GB "
            "or lower TF_VAR_node_disk_gb before provisioning.",
            file=sys.stderr,
        )
        return 2
    if not surge_ok:
        print(
            "WARNING: the initial footprint fits, but a one-node upgrade surge does not; "
            "raise SSD_TOTAL_GB before upgrading the node pool.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
