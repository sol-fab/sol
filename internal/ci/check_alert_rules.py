#!/usr/bin/env python3
"""Fail when the platform's starter alerts lose their routing contract.

Production requires alert delivery to an owner. The platform must render a
non-empty set of alert rules with severity, a summary/description and the
owner/runbook annotations it merges from the target, and the Alertmanager model
must route to the configured receiver and send resolved notifications.
"""

import argparse
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
MODULE = "platform/cloud/modules/platform/main.tf"


def fail(message):
    print(f"check_alert_rules: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", help="repository root (default: this checkout)")
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    module = (root / MODULE).read_text(encoding="utf-8")

    start = module.find("prometheus_alerting_rules = {")
    end = module.find("prometheus_alertmanager_config", start)
    if start < 0 or end < 0:
        fail("the starter alert rule set is missing")
    rules = module[start:end]
    alerts = re.findall(r'alert\s*=\s*"([^"]+)"', rules)
    if len(alerts) < 6:
        fail(f"only {len(alerts)} starter alerts are declared; the production set must cover service, pod, node and dependency failure")
    for name in alerts:
        if not name.startswith("Sol"):
            fail(f"alert {name!r} does not follow the Sol alert-name prefix")
    for field in ("severity", "summary", "description"):
        count = len(re.findall(rf"\b{field}\s*=", rules))
        if count != len(alerts):
            fail(f"{count} {field} fields for {len(alerts)} alerts")
    annotations = rules.count("local.alert_annotations")
    if annotations != len(alerts):
        fail(f"{annotations} owner/runbook annotation merges for {len(alerts)} alerts")

    alertmanager = module[end:]
    if "var.alert_receiver_url" not in alertmanager:
        fail("Alertmanager does not route to the target's receiver URL")
    if "send_resolved = true" not in alertmanager:
        fail("Alertmanager does not send resolved notifications")
    if 'receiver        = "sol-receiver"' not in alertmanager:
        fail("Alertmanager has no sol-receiver route")

    print(
        f"check_alert_rules: {len(alerts)} starter alerts carry severity, "
        "summary/description, owner/runbook annotations and a resolved webhook route"
    )


main()
