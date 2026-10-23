import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

MIGRATED = [
    "deploymentMode",
    "singleBinary.replicas",
    "write.replicas",
    "read.replicas",
    "backend.replicas",
    "gateway.enabled",
    "loki.auth_enabled",
    "loki.commonConfig.replication_factor",
    "loki.storage.type",
    "loki.useTestSchema",
    "sidecar.dashboards.enabled",
    "sidecar.datasources.enabled",
    "pushgateway.enabled",
    "alertmanager.enabled",
    "tls.enabled",
    "config.cluster.auto_create_topics_enabled",
    "auth.database",
]
LOCAL_ONLY = [
    "singleBinary.persistence.enabled",
    "server.persistentVolume.enabled",
    "statefulset.replicas",
    "resources.cpu.cores",
    "auth.postgresPassword",
    "primary.persistence.enabled",
]
LAYERS = {"common", "local", "durable"}

PLATFORM_MAIN = "platform/cloud/modules/platform/main.tf"
DEV_OBSERVABILITY = "cli/lib/local/sol_cli_dev_observability.ml"
MANIFEST = "cli/lib/workspace/sol_cli_manifest_yaml.ml"
FRAMEWORK_OBS = "framework/ocaml/sol-obs/lib/sol_obs.ml"
DEMO_TS = "examples/pluto/app/demo_ts"
DEMO_TS_TRACING = [
    f"{DEMO_TS}/order_svc/src/tracing.ts",
    f"{DEMO_TS}/fulfillment_worker/src/tracing.ts",
]
DEMO_TS_LOGS = [
    f"{DEMO_TS}/order_svc/src/index.ts",
    f"{DEMO_TS}/fulfillment_worker/src/index.ts",
]
DEMO_TS_PACKAGES = [
    f"{DEMO_TS}/order_svc/package.json",
    f"{DEMO_TS}/fulfillment_worker/package.json",
]
OBS_TS_IDENTITY_FLOOR = (0, 4, 0)
OBS_TS_DEP = re.compile(r'"@sol-fab/obs":\s*"\^(\d+)\.(\d+)\.(\d+)"')
TS_TEMPLATE_PACKAGES = [
    "platform/shared/templates/svc-ts/package.json",
    "platform/shared/templates/worker-ts/package.json",
]
DEMO_TS_LOCKFILE = f"{DEMO_TS}/package-lock.json"
DEV_TAXONOMY = re.compile(r"~taxonomy_labels:\[(.*?)\]", re.S)


def ocaml_pair_list(text, name):
    match = re.search(rf"let {name} =\s*\[(.*?)\]\s*;;", text, re.S)
    if match is None:
        return None
    return re.findall(r'"([^"]+)"\s*,\s*"([^"]+)"', match.group(1))


def framework_taxonomy(root):
    problems = []
    framework = root / FRAMEWORK_OBS
    if not framework.is_file():
        return None, [f"{FRAMEWORK_OBS} is missing, so the emitted identity vocabulary cannot be checked"]
    pairs = ocaml_pair_list(framework.read_text(encoding="utf-8"), "taxonomy")
    if pairs is None:
        problems.append(
            f'{FRAMEWORK_OBS} no longer declares `let taxonomy = [ "SOL_VAR", "label"; ... ]`'
        )
    elif len({label for _, label in pairs}) != len(pairs):
        problems.append(f"{FRAMEWORK_OBS} declares duplicate observability identity labels")
    return pairs, problems


def identity_problems(root, framework_pairs):
    problems = []
    manifest = root / MANIFEST
    manifest_pairs = None
    if not manifest.is_file():
        problems.append(f"{MANIFEST} is missing, so the rendered identity vocabulary cannot be checked")
    else:
        manifest_pairs = ocaml_pair_list(
            manifest.read_text(encoding="utf-8"), "observability_identity"
        )
        if manifest_pairs is None:
            problems.append(
                f'{MANIFEST} no longer declares `let observability_identity = [ "label", "SOL_VAR"; ... ]`'
            )
        elif len({label for label, _ in manifest_pairs}) != len(manifest_pairs):
            problems.append(f"{MANIFEST} declares duplicate observability identity labels")
    if framework_pairs is not None and manifest_pairs is not None:
        framework_env = {label: var for var, label in framework_pairs}
        manifest_env = {label: var for label, var in manifest_pairs}
        if framework_env != manifest_env:
            problems.append(
                "the framework and the manifest must map each identity label to the same environment "
                f"variable; framework={framework_env}, manifest={manifest_env}"
            )
    return problems


