#!/usr/bin/env python3
"""Mutate the SSO shape and verify the guard refuses each mutation."""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "internal/ci/check_grafana_sso.py"
MODULE = "platform/cloud/modules/platform"
ROOTS = ["platform/cloud/aws/platform", "platform/cloud/gcp/platform"]


def copy_shape(dest: Path) -> None:
    for rel in [MODULE, *ROOTS]:
        source = ROOT / rel
        target = dest / rel
        target.mkdir(parents=True)
        for name in ("main.tf", "variables.tf"):
            shutil.copy2(source / name, target / name)


def run(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(CHECK), "--root", str(root)],
        capture_output=True,
        text=True,
    )


def main() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        copy_shape(root)
        assert run(root).returncode == 0, "the unmodified shape must pass"

        main_tf = root / MODULE / "main.tf"
        text = main_tf.read_text()
        main_tf.write_text(
            text.replace(
                "anonymous = {\n            enabled = false",
                "anonymous = {\n            enabled = true",
            )
        )
        mutated = run(root)
        assert mutated.returncode != 0, "anonymous=true must be refused"
        assert "anonymous access is not disabled" in mutated.stderr

        main_tf.write_text(text)
        variables = root / MODULE / "variables.tf"
        variables.write_text(
            variables.read_text().replace(
                'description = "Break-glass Grafana admin password. When null, Sol generates one; retrieve it from the chart\'s `grafana` Secret in the monitoring namespace. SSO is the normal login path."\n  type        = string\n  default     = null',
                'description = "Grafana admin password."\n  type        = string\n  default     = "admin"',
            )
        )
        mutated = run(root)
        assert mutated.returncode != 0, "defaulting the admin password to admin must be refused"
        assert "still defaults to admin" in mutated.stderr
    print("test_grafana_sso: mutations are refused")


main()
