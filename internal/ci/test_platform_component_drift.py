import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_platform_component_drift.py"
FILES = [
    "cli/bin/cmd_local.ml",
    "cli/lib/local/sol_cli_local_platform.ml",
    "cli/lib/local/sol_cli_dev_observability.ml",
    "cli/lib/workspace/sol_cli_manifest_yaml.ml",
    "cli/lib/deploy/sol_cli_deployment_render.ml",
    "framework/ocaml/sol-obs/lib/sol_obs.ml",
    "platform/cloud/modules/platform/main.tf",
    "platform/shared/components.json",
    "examples/pluto/app/demo_ts/order_svc/src/tracing.ts",
    "examples/pluto/app/demo_ts/order_svc/src/index.ts",
    "examples/pluto/app/demo_ts/order_svc/package.json",
    "examples/pluto/app/demo_ts/fulfillment_worker/src/tracing.ts",
    "examples/pluto/app/demo_ts/fulfillment_worker/src/index.ts",
    "examples/pluto/app/demo_ts/fulfillment_worker/package.json",
    "examples/pluto/app/demo_ts/package-lock.json",
    "platform/shared/templates/svc-ts/package.json",
    "platform/shared/templates/worker-ts/package.json",
]


def append(path, text):
    def mutate(root):
        with open(root / path, "a", encoding="utf-8") as f:
            f.write(text)
    return mutate


def break_layers(root):
    path = root / "platform/shared/components.json"
    data = json.loads(path.read_text())
    first = sorted(data)[0]
    data[first]["prod"] = data[first].pop("durable")
    path.write_text(json.dumps(data))


def drop_env_from_tf(root):
    path = root / "platform/cloud/modules/platform/main.tf"
    text = path.read_text()
    path.write_text(text.replace('"workspace", "env", "domain"', '"workspace", "domain"', 1))


def drop_env_from_ocaml(root):
    path = root / "cli/lib/local/sol_cli_dev_observability.ml"
    text = path.read_text()
    path.write_text(text.replace('"workspace"; "env"; "domain"', '"workspace"; "domain"', 1))


def drift_the_ocaml_mirror(root):
    path = root / "cli/lib/local/sol_cli_dev_observability.ml"
    text = path.read_text()
    path.write_text(text.replace('"primitive"; "release" ]', '"primitive"; "release"; "region" ]', 1))


def drop_identity_label_from_manifest(root):
    path = root / "cli/lib/workspace/sol_cli_manifest_yaml.ml"
    text = path.read_text()
    path.write_text(text.replace('  ; "env", "SOL_ENV"\n', "", 1))


def drop_framework_identity_label(root):
    path = root / "framework/ocaml/sol-obs/lib/sol_obs.ml"
    text = path.read_text()
    path.write_text(text.replace('  ; "SOL_ENV", "env"\n', "", 1))


def rename_identity_env_var(root):
    path = root / "cli/lib/workspace/sol_cli_manifest_yaml.ml"
    text = path.read_text()
    path.write_text(text.replace('"service", "SOL_SERVICE"', '"service", "SOL_WORKLOAD"', 1))


def hardcode_ts_trace_service(root):
    path = root / "examples/pluto/app/demo_ts/order_svc/src/tracing.ts"
    text = path.read_text()
    path.write_text(
        text.replace(
            "resourceFromAttributes(resourceAttributes(serviceName))",
            'resourceFromAttributes({ "service.name": serviceName })',
            1,
        )
    )


def downgrade_ts_obs_pin(root):
    path = root / "examples/pluto/app/demo_ts/order_svc/package.json"
    text = path.read_text()
    path.write_text(text.replace('"@sol-fab/obs": "^0.4.0"', '"@sol-fab/obs": "^0.3.0"', 1))


def drop_ts_loki_pusher(root):
    path = root / "examples/pluto/app/demo_ts/order_svc/src/index.ts"
    text = path.read_text()
    path.write_text(text.replace("makeLokiPusher(", "consoleJson(", 1))


def downgrade_ts_template_obs_pin(root):
    path = root / "platform/shared/templates/svc-ts/package.json"
    text = path.read_text()
    path.write_text(text.replace('"@sol-fab/obs": "^0.4.0"', '"@sol-fab/obs": "^0.3.0"', 1))


def duplicate_obs_in_demo_lockfile(root):
    path = root / "examples/pluto/app/demo_ts/package-lock.json"
    lock = json.loads(path.read_text())
    lock["packages"]["node_modules/@sol-fab/kafka/node_modules/@sol-fab/obs"] = {"version": "0.1.2"}
    path.write_text(json.dumps(lock, indent=2) + "\n")


CASES = [
    ("a migrated key back in the local platform", "fail",
     append("cli/lib/local/sol_cli_local_platform.ml", '\nlet _ = "deploymentMode"\n')),
    ("a migrated key back in cmd_local", "fail", append("cli/bin/cmd_local.ml", '\nlet _ = "gateway.enabled"\n')),
    ("a migrated key back in main.tf", "fail",
     append("platform/cloud/modules/platform/main.tf", '\nlocals {\n  drift = "loki.auth_enabled"\n}\n')),
    ("a local-only key back in the local platform", "fail",
     append("cli/lib/local/sol_cli_local_platform.ml", '\nlet _ = "statefulset.replicas"\n')),
    ("a local-only key in main.tf is allowed", "pass",
     append("platform/cloud/modules/platform/main.tf", '\nlocals {\n  allowed = "statefulset.replicas"\n}\n')),
    ("a component keyed by environment", "fail", break_layers),
    ("env dropped from the cloud log taxonomy", "fail", drop_env_from_tf),
    ("env dropped from the local log taxonomy mirror", "fail", drop_env_from_ocaml),
    ("the local log taxonomy mirror drifts from the cloud", "fail", drift_the_ocaml_mirror),
    ("env dropped from the rendered identity", "fail", drop_identity_label_from_manifest),
    ("env dropped from the framework's emitted identity", "fail", drop_framework_identity_label),
    ("a rendered identity variable is renamed", "fail", rename_identity_env_var),
    ("the TypeScript trace hardcodes its service name", "fail", hardcode_ts_trace_service),
    ("the TypeScript obs pin predates identity support", "fail", downgrade_ts_obs_pin),
    ("the TypeScript service stops pushing through makeLokiPusher", "fail", drop_ts_loki_pusher),
    ("a TypeScript template falls below the identity floor", "fail", downgrade_ts_template_obs_pin),
    ("the demo lockfile resolves two @sol-fab/obs versions", "fail", duplicate_obs_in_demo_lockfile),
    ("the real tree", "pass", lambda root: None),
]


def main():
    with tempfile.TemporaryDirectory() as scratch:
        for name, want, mutate in CASES:
            root = Path(scratch) / name.replace(" ", "-")
            for rel in FILES:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(REPO / rel, root / rel)
            mutate(root)
            run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
            got = "pass" if run.returncode == 0 else "fail"
            if got != want:
                sys.exit(f"  [FAIL] {name}: expected {want}, got {got}\n{run.stdout}{run.stderr}")
            print(f"  [OK]   {name}")


main()