def typescript_identity_problems(root):
    problems = []
    for rel in DEMO_TS_TRACING:
        path = root / rel
        if not path.is_file():
            problems.append(f"{rel} is missing, so the TypeScript trace identity cannot be checked")
            continue
        text = path.read_text(encoding="utf-8")
        if "resourceAttributes(" not in text:
            problems.append(
                f"{rel} must build its OTel resource from resourceAttributes() so a TypeScript trace "
                "carries Sol's injected workload identity (DEC-064/OBS-051)"
            )
        if "ATTR_SERVICE_NAME" in text:
            problems.append(
                f"{rel} hardcodes service.name instead of reading the injected identity (DEC-064/OBS-051)"
            )
    for rel in DEMO_TS_LOGS:
        path = root / rel
        if not path.is_file():
            problems.append(f"{rel} is missing, so the TypeScript log identity cannot be checked")
            continue
        if "makeLokiPusher(" not in path.read_text(encoding="utf-8"):
            problems.append(
                f"{rel} must push its logs through makeLokiPusher() so the Loki stream carries Sol's "
                "injected workload identity (DEC-064/OBS-051)"
            )
    for rel in DEMO_TS_PACKAGES + TS_TEMPLATE_PACKAGES:
        path = root / rel
        if not path.is_file():
            problems.append(f"{rel} is missing, so the TypeScript identity floor cannot be checked")
            continue
        match = OBS_TS_DEP.search(path.read_text(encoding="utf-8"))
        if match is None:
            problems.append(f'{rel} must depend on "@sol-fab/obs" to read the injected identity (OBS-051)')
        elif tuple(int(part) for part in match.groups()) < OBS_TS_IDENTITY_FLOOR:
            floor = ".".join(str(part) for part in OBS_TS_IDENTITY_FLOOR)
            problems.append(
                f"{rel} pins @sol-fab/obs {match.group(0)}, which predates Sol workload-identity support "
                f"({floor}); the app's own service name would win (OBS-051)"
            )
    return problems


def typescript_lockfile_problems(root):
    problems = []
    path = root / DEMO_TS_LOCKFILE
    if not path.is_file():
        problems.append(f"{DEMO_TS_LOCKFILE} is missing, so the resolved @sol-fab/obs version cannot be checked")
        return problems
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as error:
        problems.append(f"{DEMO_TS_LOCKFILE} could not be parsed: {error}")
        return problems
    versions = sorted(
        {
            entry.get("version")
            for name, entry in lock.get("packages", {}).items()
            if name.endswith("@sol-fab/obs") and isinstance(entry, dict)
        }
    )
    if len(versions) != 1:
        problems.append(
            f"{DEMO_TS_LOCKFILE} resolves {versions or 'no versions of'} @sol-fab/obs; a consumer must "
            "carry exactly one, or @sol-fab/kafka's re-exported tracing and the app's own logs drift "
            "apart (BUG-127)"
        )
        return problems
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)", str(versions[0]))
    if match is None:
        problems.append(f"{DEMO_TS_LOCKFILE} resolves @sol-fab/obs {versions[0]!r}, which is not a version")
        return problems
    if tuple(int(part) for part in match.groups()) < OBS_TS_IDENTITY_FLOOR:
        floor = ".".join(str(part) for part in OBS_TS_IDENTITY_FLOOR)
        problems.append(
            f"{DEMO_TS_LOCKFILE} resolves @sol-fab/obs {versions[0]}, which predates Sol workload-identity "
            f"support ({floor}) (OBS-051)"
        )
    return problems


def ocaml_taxonomy(text):
    match = DEV_TAXONOMY.search(text)
    if match is None:
        return None
    return re.findall(r'"([^"]+)"', match.group(1))


def terraform_taxonomy(path):
    data = tfconfig.load(path)
    for block in tfconfig.blocks(data, "locals"):
        if "observability_taxonomy_labels" in block:
            labels = block["observability_taxonomy_labels"]
            return [tfconfig.unquote(value) for value in labels]
    return None


