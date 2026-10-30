import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = [sys.executable, str(REPO / "internal/ci/check_production_infra.py")]
AWS = "platform/cloud/aws/cluster/main.tf"
AWS_VARS = "platform/cloud/aws/cluster/variables.tf"
GCP = "platform/cloud/gcp/cluster/main.tf"
GCP_VARS = "platform/cloud/gcp/cluster/variables.tf"
GCP_OUT = "platform/cloud/gcp/cluster/outputs.tf"
GCP_KAFKA = "platform/cloud/gcp/cluster/kafka.tf"
MODULE = "platform/cloud/modules/platform/main.tf"
MODULE_VARS = "platform/cloud/modules/platform/variables.tf"
DEPLOY = "platform/cloud/modules/platform/platform_deploy_rbac.tf"
NETWORK = "platform/cloud/modules/platform/platform_network_facts.tf"
PROVISIONER = "platform/cloud/modules/platform/platform_provisioner_rbac.tf"
BOOTSTRAP = "platform/cloud/aws/bootstrap/main.tf"
BOOTSTRAP_OUT = "platform/cloud/aws/bootstrap/outputs.tf"
AWS_PLATFORM = "platform/cloud/aws/platform/main.tf"
AWS_PLATFORM_VARS = "platform/cloud/aws/platform/variables.tf"
LEASE = "cli/lib/deploy/sol_cli_boundary_lease.ml"


def edit(path, pattern, replacement, after=None, literal=True):
    def mutate(root):
        text = (root / path).read_text()
        start = 0
        if after is not None:
            start = text.find(after)
            if start < 0:
                sys.exit(f"FAIL: a mutation's scope anchor no longer matches {path}: {after!r}")
        head, tail = text[:start], text[start:]
        if literal:
            if pattern not in tail:
                sys.exit(f"FAIL: a mutation's anchor no longer matches {path}: {pattern!r}")
            tail = tail.replace(pattern, replacement, 1)
        else:
            tail, n = re.subn(pattern, replacement, tail, count=1, flags=re.S)
            if n != 1:
                sys.exit(f"FAIL: a mutation's pattern no longer matches {path}: {pattern!r}")
        (root / path).write_text(head + tail)
    return mutate


def append(path, text):
    def mutate(root):
        with open(root / path, "a", encoding="utf-8") as f:
            f.write(text)
    return mutate


def default_of(path, variable, value):
    return edit(path, rf'(variable "{variable}" \{{.*?default\s*=\s*)\S+', rf"\g<1>{value}", literal=False)


