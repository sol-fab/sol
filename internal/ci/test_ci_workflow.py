#!/usr/bin/env python3
"""Execute the generated CI workflow's shell steps against stubs.

This is deliberately not a string assertion. The workflow is the artifact a user
receives from `sol new workspace`; its install, login, build and deploy steps
must actually run, in the order that satisfies Sol's lifecycle. The test renders
the canonical template, creates a fake release bundle and stub provider/CLI
commands, then executes the same `run:` blocks GitHub Actions would execute.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "platform/shared/templates/workspace/.github/workflows/sol-ci.yml"
NAME = "testapp"
VERSION = "v0.0.0-test"
DIGEST = "sha256:" + "a" * 64
REGISTRY = "registry.example"
TARGET = "prod/aws/us-east-1"


def fail(message: str) -> None:
    print(f"test_ci_workflow: {message}", file=sys.stderr)
    raise SystemExit(1)


def step_script(document: dict, job: str, name: str) -> str:
    for step in document["jobs"][job]["steps"]:
        if step.get("name") == name:
            script = step.get("run")
            if not isinstance(script, str):
                fail(f"{job}/{name} has no run script")
            return script
    fail(f"{job} has no step named {name!r}")
    raise AssertionError


def write_stub(path: Path, body: str) -> None:
    path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
    path.chmod(0o755)


def run(script: str, cwd: Path, env: dict[str, str]) -> None:
    result = subprocess.run(
        ["bash", "-c", script],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        print(result.stdout, file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        fail(f"workflow script failed with exit {result.returncode}")


def line_log(path: Path) -> list[str]:
    return path.read_text().splitlines() if path.exists() else []


def main() -> None:
    rendered = TEMPLATE.read_text().replace("{{name}}", NAME).replace("{{Name}}", NAME.title())
    document = yaml.safe_load(rendered)

    with tempfile.TemporaryDirectory(prefix="sol-ci-workflow-") as temp:
        root = Path(temp)
        stub = root / "stub"
        stub.mkdir()
        log = root / "commands.log"
        log.touch()
        base_env = {
            **os.environ,
            "PATH": f"{stub}:{os.environ['PATH']}",
            "STUB_LOG": str(log),
        }

        # A minimal release archive: the install step must extract it, put its
        # bin on GITHUB_PATH, and run its own `sol assets` check.
        stage = root / "stage"
        bundle = stage / f"sol-{VERSION}"
        (bundle / "bin").mkdir(parents=True)
        (bundle / "share" / "sol" / VERSION).mkdir(parents=True)
        write_stub(
            bundle / "bin" / "sol",
            'printf "sol %s\\n" "$*" >> "$STUB_LOG"',
        )
        archive = root / "release.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(bundle, arcname=bundle.name)

        write_stub(stub / "curl", 'cat "$FAKE_BUNDLE"')
        runner_temp = root / "runner"
        github_path = root / "github_path"
        install_env = {
            **base_env,
            "SOL_VERSION": VERSION,
            "FAKE_BUNDLE": str(archive),
            "RUNNER_TEMP": str(runner_temp),
            "GITHUB_PATH": str(github_path),
        }
        run(step_script(document, "deploy", "Install the Sol release"), root, install_env)
        if not (runner_temp / "sol" / "bin" / "sol").is_file():
            fail("the install step did not extract the release")
        if f"{runner_temp}/sol/bin" not in github_path.read_text():
            fail("the install step did not put the release bin on GITHUB_PATH")
        if not any(line == "sol assets" for line in line_log(log)):
            fail("the install step did not run `sol assets`")

        # Registry login must use the registry host, not the full repository path.
        write_stub(stub / "aws", 'echo "password"')
        write_stub(
            stub / "docker",
            'if [ "$1" = "login" ]; then cat >/dev/null; fi\n'
            'echo "docker $*" >> "$STUB_LOG"',
        )
        aws_login_env = {
            **base_env,
            "SOL_REGISTRY": f"{REGISTRY}/team",
            "AWS_REGION": "us-east-1",
        }
        run(step_script(document, "build-images", "Log in to AWS ECR"), root, aws_login_env)
        if not any(
            "docker login" in line and REGISTRY in line for line in line_log(log)
        ):
            fail("the AWS login step did not log in to the registry host")

        write_stub(stub / "gcloud", 'printf "gcloud %s\\n" "$*" >> "$STUB_LOG"')
        run(
            step_script(document, "build-images", "Log in to GCP Artifact Registry"),
            root,
            {**base_env, "SOL_REGISTRY": f"{REGISTRY}/project/cluster"},
        )
        if not any(
            "gcloud auth configure-docker " + REGISTRY in line for line in line_log(log)
        ):
            fail("the GCP login step did not configure the registry host")

        # Build and push must record the immutable digest under the service name
        # `sol deploy --image-ref` expects, not the hyphenated image path.
        workspace = root / "workspace"
        unit = workspace / "app" / "payments" / "charge_svc"
        unit.mkdir(parents=True)
        (unit / "Dockerfile").write_text("FROM scratch\n")
        docker = stub / "docker"
        write_stub(
            docker,
            'printf "docker %s\\n" "$*" >> "$STUB_LOG"\n'
            'case "$*" in\n'
            '  *inspect*) printf "%s/%s/charge-svc@%s\\n" "$SOL_REGISTRY" "testapp" "'
            + DIGEST
            + '";;\n'
            "esac",
        )
        build_env = {
            **base_env,
            "SOL_REGISTRY": REGISTRY,
            "IMAGE_TAG": "b" * 40,
        }
        run(step_script(document, "build-images", "Build and push images"), workspace, build_env)
        refs = (workspace / "image-refs.txt").read_text().strip()
        if refs != f"charge_svc={REGISTRY}/testapp/charge-svc@{DIGEST}":
            fail(f"image-refs.txt is {refs!r}, not the service-keyed digest")

        # The deploy job applies migrations before the deploy that verifies them,
        # and passes every recorded digest as --image-ref.
        write_stub(
            stub / "sol",
            'printf "sol %s\\n" "$*" >> "$STUB_LOG"',
        )
        deploy_env = {
            **base_env,
            "SOL_TARGET": TARGET,
            "SOL_REGISTRY": REGISTRY,
        }
        before = len(line_log(log))
        run(step_script(document, "deploy", "Apply migrations"), workspace, deploy_env)
        run(step_script(document, "deploy", "Deploy immutable images"), workspace, deploy_env)
        deploy_lines = line_log(log)[before:]
        migrate = next(
            (i for i, line in enumerate(deploy_lines) if line.startswith("sol migrate apply ")),
            None,
        )
        deploy = next(
            (i for i, line in enumerate(deploy_lines) if line.startswith("sol deploy ")),
            None,
        )
        if migrate is None or deploy is None or not migrate < deploy:
            fail(f"migrate/deploy order is wrong: {deploy_lines!r}")
        if f"charge_svc={REGISTRY}/testapp/charge-svc@{DIGEST}" not in deploy_lines[deploy]:
            fail(f"deploy did not pass the recorded digest: {deploy_lines[deploy]!r}")

    print("test_ci_workflow: generated workflow shell steps execute in order")


main()
