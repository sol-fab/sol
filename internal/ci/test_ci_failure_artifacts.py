"""Pin the failure-artifact boundary guard's contract (#1462).

The guard protects the upload step that keeps a failing Dune test's runner-side
output retrievable.  These cases establish that removing the step, weakening its
condition, broadening its paths or moving it before the last Dune test step is
rejected -- and that the repository's shipped workflow is accepted.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is not installed: pip install -r internal/ci/requirements.txt")

ROOT = Path(__file__).resolve().parents[2]
GUARD = Path(__file__).resolve().parent / "check_ci_failure_artifacts.py"
FAILURES = []


def ok(message):
    sys.stdout.write(f"  [OK]   {message}\n")


def bad(message):
    sys.stdout.write(f"  [FAIL] {message}\n")
    FAILURES.append(message)


def workflow(*, upload=True, condition="failure()", paths=None, retention=7, upload_index=2):
    steps = [
        {"name": "Unit tests", "run": "opam exec -- dune build @ci-unit"},
        {"name": "Facts-to-jobs golden-path smoke", "run": "opam exec -- dune build @ci-e2e"},
    ]
    if upload:
        with_ = {
            "path": "\n".join(paths or ["_build/_tests/**", "_build/log"]),
            "if-no-files-found": "ignore",
        }
        if retention is not None:
            with_["retention-days"] = retention
        steps.insert(
            upload_index,
            {
                "name": "Upload Dune test failure output",
                "if": condition,
                "uses": "actions/upload-artifact@v4",
                "with": with_,
            },
        )
    return {"on": "pull_request", "jobs": {"test": {"steps": steps}}}


def write(root, document):
    path = root / ".github" / "workflows" / "ci.yml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(document), encoding="utf-8")


def run(root):
    result = subprocess.run(
        [sys.executable, str(GUARD), str(root)],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode, result.stdout + result.stderr


def expect(name, document, returncode, needle):
    with tempfile.TemporaryDirectory() as tmp:
        write(Path(tmp), document)
        code, output = run(tmp)
    if code != returncode:
        bad(f"{name}: expected exit {returncode}, got {code}\n{output}")
    elif needle and needle not in output:
        bad(f"{name}: output does not name {needle!r}\n{output}")
    else:
        ok(name)


code, output = run(ROOT)
if code != 0:
    bad(f"the repository's shipped workflow is rejected\n{output}")
else:
    ok("the repository's shipped workflow")

expect("the upload step is accepted", workflow(), 0, "follows the Dune test steps")
expect("a missing upload step is rejected", workflow(upload=False), 1, "exactly one")
expect("a non-failure condition is rejected", workflow(condition="always()"), 1, "failure()")
expect("a broadened path is rejected", workflow(paths=["_build/**"]), 1, "path list")
expect("an extra sensitive path is rejected", workflow(paths=["_build/_tests/**", ".env"]), 1, "path list")
expect("an unbounded retention is rejected", workflow(retention=None), 1, "retention-days")
expect("the upload before the last Dune test step is rejected", workflow(upload_index=1), 1, "must follow")

if FAILURES:
    sys.exit(1)
