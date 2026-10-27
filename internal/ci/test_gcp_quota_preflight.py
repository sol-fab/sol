#!/usr/bin/env python3
"""Pure tests for the GCP SSD quota preflight."""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sys
import tempfile

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
    with tempfile.TemporaryDirectory() as directory:
        tfvars = pathlib.Path(directory) / "qual.tfvars"
        tfvars.write_text("node_count = 6\nnode_disk_gb = 50 # qualification\n", encoding="utf-8")
        check("tfvars node_count is read", quota.tfvars_int(str(tfvars), "node_count") == 6)
        check("tfvars node_disk_gb is read", quota.tfvars_int(str(tfvars), "node_disk_gb") == 50)
        check("an absent tfvars value falls back", quota.tfvars_int(str(tfvars), "sql_disk_gb") is None)
        tfvars.write_text("node_disk_gb = var.disk\n", encoding="utf-8")
        try:
            quota.tfvars_int(str(tfvars), "node_disk_gb")
        except quota.QuotaError:
            check("a non-literal tfvars value is refused", True)
        else:
            check("a non-literal tfvars value is refused", False)

        override = pathlib.Path(directory) / "override.tfvars"
        override.write_text("node_disk_gb = 100\n", encoding="utf-8")
        quota_json = pathlib.Path(directory) / "quota.json"
        quota_json.write_text(json.dumps(document(500, 0)), encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = quota.main([
                "gcp_quota_preflight.py", "--quota-json", str(quota_json),
                "--tfvars", str(override), "--node-disk-gb", "100",
            ])
        check("a tfvars node_disk override is used", "required 480" in out.getvalue() and "surge total 580" in out.getvalue())
        check("initial quota passes with a surge warning", rc == 0 and "WARNING" in err.getvalue())

    ok, _ = quota.assess(document(500, 100), 480)
    check("existing usage reduces the available headroom", not ok)
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
