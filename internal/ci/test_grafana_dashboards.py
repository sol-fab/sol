#!/usr/bin/env python3
"""Mutate the dashboard set and verify the guard refuses each mutation."""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "internal/ci/check_grafana_dashboards.py"
DASHBOARDS = ROOT / "platform/shared/observability/dashboards"
MODULE = ROOT / "platform/cloud/modules/platform/main.tf"


def copy_shape(dest):
    target = dest / "platform/shared/observability/dashboards"
    target.mkdir(parents=True)
    for path in DASHBOARDS.glob("*.json"):
        shutil.copy2(path, target / path.name)
    module = dest / "platform/cloud/modules/platform"
    module.mkdir(parents=True)
    shutil.copy2(MODULE, module / "main.tf")
    return target


def run(root):
    return subprocess.run(
        [sys.executable, str(CHECK), "--root", str(root)],
        capture_output=True,
        text=True,
    )


def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        dashboards = copy_shape(root)
        assert run(root).returncode == 0, "the unmodified shape must pass"

        path = dashboards / "workspace-overview.json"
        original = path.read_text()
        dashboard = json.loads(original)
        dashboard["panels"] = []
        path.write_text(json.dumps(dashboard))
        result = run(root)
        assert result.returncode != 0, "an empty dashboard must be refused"
        assert "has no panels" in result.stderr

        path.write_text(original)
        module = root / "platform/cloud/modules/platform/main.tf"
        module.write_text(module.read_text().replace('"release-timeline.json"', '"removed.json"'))
        result = run(root)
        assert result.returncode != 0, "an unmounted dashboard must be refused"
        assert "does not mount release-timeline.json" in result.stderr
    print("test_grafana_dashboards: empty and unmounted dashboards are refused")


main()
