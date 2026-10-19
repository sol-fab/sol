import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_provider_tls_path.py"

ISSUER = "platform/cloud/modules/platform/cert_manager_issuer.tf"
RELEASE = "platform/cloud/modules/platform/main.tf"
GCP_PLATFORM = "platform/cloud/gcp/platform/main.tf"
GCP_CLUSTER = "platform/cloud/gcp/cluster/main.tf"
AWS_CLUSTER = "platform/cloud/aws/cluster/main.tf"
AWS_PLATFORM = "platform/cloud/aws/platform/main.tf"
GCP_DRIVER = "cli/lib/cloud/sol_cli_gcp_cluster.ml"
AWS_DRIVER = "cli/lib/cloud/sol_cli_aws_cluster.ml"

GCP_PLATFORM_VARS = "platform/cloud/gcp/platform/variables.tf"
AWS_PLATFORM_VARS = "platform/cloud/aws/platform/variables.tf"

COPIED = (
    ISSUER,
    RELEASE,
    GCP_PLATFORM,
    GCP_PLATFORM_VARS,
    GCP_CLUSTER,
    AWS_CLUSTER,
    AWS_PLATFORM,
    AWS_PLATFORM_VARS,
    GCP_DRIVER,
    AWS_DRIVER,
)


def substitute(relative, pattern, replacement, count=1):
    def mutate(root):
        path = root / relative
        text, changed = re.subn(pattern, replacement, path.read_text(), count=count)
        assert changed >= 1, f"the mutation anchor {pattern!r} did not match in {relative}"
        path.write_text(text)
    return mutate


def remove_block(relative, anchor):
    def mutate(root):
        path = root / relative
        text = path.read_text()
        start = text.index(anchor)
        depth = 0
        index = text.index("{", start)
        while True:
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        end = text.index("\n", index) + 1
        path.write_text(text[: text.rindex("\n", 0, start) + 1] + text[end:])
    return mutate


CASES = [
    ("gcp-solver-removed", substitute(
        ISSUER, r'cloudDNS = \{\n\s*project = var\.cert_manager_dns01_project\n\s*\}',
        'route53 = { region = "us-east-1" }', count=2)),
    ("gcp-solver-variable-removed", substitute(
        ISSUER, r'var\.cert_manager_dns01_project', '"sol-qualification"', count=2)),
    ("gcp-issuers-not-gated-on-the-provider", substitute(
        ISSUER, r'count = var\.cloud_provider == "gcp" \? 1 : 0', 'count = 1', count=2)),
    ("aws-issuers-not-gated-on-the-provider", substitute(
        ISSUER, r'count = var\.cloud_provider == "gcp" \? 0 : 1', 'count = 1', count=2)),
    ("gcp-identity-annotation-removed", substitute(
        RELEASE, r'\n\s*\(local\.cert_manager_identity_annotation\) = local\.cert_manager_identity', "")),
    ("gcp-identity-input-removed", substitute(
        ISSUER, r'var\.cert_manager_workload_identity_sa_email', '""', count=3)),
    ("gcp-empty-identity-no-longer-refused", substitute(
        ISSUER, r'condition\s*=\s*var\.cert_manager_workload_identity_sa_email != ""',
        'condition     = true', count=2)),
    ("gcp-platform-root-drops-the-identity", substitute(
        GCP_PLATFORM, r"\n\s*cert_manager_workload_identity_sa_email = var\.cert_manager_workload_identity_sa_email", "")),
    ("gcp-record-role-widened-to-zone-read", substitute(
        GCP_CLUSTER, r'"dns\.resourceRecordSets\.create",', '"dns.resourceRecordSets.get",')),
    ("gcp-zone-binding-becomes-project-wide", substitute(
        GCP_CLUSTER,
        r'resource "google_dns_managed_zone_iam_member" "cert_manager_dns_records"',
        'resource "google_project_iam_member" "cert_manager_dns_records"',
        count=1)),
    ("gcp-workload-identity-binding-removed", remove_block(
        GCP_CLUSTER, 'resource "google_service_account_iam_member" "cert_manager_workload_identity"')),
    ("gcp-workload-identity-not-enabled", remove_block(
        GCP_CLUSTER, 'workload_identity_config {')),
    ("gcp-pool-uses-the-node-metadata-server", substitute(
        GCP_CLUSTER, r'mode = "GKE_METADATA"', 'mode = "GCE_METADATA"')),
    ("gcp-driver-refuses-tls-again", substitute(
        GCP_DRIVER, r"let platform_vars outputs context ~cluster_issuer:_ ~region:_ =",
        'let platform_vars outputs context ~cluster_issuer:_ ~region:_ =\n  let _ = "Sol cannot yet wire a certificate issuer on GCP" in\n  ignore _ in')),
    ("aws-record-authority-widened-to-every-zone", substitute(
        AWS_CLUSTER,
        r'resources = \[local\.route53_zone_arn\]',
        'resources = ["*"]')),
    ("aws-solver-region-dropped", substitute(
        AWS_PLATFORM, r"\n\s*cert_manager_dns01_region\s*=\s*var\.cert_manager_dns01_region", "")),
]


def tree(scratch, name):
    root = scratch / name
    for relative in COPIED:
        (root / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / relative, root / relative)
    return root


def snapshot(root):
    return sorted((p, p.read_bytes()) for p in root.rglob("*") if p.is_file())


def verdict(root):
    run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def main():
    print("check_provider_tls_path mutations")
    with tempfile.TemporaryDirectory() as scratch:
        for name, mutate in CASES:
            root = tree(Path(scratch), name)
            before = snapshot(root)
            mutate(root)
            if snapshot(root) == before:
                sys.exit(f"FAIL: the '{name}' mutation did not change the tree at all")
            rc, output = verdict(root)
            if rc == 0:
                sys.exit(f"FAIL: the guard accepted the '{name}' mutation:\n{output}")
            first = next((line for line in output.splitlines() if line.startswith("FAIL")), "")
            print(f"  rejected: {name} -- {first[:88]}")
        rc, output = verdict(tree(Path(scratch), "real-tree"))
        if rc != 0:
            sys.exit(f"FAIL: the guard rejected the unmutated tree (real-tree):\n{output}")
        print(f"  accepted: real-tree -- {output.strip()[:100]}")
    print("check_provider_tls_path: all mutations rejected, unmutated tree accepted")


main()
