#!/usr/bin/env python3
"""Mutate the qualification publisher path and verify the guard bites."""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "internal/ci/check_gcp_qualification_publisher.py"
HARNESS = ROOT / "internal/qualification/gcp/live-qual.sh"


def run(root):
    return subprocess.run(
        [sys.executable, str(CHECK), "--root", str(root)], capture_output=True, text=True
    )


def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        target = root / "internal/qualification/gcp"
        target.mkdir(parents=True)
        shutil.copy2(HARNESS, target / "live-qual.sh")
        assert run(root).returncode == 0, "the unmodified harness must pass"

        original = (target / "live-qual.sh").read_text()
        (target / "live-qual.sh").write_text(
            original.replace(
                'token="$(gcloud auth print-access-token --impersonate-service-account "$PUBLISHER_SERVICE_ACCOUNT" --quiet)"',
                'token="$(gcloud auth print-access-token --quiet)"',
                1,
            )
        )
        result = run(root)
        assert result.returncode != 0, "an ambient publisher token must be refused"
        assert "publisher" in result.stderr

        (target / "live-qual.sh").write_text(
            original.replace(
                'print-access-token --impersonate-service-account "$PUBLISHER_SERVICE_ACCOUNT"',
                'print-access-token',
                1,
            )
        )
        result = run(root)
        assert result.returncode != 0, "a missing impersonation must be refused"
    print("test_gcp_qualification_publisher: ambient publishing is refused")


main()
