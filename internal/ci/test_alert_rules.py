#!/usr/bin/env python3
"""Mutate the alert contract and verify the guard refuses it."""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "internal/ci/check_alert_rules.py"
MODULE = ROOT / "platform/cloud/modules/platform/main.tf"


def run(root):
    return subprocess.run(
        [sys.executable, str(CHECK), "--root", str(root)], capture_output=True, text=True
    )


def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        target = root / "platform/cloud/modules/platform"
        target.mkdir(parents=True)
        shutil.copy2(MODULE, target / "main.tf")
        assert run(root).returncode == 0, "the unmodified shape must pass"

        original = (target / "main.tf").read_text()
        (target / "main.tf").write_text(original.replace("severity = \"warning\"", "severity = \"warning\"\n# removed", 1))
        # Removing one severity must break the count.
        mutated = original.replace("severity = \"warning\"\n", "", 1)
        (target / "main.tf").write_text(mutated)
        result = run(root)
        assert result.returncode != 0, "a rule without severity must be refused"
        assert "severity fields" in result.stderr

        (target / "main.tf").write_text(original.replace("send_resolved = true", "send_resolved = false", 1))
        result = run(root)
        assert result.returncode != 0, "missing resolved notifications must be refused"
        assert "resolved" in result.stderr
    print("test_alert_rules: missing severity and resolved delivery are refused")


main()
