#!/usr/bin/env python3
"""Pure tests for the GCP SSD quota preflight."""

from __future__ import annotations

import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "qualification"))
import gcp_quota_preflight as quota  # noqa: E402

checks = 0
failures = 0


def check(label: str, condition: bool) -> None:
    global checks, failures
    checks += 1
    print(f"  [{'OK' if condition else 'FAIL'}]   {label}")
    failures += 0 if condition else 1


def document(limit: float, usage: float) -> dict:
    return {"quotas": [{"metric": "SSD_TOTAL_GB", "limit": limit, "usage": usage}]}


def main() -> int:
    ok, line = quota.assess(document(500, 60), 440)
    check("exactly the required headroom passes", ok)
    check("report carries limit/usage/required", "available 440" in line and "required 440" in line)
    ok, _ = quota.assess(document(500, 61), 440)
    check("one GB short fails", not ok)
    ok, _ = quota.assess(document(500, 0), 500)
    check("exactly the limit passes", ok)
    try:
        quota.ssd_quota({"quotas": [{"metric": "CPUS", "limit": 1, "usage": 0}]})
    except quota.QuotaError:
        check("a missing SSD quota is an error", True)
    else:
        check("a missing SSD quota is an error", False)
    try:
        quota.ssd_quota({"quotas": [{"metric": "SSD_TOTAL_GB", "limit": "x", "usage": 0}]})
    except quota.QuotaError:
        check("a malformed SSD quota is an error", True)
    else:
        check("a malformed SSD quota is an error", False)
    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
