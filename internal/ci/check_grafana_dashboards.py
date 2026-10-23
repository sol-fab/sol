#!/usr/bin/env python3
"""Fail when a shipped Grafana dashboard is empty or not provisioned.

This is not a substitute for the live Grafana verification: it checks that every
dashboard the platform ships is valid JSON with a title, a uid and at least one
panel, and that the Grafana sidecar ConfigMap still mounts every one of them.
"""

import argparse
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
EXPECTED = {
    "workspace-overview.json",
    "service-template.json",
    "domain-overview.json",
    "release-timeline.json",
    "target-infrastructure.json",
}


def fail(message):
    print(f"check_grafana_dashboards: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", help="repository root (default: this checkout)")
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    dashboards_dir = root / "platform/shared/observability/dashboards"
    module_path = root / "platform/cloud/modules/platform/main.tf"
    if not dashboards_dir.is_dir():
        fail(f"{dashboards_dir} is missing")
    seen = set()
    for path in sorted(dashboards_dir.glob("*.json")):
        seen.add(path.name)
        try:
            dashboard = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            fail(f"{path.name} is not valid JSON: {error}")
        if not isinstance(dashboard, dict):
            fail(f"{path.name} is not a JSON object")
        for field in ("title", "uid"):
            value = dashboard.get(field)
            if not isinstance(value, str) or not value.strip():
                fail(f"{path.name} has no non-empty {field}")
        panels = dashboard.get("panels")
        if not isinstance(panels, list) or not panels:
            fail(f"{path.name} has no panels")
        if not any(isinstance(panel, dict) and panel.get("datasource") for panel in panels):
            fail(f"{path.name} has no panel bound to a datasource")

    missing = EXPECTED - seen
    extra = seen - EXPECTED
    if missing:
        fail(f"the shipped set is missing {', '.join(sorted(missing))}")
    if extra:
        fail(f"the shipped set gained {', '.join(sorted(extra))} without adding it to the ConfigMap contract")

    module = module_path.read_text(encoding="utf-8")
    start = module.find('resource "kubernetes_config_map" "grafana_dashboards"')
    if start < 0:
        fail("the Grafana dashboards ConfigMap is missing")
    end = module.find("\n}", start)
    config_map = module[start:end] if end >= 0 else module[start:]
    mounted = set(re.findall(r'^\s*"([^"]+)"\s*=', config_map, re.M))
    for name in sorted(EXPECTED):
        if name not in mounted:
            fail(f"the Grafana sidecar ConfigMap does not mount {name}")
    unexpected = mounted - EXPECTED
    if unexpected:
        fail(f"the Grafana sidecar ConfigMap mounts {', '.join(sorted(unexpected))} without a shipped dashboard")
    if 'grafana_dashboard = "1"' not in config_map:
        fail("the dashboards ConfigMap is not labelled for the Grafana sidecar")

    print(
        "check_grafana_dashboards: five valid, non-empty dashboards, all mounted "
        "by the sidecar-labelled ConfigMap; live visibility still requires Grafana"
    )


main()
