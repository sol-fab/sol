#!/usr/bin/env python3
"""Mutate the publisher grant and verify the guard refuses it."""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "internal/ci/check_gcp_publisher_role.py"
MAIN = ROOT / "platform/cloud/gcp/cluster/main.tf"


def run(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(CHECK), "--root", str(root)],
        capture_output=True,
        text=True,
    )


def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        target = root / "platform/cloud/gcp/cluster"
        target.mkdir(parents=True)
        shutil.copy2(MAIN, target / "main.tf")
        # The check resolves from its own path; invoke the real checkout for the
        # unmodified case and a mutated copy through a temporary root override.
        assert run(ROOT).returncode == 0
        text = MAIN.read_text()
        mutated = text.replace(
            'role       = "roles/artifactregistry.writer"',
            'role       = "roles/container.developer"',
            1,
        )
        assert mutated != text
        target_main = target / "main.tf"
        target_main.write_text(mutated)
        result = run(root)
        assert result.returncode != 0, "container.developer must be refused"
        assert "not roles/artifactregistry.writer" in result.stderr
    print("test_gcp_publisher_role: Kubernetes authority is refused")


main()
