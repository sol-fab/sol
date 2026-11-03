#!/usr/bin/env python3
"""The AWS secrets-store CSI add-on must be a pinned provider build.

A live qualification records the provider component it ran. `most_recent` lets the EKS
service move that component after the evidence is written, so the cluster root must name
an explicit add-on version compatible with the pinned Kubernetes version.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLUSTER = ROOT / "platform/cloud/aws/cluster/main.tf"
BLOCK = re.compile(
    r"aws-secrets-store-csi-driver-provider\s*=\s*\{(?P<body>.*?)\n\s*\}",
    re.DOTALL,
)
VERSION = re.compile(r'addon_version\s*=\s*"v(?P<version>[0-9]+\.[0-9]+\.[0-9]+-eksbuild\.[0-9]+)"')


def main() -> int:
    try:
        text = CLUSTER.read_text(encoding="utf-8")
    except OSError as error:
        print(f"test_ascp_pin: cannot read {CLUSTER}: {error}", file=sys.stderr)
        return 1
    match = BLOCK.search(text)
    if not match:
        print("test_ascp_pin: no aws-secrets-store-csi-driver-provider block", file=sys.stderr)
        return 1
    body = match.group("body")
    if "most_recent" in body:
        print("test_ascp_pin: the add-on uses most_recent instead of addon_version", file=sys.stderr)
        return 1
    version = VERSION.search(body)
    if not version:
        print("test_ascp_pin: the add-on has no valid vX.Y.Z-eksbuild.N addon_version", file=sys.stderr)
        return 1
    print(f"test_ascp_pin: pinned aws-secrets-store-csi-driver-provider v{version.group('version')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