CASES = [
    ("rds-precondition-removed", edit(AWS, "    precondition {", "    postcondition {"), "has no precondition guarding db_password"),
    ("rds-precondition-forgets-the-password", edit(
        AWS, r"(precondition \{.*?\n    \})", lambda m: m.group(1).replace("db_password", "db_secret"), literal=False),
     "the RDS precondition no longer mentions db_password"),
    ("rds-multi-az-dropped", edit(AWS, "  multi_az                = var.rds_multi_az\n", ""), "lost its multi_az wiring"),
    ("rds-deletion-protection-default-false", default_of(AWS_VARS, "rds_deletion_protection", "false"), "rds_deletion_protection no longer defaults to true"),
    ("rds-skip-final-snapshot-default-true", default_of(AWS_VARS, "rds_skip_final_snapshot", "true"), "rds_skip_final_snapshot no longer defaults to false"),
    ("sql-guard-literal", edit(GCP, "  deletion_protection = var.sql_deletion_protection", "  deletion_protection = true"), "no longer wires Terraform's deletion-protection guard"),
    ("sql-live-setting-literal", edit(GCP, "deletion_protection_enabled = var.sql_deletion_protection", "deletion_protection_enabled = false"), "no longer wires the live API deletion-protection setting"),
    ("sql-deletion-protection-default-false", default_of(GCP_VARS, "sql_deletion_protection", "false"), "sql_deletion_protection no longer defaults to true"),
    ("gcp-output-renamed", edit(GCP_OUT, 'output "artifact_registry" {', 'output "artifact_registry_url" {'), 'no longer publishes "artifact_registry"'),
    ("gcp-kafka-reader-no-deployer", edit(GCP_KAFKA, 'data "google_client_openid_userinfo" "deployer" {', 'data "google_client_openid_userinfo" "deployer_renamed" {'), "deploying identity"),
    ("gcp-kafka-reader-var-only", edit(GCP_KAFKA, 'for_each  = var.kafka_connection == null ? toset([]) : local.kafka_reader_members', 'for_each  = var.kafka_connection == null ? toset([]) : var.kafka_reader_members'), "resolved deploying identity"),
    ("gcp-kafka-reader-precondition-var", edit(GCP_KAFKA, 'condition     = length(local.kafka_reader_members) > 0', 'condition     = length(var.kafka_reader_members) > 0'), "resolved deploying identity"),
    ("rds-skip-final-snapshot-literal", edit(AWS, "  skip_final_snapshot     = var.rds_skip_final_snapshot", "  skip_final_snapshot     = false"), "no longer takes skip_final_snapshot from its own"),
    ("rds-final-snapshot-identifier-dropped", edit(AWS, "  final_snapshot_identifier = (", "  final_snapshot_name = ("), "sets no final_snapshot_identifier"),
    ("storage-class-unencrypted", edit(MODULE, '    encrypted = "true"', '    encrypted = "false"'), 'no longer sets encrypted = "true"'),
    ("storage-class-on-every-provider", edit(MODULE, 'var.create_storage_class && var.cloud_provider == "aws" ? 1 : 0', "var.create_storage_class ? 1 : 0"), "no longer created on AWS only"),
    ("storage-class-name-disagrees", default_of(MODULE_VARS, "storage_class_name", '"gp2"'), "does not name the StorageClass Terraform creates"),
    ("storage-driver-disagrees", edit(MODULE, '"ebs.csi.aws.com"', '"ebs.csi.example.com"'), "does not name the CSI driver"),
    ("deploy-role-missing", edit(DEPLOY, 'resource "kubernetes_cluster_role" "sol_deploy" {', 'resource "kubernetes_cluster_role" "sol_deploy_renamed" {'), "kubernetes_cluster_role.sol_deploy not found"),
    ("deploy-role-bound-cluster-wide", append(DEPLOY, '''
resource "kubernetes_cluster_role_binding" "everywhere" {
  metadata { name = "sol-deploy-everywhere" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.sol_deploy.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "sol:deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}
'''), "is bound by a ClusterRoleBinding"),
    ("bootstrap-rolebindings-patchable", edit(
        DEPLOY, '    resources  = ["rolebindings"]\n    verbs      = ["get", "list", "watch", "create"]',
        '    resources  = ["rolebindings"]\n    verbs      = ["get", "list", "watch", "create", "patch"]'), "are no longer\n      create-only"),
    ("lease-outside-default", edit(DEPLOY, '    namespace = "default"', '    namespace = "kube-system"', after='resource "kubernetes_role" "sol_boundary_lease"'), "must grant exactly get/create/update/delete"),
    ("lease-lists-configmaps", edit(DEPLOY, 'verbs      = ["get", "update", "delete"]', 'verbs      = ["get", "update", "delete", "list"]'), "must grant exactly get/create/update/delete"),
    ("lease-reaches-secrets", edit(DEPLOY, '    resources  = ["configmaps"]\n    verbs      = ["create"]', '    resources  = ["configmaps", "secrets"]\n    verbs      = ["create"]'), "must grant exactly get/create/update/delete"),
    ("lease-bound-to-another-group", edit(DEPLOY, '    name      = "sol:deployers"', '    name      = "sol:everyone"', after='resource "kubernetes_role_binding" "sol_boundary_lease"'), "is not bound to sol:deployers in default"),
    ("service-account-subject-api-group", edit(DEPLOY, '    api_group = ""', '    api_group = "rbac.authorization.k8s.io"', after='kind      = "ServiceAccount"'), "ServiceAccount RBAC subject carries apiGroup"),
    ("network-facts-service-account-missing", edit(NETWORK, 'subject {\n    kind      = "ServiceAccount"', 'subject_removed {\n    kind      = "ServiceAccount"'), "network_facts does not bind"),
    ("kafka-ca-reader-missing", edit(DEPLOY, 'resource "kubernetes_role" "sol_kafka_ca_reader" {', 'resource "kubernetes_role" "sol_kafka_ca_reader_renamed" {'), "kubernetes_role.sol_kafka_ca_reader not found"),
    ("kafka-ca-reader-wrong-namespace", edit(DEPLOY, '    namespace = kubernetes_namespace.redpanda.metadata[0].name', '    namespace = "default"', after='resource "kubernetes_role" "sol_kafka_ca_reader"'), "must grant exactly get"),
    ("kafka-ca-reader-lists", edit(DEPLOY, '    verbs          = ["get"]', '    verbs          = ["get", "list"]', after='resource "kubernetes_role" "sol_kafka_ca_reader"'), "must grant exactly get"),
    ("kafka-ca-reader-widened", edit(DEPLOY, '    resource_names = ["redpanda-default-cert"]', '    resource_names = ["redpanda-default-cert", "redpanda-external-cert"]', after='resource "kubernetes_role" "sol_kafka_ca_reader"'), "must grant exactly get"),
    ("kafka-ca-reader-binds-another-role", edit(DEPLOY, '    name      = kubernetes_role.sol_kafka_ca_reader.metadata[0].name', '    name      = kubernetes_role.sol_boundary_lease.metadata[0].name', after='resource "kubernetes_role_binding" "sol_kafka_ca_reader"'), "not bound to sol:deployers in redpanda"),
    ("kafka-ca-reader-bound-to-another-group", edit(DEPLOY, '    name      = "sol:deployers"', '    name      = "sol:everyone"', after='resource "kubernetes_role_binding" "sol_kafka_ca_reader"'), "not bound to sol:deployers in redpanda"),
    ("lease-issues-a-new-operation", append(LEASE, "\nlet _ = Sol_cli_kubectl.apply\n"), "boundary-lease kubectl operations changed"),
    ("bind-allowlist-loses-sol-deploy", edit(DEPLOY, "      kubernetes_cluster_role.sol_deploy.metadata[0].name,\n", ""), "sol-deploy is no longer in the deploy bootstrap's bind allowlist"),
    ("bind-allowlist-loses-operator", edit(DEPLOY, "      kubernetes_cluster_role.sol_operator_diagnostics.metadata[0].name,\n", ""), "is not in the deploy bootstrap's"),
    ("bind-allowlist-wildcard", edit(DEPLOY, "    resource_names = [\n", '    resource_names = [\n      "*",\n'), "bind allowlist uses a wildcard"),
    ("deploy-bootstrap-escalates", edit(DEPLOY, 'verbs = ["bind"]', 'verbs = ["bind", "escalate"]'), "grants escalate"),
    ("deploy-entry-unguarded", edit(AWS, 'var.deploy_role_arn == "" ? {} : {', "{"), "no longer guards deploy_role_arn"),
    ("provisioner-publish-deny-renamed", edit(BOOTSTRAP, 'sid    = "NoImagePublish"', 'sid    = "NoImagePublishing"'), "no longer explicitly denies ecr:PutImage"),
    ("provisioner-publish-deny-allows", edit(BOOTSTRAP, 'effect = "Deny"', 'effect = "Allow"', after='sid    = "NoImagePublish"'), "no longer explicitly denies ecr:PutImage"),
    ("publisher-cannot-push", edit(BOOTSTRAP, '      "ecr:PutImage",\n', "", after='sid    = "PublishWorkspaceImages"'), "no longer grants ecr:PutImage"),
    ("publisher-deny-renamed", edit(BOOTSTRAP, 'sid    = "NoProvisionOrDeploy"', 'sid    = "NoProvisioning"'), "no longer explicitly denies provisioning/IAM"),
    ("publisher-deny-allows", edit(BOOTSTRAP, 'effect = "Deny"', 'effect = "Allow"', after='sid    = "NoProvisionOrDeploy"'), "no longer explicitly denies provisioning/IAM"),
    ("publisher-policy-output-renamed", edit(BOOTSTRAP_OUT, 'output "publisher_policy_json"', 'output "publisher_json"'), "no longer outputs publisher_policy_json"),
    ("provisioner-wildcard", edit(PROVISIONER, '    verbs      = ["get", "list", "watch"]', '    verbs      = ["get", "list", "watch", "*"]'), "grants escalate/bind"),
    ("provisioner-write", edit(PROVISIONER, '    verbs      = ["get", "list", "watch"]', '    verbs      = ["get", "list", "watch", "create"]'), "not read-only"),
    ("module-declares-a-backend", append(MODULE, '\nterraform {\n  backend "s3" {}\n}\n'), "the shared platform module declares a backend"),
    ("gcp-cluster-on-s3", edit(GCP, 'backend "gcs" {}', 'backend "s3" {}'), "the GCP cloud root declares the S3 backend"),
    ("aws-platform-wrong-backend", edit(AWS_PLATFORM, 'backend "s3" {}', 'backend "gcs" {}'), "no longer declares the s3 backend"),
    ("aws-platform-misses-a-variable", edit(AWS_PLATFORM_VARS, r'variable "base_domain" \{.*?\n\}\n', "", literal=False), "does not mirror these declared variables"),
    ("aws-platform-extra-variable", append(AWS_PLATFORM_VARS, '\nvariable "not_in_the_definition" {\n  type = string\n}\n'), "declares variables the shared definition"),
    ("aws-platform-does-not-pass-one", edit(AWS_PLATFORM, "  base_domain                             = var.base_domain\n", ""), "declares but does not pass to the module"),
]


