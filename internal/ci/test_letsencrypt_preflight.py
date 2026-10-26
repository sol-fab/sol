#!/usr/bin/env python3
"""Pure tests for the CT-based Let's Encrypt headroom check."""

from __future__ import annotations

import datetime as dt
import os
import pathlib
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "internal" / "qualification"))
import letsencrypt_preflight as preflight  # noqa: E402

checks = 0
failures = 0
NOW = dt.datetime(2026, 10, 26, 12, 0, tzinfo=dt.timezone.utc)


def check(label: str, condition: bool) -> None:
    global checks, failures
    checks += 1
    print(f"  [{'OK' if condition else 'FAIL'}]   {label}")
    failures += 0 if condition else 1


def record(serial: str, host: str, when: dt.datetime, issuer: str = "C=US, O=Let's Encrypt, CN=YR1") -> dict:
    return {
        "issuer_name": issuer,
        "name_value": host,
        "not_before": when.strftime("%Y-%m-%dT%H:%M:%S"),
        "serial_number": serial,
    }


def main() -> int:
    host = "argocd.qual.example.dev"
    check("exact host is counted", len(preflight.issued_for(host, [
        record("a", host, NOW - dt.timedelta(days=1)),
    ], NOW)) == 1)
    check("a wildcard name does not count as the exact host", len(preflight.issued_for(host, [
        record("b", f"*.qual.example.dev", NOW - dt.timedelta(days=1)),
    ], NOW)) == 0)
    check("a non-Let's Encrypt issuer is ignored", len(preflight.issued_for(host, [
        record("c", host, NOW - dt.timedelta(days=1), issuer="C=US, O=Other CA"),
    ], NOW)) == 0)
    check("a certificate older than 168h is ignored", len(preflight.issued_for(host, [
        record("d", host, NOW - dt.timedelta(days=8)),
    ], NOW)) == 0)
    check("duplicate CT serials are counted once", len(preflight.issued_for(host, [
        record("e", host, NOW - dt.timedelta(days=1)),
        record("e", host, NOW - dt.timedelta(days=1)),
    ], NOW)) == 1)

    five = [record(str(i), host, NOW - dt.timedelta(days=1)) for i in range(5)]
    four = five[:4]
    orig_fetch = preflight.fetch

    def fake(records):
        return lambda _host, _base: records

    preflight.fetch = fake(five)
    ok, lines = preflight.check("qual.example.dev", "letsencrypt-prod", "https://crt.sh", False)
    check("five certificates fail the check", not ok and any("FAIL" in line for line in lines))
    preflight.fetch = fake(four)
    ok, lines = preflight.check("qual.example.dev", "letsencrypt-prod", "https://crt.sh", False)
    check("four certificates pass with a warning", ok and any("WARN" in line for line in lines))
    preflight.fetch = lambda _host, _base: (_ for _ in ()).throw(preflight.PreflightError("ct unavailable"))
    ok, lines = preflight.check("qual.example.dev", "letsencrypt-prod", "https://crt.sh", False)
    check("unreadable CT fails closed", not ok)
    ok, lines = preflight.check("qual.example.dev", "letsencrypt-prod", "https://crt.sh", True)
    check("--allow-unknown permits unreadable CT", ok)
    ok, lines = preflight.check("qual.example.dev", "letsencrypt-staging", "https://crt.sh", False)
    check("staging issuer skips the production quota", ok)
    preflight.fetch = orig_fetch

    with tempfile.TemporaryDirectory() as directory:
        ledger = os.path.join(directory, "issuance.json")
        preflight.fetch = fake([record("ct", host, NOW - dt.timedelta(days=1))])
        for attempt in range(4):
            ok, _ = preflight.check("qual.example.dev", "letsencrypt-prod", "https://crt.sh", False, ledger, True)
            check(f"local reservation {attempt + 1} passes", ok)
        ok, lines = preflight.check("qual.example.dev", "letsencrypt-prod", "https://crt.sh", False, ledger, True)
        check("local ledger caps a fifth reservation", not ok and any("5" in line for line in lines))
        preflight.fetch = orig_fetch

    print(f"\n{checks - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
