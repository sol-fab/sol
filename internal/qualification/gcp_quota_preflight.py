#!/usr/bin/env python3
"""Check GCP SSD quota headroom before provisioning a production target."""

from __future__ import annotations

import argparse
import json
import sys


class QuotaError(Exception):
    pass


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
    parser.add_argument("--node-count", type=int, default=4)
    parser.add_argument("--node-disk-gb", type=int, default=100)
    parser.add_argument("--broker-gb", type=int, default=60)
    parser.add_argument("--platform-gb", type=int, default=20)
    parser.add_argument("--out")
    args = parser.parse_args(argv[1:])
    required = args.node_count * args.node_disk_gb + args.broker_gb + args.platform_gb
    try:
        with open(args.quota_json, encoding="utf-8") as handle:
            document = json.load(handle)
        ok, line = assess(document, required)
    except (OSError, json.JSONDecodeError, QuotaError) as error:
        print(f"gcp-quota-preflight: {error}", file=sys.stderr)
        return 1
    report = (
        f"{line}\n"
        f"required = {args.node_count} nodes x {args.node_disk_gb}GB + {args.broker_gb}GB brokers + "
        f"{args.platform_gb}GB platform PVCs\n"
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