def tree(scratch, name):
    root = scratch / name
    shutil.copytree(REPO / "platform/cloud", root / "platform/cloud", ignore=shutil.ignore_patterns(".terraform", "*.tfstate*"))
    for rel in ("cli/lib/cloud/sol_cli_provider_capabilities.ml", LEASE):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / rel, root / rel)
    return root


def verdict(guard, root, env=None):
    run = subprocess.run(guard + [str(root)], capture_output=True, text=True, env=env)
    return run.returncode, run.stdout + run.stderr


def main(guard=GUARD, strict=True):
    no_terraform = {**os.environ, "PATH": ":".join(p for p in os.environ["PATH"].split(":") if not (Path(p) / "terraform").exists())}
    results = []
    with tempfile.TemporaryDirectory() as scratch:
        rc, output = verdict(guard, tree(Path(scratch), "real-tree"))
        if rc != 0:
            sys.exit(f"FAIL: the guard rejected the real tree:\n{output}")
        for name, mutate, expected in CASES:
            root = tree(Path(scratch), name)
            mutate(root)
            rc, output = verdict(guard, root, env=no_terraform)
            caught = rc != 0 and expected in output
            results.append((name, caught))
            if strict and not caught:
                why = "accepted it" if rc == 0 else "rejected it for another reason"
                sys.exit(f"FAIL: the guard {why} ('{name}'), expected: {expected!r}\n{output}")
            print(f"  {'rejected' if caught else 'MISSED  '}: {name}")
        if strict:
            if shutil.which("terraform"):
                root = tree(Path(scratch), "unformatted")
                edit(MODULE, '    encrypted = "true"', '    encrypted =   "true"')(root)
                rc, output = verdict(guard, root)
                if rc == 0 or "not terraform-fmt clean" not in output:
                    sys.exit(f"FAIL: the guard did not reject unformatted Terraform:\n{output}")
                print("  rejected: platform-cloud-unformatted")
            else:
                print("  skipped : platform-cloud-unformatted (terraform is not installed here)")
    if strict:
        print(f"check_production_infra: all {len(CASES)} mutations rejected for their own reason; the real tree accepted")
    return results


if __name__ == "__main__":
    main()
