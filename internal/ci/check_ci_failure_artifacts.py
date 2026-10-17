"""Guard the failure-artifact boundary of the Dune test job (#1462).

A failing Dune test leaves its detailed output on the runner in
``_build/_tests`` (and, when Dune writes one, ``_build/log``).  The runner is
destroyed with the job, so the workflow must upload exactly that evidence on
failure.  This check pins the guarantees the workflow has to keep:

  * an upload step exists, runs only on failure, and follows every Dune test
    step in the ``test`` job;
  * it retains a bounded number of days;
  * its path list is exactly the Dune output locations, so it cannot silently
    grow to publish kubeconfigs, environment files or the whole workspace.

The actual upload and retrieval still require a GitHub Actions run; this is
only the offline structural half.
"""

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is not installed: pip install -r internal/ci/requirements.txt")

NAME = "check_ci_failure_artifacts"
UPLOAD_NAME = "Upload Dune test failure output"
EXPECTED_PATHS = {"_build/_tests/**", "_build/log"}
MAX_RETENTION_DAYS = 30
DUNE_TEST_STEP = re.compile(r"\bdune build @ci-(?:unit|lifecycle|integration-kafka|integration-pg|e2e)\b")


def fail(message):
    sys.exit(f"{NAME}: {message}")


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[2])
    workflow = root / ".github" / "workflows" / "ci.yml"
    job = (yaml.safe_load(workflow.read_text(encoding="utf-8")) or {}).get("jobs", {}).get("test")
    if not isinstance(job, dict):
        fail(f"{workflow} has no `test` job")

    steps = [step for step in job.get("steps", []) if isinstance(step, dict)]
    uploads = [index for index, step in enumerate(steps) if step.get("name") == UPLOAD_NAME]
    if len(uploads) != 1:
        fail(f"the `test` job must have exactly one '{UPLOAD_NAME}' step, found {len(uploads)}")
    index = uploads[0]
    step = steps[index]

    condition = str(step.get("if", ""))
    if not condition.startswith("failure()"):
        fail(f"'{UPLOAD_NAME}' must be conditional on failure(), not {condition!r}")
    if step.get("uses") != "actions/upload-artifact@v4":
        fail(f"'{UPLOAD_NAME}' must use actions/upload-artifact@v4, not {step.get('uses')!r}")

    with_ = step.get("with") or {}
    paths = {line.strip() for line in str(with_.get("path", "")).splitlines() if line.strip()}
    if paths != EXPECTED_PATHS:
        fail(
            f"'{UPLOAD_NAME}' path list is {sorted(paths)}, not {sorted(EXPECTED_PATHS)}; "
            "keep the artifact to Dune's failure output so no credential or workspace material is published"
        )
    if str(with_.get("if-no-files-found")) != "ignore":
        fail(f"'{UPLOAD_NAME}' must set if-no-files-found: ignore so a pre-test failure is not a second error")

    retention = with_.get("retention-days")
    if not isinstance(retention, int) or not 1 <= retention <= MAX_RETENTION_DAYS:
        fail(f"'{UPLOAD_NAME}' retention-days is {retention!r}, not 1..{MAX_RETENTION_DAYS}")

    dune_steps = [i for i, candidate in enumerate(steps) if DUNE_TEST_STEP.search(str(candidate.get("run", "")))]
    if not dune_steps:
        fail("the `test` job runs no Dune test class")
    if index < max(dune_steps):
        fail(
            f"'{UPLOAD_NAME}' must follow every Dune test step; "
            f"a later test step (index {max(dune_steps)}) would not be covered"
        )

    print(f"{NAME}: failure artifact '{UPLOAD_NAME}' follows the Dune test steps and uploads only {sorted(paths)} for {retention} day(s)")


main()