def taxonomy_problems(root, framework_pairs):
    problems = []
    if framework_pairs is None:
        return problems
    framework_labels = [label for _, label in framework_pairs]
    main_tf = root / PLATFORM_MAIN
    dev = root / DEV_OBSERVABILITY
    try:
        cloud = terraform_taxonomy(main_tf)
    except Exception as e:
        return [f"{main_tf} could not be parsed for observability_taxonomy_labels: {e}"]
    if cloud is None:
        problems.append(f"{main_tf} no longer declares locals.observability_taxonomy_labels")
    if not dev.is_file():
        problems.append(f"{DEV_OBSERVABILITY} is missing, so the local Alloy mirror cannot be checked")
        return problems
    local = ocaml_taxonomy(dev.read_text(encoding="utf-8"))
    if local is None:
        problems.append(f"{DEV_OBSERVABILITY} no longer declares ~taxonomy_labels:[...]")
    if cloud is not None and local is not None:
        if cloud != local:
            problems.append(
                f"the cloud Alloy taxonomy {cloud} and the local mirror {local} must be identical "
                "(dev mirrors prod, DEC-046)"
            )
        if sorted(cloud) != sorted(framework_labels):
            problems.append(
                f"the cloud log-promotion taxonomy {cloud} must match the framework identity labels "
                f"{framework_labels}"
            )
    return problems


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[2])
    local_sources = [root / "cli/bin/cmd_local.ml", root / "cli/lib/local/sol_cli_local_platform.ml"]
    main_tf = root / PLATFORM_MAIN
    components_json = root / "platform/shared/components.json"
    problems = []
    for key in MIGRATED:
        for source in local_sources + [main_tf]:
            if source.is_file() and f'"{key}"' in source.read_text():
                problems.append(
                    f'{source} hardcodes "{key}" inline again -- this value belongs in '
                    "platform/shared/components.json (ADR 0001 / CODE_LAYER-005)."
                )
    for key in LOCAL_ONLY:
        for source in local_sources:
            if source.is_file() and f'"{key}"' in source.read_text():
                problems.append(
                    f'{source} hardcodes "{key}" inline again -- this value now comes entirely from the local '
                    "layer of platform/shared/components.json (ADR 0001 / CODE_LAYER-005)."
                )
    try:
        components = json.loads(components_json.read_text())
    except (OSError, ValueError) as e:
        problems.append(f"{components_json} could not be read: {e}")
        components = {}
    versions = components.pop("versions", None)
    if not isinstance(versions, dict) or not versions:
        problems.append(
            f"{components_json} must declare a top-level `versions` object of platform chart "
            "versions, shared by the local platform and the production Terraform module"
        )
    elif any(not isinstance(version, str) or not version for version in versions.values()):
        problems.append(f"{components_json}: every versions entry must be a non-empty string")
    bad = [
        f"{name}: {sorted(layers) if isinstance(layers, dict) else type(layers).__name__}"
        for name, layers in sorted(components.items())
        if not isinstance(layers, dict) or set(layers) != LAYERS
    ]
    if bad:
        problems.append(
            f"every component in {components_json} must have exactly the layers common, local, durable "
            "(keyed by profile, never by env, provider or region):\n  " + "\n  ".join(bad)
        )
    framework_pairs, framework_problems = framework_taxonomy(root)
    problems.extend(framework_problems)
    problems.extend(taxonomy_problems(root, framework_pairs))
    problems.extend(identity_problems(root, framework_pairs))
    problems.extend(typescript_identity_problems(root))
    problems.extend(typescript_lockfile_problems(root))
    for problem in problems:
        print(f"guardrail: {problem}", file=sys.stderr)
    if problems:
        sys.exit(1)
    print("guardrail: no migrated platform-component keys found duplicated inline in the local platform or main.tf.")
    print("guardrail: the cloud and local Alloy taxonomy declarations match the framework identity labels.")
    print("guardrail: framework and manifest identity declarations agree; the rendered identity ConfigMap is covered by the manifest-render tests.")
    print("guardrail: TypeScript demo sources reference the identity helpers and avoid hardcoding service.name.")
    print("guardrail: the demo and the TypeScript templates pin @sol-fab/obs at or above the identity floor, and the demo lockfile resolves exactly one copy.")


main()
