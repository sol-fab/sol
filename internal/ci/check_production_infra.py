import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

GCP_MAY_OMIT = {
    "aws_region",
    "cert_manager_dns01_region",
    "cert_manager_irsa_role_arn",
    "grafana_irsa_role_arn",
    "loki_irsa_role_arn",
    "loki_s3_bucket",
    "thanos_irsa_role_arn",
    "thanos_s3_bucket",
}
# The platform root synthesizes this module input from the cluster output and a
# scoped provider read; it is not a root variable the module call can mirror.
SYNTHESIZED_MODULE_INPUTS = {"kafka_credential"}
NAMESPACE_KINDS = {"namespaces", "rolebindings"}


def fail(*lines):
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)


def find(found, type_, name):
    return next((r for r in found if r.type == type_ and r.name == name), None)


def literal(value):
    return tfconfig.unquote(value) if tfconfig.is_string_literal(value) else value


def strings(values):
    return [literal(v) for v in (values or [])]


def default_of(variables, name):
    body = variables.get(name, {})
    return body.get("default") if "default" in body else None


def statements(policy):
    return [
        (literal(s.get("sid", "")), literal(s.get("effect", '"Allow"')), strings(s.get("actions")))
        for s in tfconfig.blocks(policy.body, "statement")
    ]


def rules(resource):
    return [
        (strings(rule.get("resources")), strings(rule.get("verbs")), rule)
        for rule in tfconfig.blocks(resource.body, "rule")
    ]


def backends(path):
    doc = tfconfig.load(path)
    return [
        tfconfig.unquote(name)
        for terraform in doc.get("terraform", [])
        for backend in tfconfig.blocks(terraform, "backend")
        for name in backend
        if name != "__is_block__"
    ]


def check_aws_database(root):
    aws = root / "platform/cloud/aws/cluster/main.tf"
    if not aws.is_file():
        fail(f"FAIL: {aws} is missing")
    rds = find(tfconfig.resources(aws), "aws_db_instance", "postgres")
    if rds is None:
        fail(f"FAIL: aws_db_instance.postgres not found in {aws}")
    preconditions = [p for lifecycle in tfconfig.blocks(rds.body, "lifecycle") for p in tfconfig.blocks(lifecycle, "precondition")]
    if not preconditions:
        fail(
            "FAIL: aws_db_instance.postgres has no precondition guarding db_password;",
            "      an empty password would again reach CreateDBInstance.",
        )
    if not any("db_password" in str(p) for p in preconditions):
        fail("FAIL: the RDS precondition no longer mentions db_password")
    if "multi_az" not in rds.body:
        fail("FAIL: aws_db_instance.postgres lost its multi_az wiring")
    variables = tfconfig.variables(root / "platform/cloud/aws/cluster/variables.tf")
    if default_of(variables, "rds_deletion_protection") is not True:
        fail(
            "FAIL: rds_deletion_protection no longer defaults to true;",
            "      a production database would be destroyable by an ordinary apply.",
        )
    if default_of(variables, "rds_skip_final_snapshot") is not False:
        fail(
            "FAIL: rds_skip_final_snapshot no longer defaults to false;",
            "      destroying production Postgres would take no final snapshot.",
        )
    return rds


def check_gcp_database(root):
    gcp = root / "platform/cloud/gcp/cluster/main.tf"
    sql = find(tfconfig.resources(gcp), "google_sql_database_instance", "postgres")
    if sql is None:
        fail(f"FAIL: google_sql_database_instance.postgres not found in {gcp}")
    if tfconfig.variable_reference(sql.body.get("deletion_protection")) != "sql_deletion_protection":
        fail("FAIL: Cloud SQL no longer wires Terraform's deletion-protection guard.")
    live = [s.get("deletion_protection_enabled") for s in tfconfig.blocks(sql.body, "settings")]
    if not any(tfconfig.variable_reference(v) == "sql_deletion_protection" for v in live):
        fail("FAIL: Cloud SQL no longer wires the live API deletion-protection setting.")
    variables = tfconfig.variables(root / "platform/cloud/gcp/cluster/variables.tf")
    if default_of(variables, "sql_deletion_protection") is not True:
        fail("FAIL: sql_deletion_protection no longer defaults to true")
    outputs_tf = root / "platform/cloud/gcp/cluster/outputs.tf"
    if not outputs_tf.is_file():
        fail(f"FAIL: {outputs_tf} is missing")
    published = {tfconfig.unquote(n) for entry in tfconfig.load(outputs_tf).get("output", []) for n in entry}
    for required in ("cluster_name", "project_id", "region", "artifact_registry"):
        if required not in published:
            fail(
                f'FAIL: the GCP cloud root no longer publishes "{required}",',
                "      which Sol_cli_gcp_cluster.gcp_outputs_of_json requires.",
            )


def check_gcp_kafka(root):
    """The GCP Kafka secret's reader is the deploying identity, explicitly."""
    kafka = root / "platform/cloud/gcp/cluster/kafka.tf"
    text = kafka.read_text()
    if 'data "google_client_openid_userinfo" "deployer"' not in text:
        fail("FAIL: the GCP Kafka secret no longer reads the deploying identity.")
    if "data.google_client_openid_userinfo.deployer[0].email" not in text:
        fail("FAIL: the GCP Kafka reader no longer names the deploying identity.")
    if "condition     = length(local.kafka_reader_members) > 0" not in text:
        fail("FAIL: the GCP Kafka precondition no longer checks the resolved deploying identity.")
    if (
        "for_each  = var.kafka_connection == null ? toset([]) : local.kafka_reader_members"
        not in text
    ):
        fail("FAIL: the GCP Kafka grant no longer uses the resolved deploying identity.")


def check_final_snapshot(rds):
    if tfconfig.variable_reference(rds.body.get("skip_final_snapshot")) != "rds_skip_final_snapshot":
        fail(
            "FAIL: aws_db_instance.postgres no longer takes skip_final_snapshot from its own",
            "      variable; finding 9 was that this was derived from deletion protection.",
        )
    if "final_snapshot_identifier" not in rds.body:
        fail(
            "FAIL: aws_db_instance.postgres sets no final_snapshot_identifier, so terraform",
            "      refuses to destroy it at all whenever a final snapshot is required.",
        )


def check_storage_class(root):
    module_main = root / "platform/cloud/modules/platform/main.tf"
    sc = find(tfconfig.resources(module_main), "kubernetes_storage_class_v1", "platform_default")
    if sc is None:
        fail("FAIL: kubernetes_storage_class_v1.platform_default not found")
    if literal(sc.body.get("parameters", {}).get("encrypted")) != "true":
        fail(
            'FAIL: the default StorageClass no longer sets encrypted = "true";',
            "      Redpanda's log, in-cluster Postgres, Loki and Prometheus would be",
            "      unencrypted at rest on any account without EBS encryption-by-default.",
        )
    if not re.search(r'var\.create_storage_class\s*&&\s*var\.cloud_provider\s*==\s*"aws"', str(sc.body.get("count", ""))):
        fail(
            "FAIL: the platform default StorageClass is no longer created on AWS only;",
            "      on GCP GKE's own default class is adopted, and a second default",
            "      would be resolved arbitrarily.",
        )
    created_class = literal(default_of(tfconfig.variables(root / "platform/cloud/modules/platform/variables.tf"), "storage_class_name"))
    created_driver = literal(sc.body.get("storage_provisioner"))
    if not created_class or not created_driver:
        fail("FAIL: could not read the platform StorageClass's name/provisioner from Terraform")
    capabilities = (root / "cli/lib/cloud/sol_cli_provider_capabilities.ml").read_text()
    if f'storage_class = "{created_class}"' not in capabilities:
        fail(
            "FAIL: the Ready gate does not name the StorageClass Terraform creates",
            f"      ({created_class}); the two literals must agree.",
        )
    if f'csi_driver = "{created_driver}"' not in capabilities:
        fail(
            "FAIL: the Ready gate does not name the CSI driver the platform StorageClass",
            f"      uses ({created_driver}); the two literals must agree.",
        )


def check_deploy_rbac(root):
    deploy_rbac = root / "platform/cloud/modules/platform/platform_deploy_rbac.tf"
    if not deploy_rbac.is_file():
        fail(f"FAIL: {deploy_rbac} is missing")
    found = tfconfig.resources(deploy_rbac, kinds=("resource",))
    if find(found, "kubernetes_cluster_role", "sol_deploy") is None:
        fail("FAIL: kubernetes_cluster_role.sol_deploy not found")
    for binding in (r for r in found if r.type == "kubernetes_cluster_role_binding"):
        if "kubernetes_cluster_role.sol_deploy.metadata" in str(binding.body):
            fail(
                "FAIL: kubernetes_cluster_role.sol_deploy is bound by a ClusterRoleBinding --",
                "      it must only ever be bound per namespace, at runtime",
            )
    bootstrap = find(found, "kubernetes_cluster_role", "sol_deploy_bootstrap")
    if bootstrap is None:
        fail("FAIL: kubernetes_cluster_role.sol_deploy_bootstrap not found")
    namespace_rules = [verbs for resources, verbs, _ in rules(bootstrap) if set(resources) & NAMESPACE_KINDS]
    if not namespace_rules or any(set(v) != {"get", "list", "watch", "create"} for v in namespace_rules):
        fail(
            "FAIL: sol-deploy-bootstrap's namespaces/rolebindings rules are no longer",
            "      create-only; this identity must never patch/update/delete either kind.",
        )
    ca_reader = find(found, "kubernetes_role", "sol_kafka_ca_reader")
    if ca_reader is None:
        fail(
            "FAIL: kubernetes_role.sol_kafka_ca_reader not found;",
            "      the deploy identity cannot read the broker CA it must project (ADR 0008).",
        )
    ca_namespace = (tfconfig.blocks(ca_reader.body, "metadata") or [{}])[0].get("namespace")
    ca_rules = rules(ca_reader)
    ca_names = [literal(n) for values in tfconfig.attributes(ca_reader.body, "resource_names") for n in values]
    if (
        ca_namespace != "${kubernetes_namespace.redpanda.metadata[0].name}"
        or len(ca_rules) != 1
        or ca_rules[0][0] != ["secrets"]
        or ca_rules[0][1] != ["get"]
        or ca_names != ["redpanda-default-cert"]
    ):
        fail(
            "FAIL: the Kafka CA reader must grant exactly get on the",
            "      redpanda-default-cert Secret in the redpanda namespace",
        )
    for binding in (
        r for r in found if r.type in ("kubernetes_role_binding", "kubernetes_cluster_role_binding")
    ):
        for subject in tfconfig.blocks(binding.body, "subject"):
            kind = literal(subject.get("kind"))
            api_group = literal(subject.get("api_group"))
            if kind == "ServiceAccount" and api_group not in ("", None):
                fail(
                    "FAIL: a ServiceAccount RBAC subject carries apiGroup",
                    f"      {api_group!r}; Kubernetes requires an empty apiGroup for",
                    "      ServiceAccount subjects.",
                )
            if kind in ("User", "Group") and api_group != "rbac.authorization.k8s.io":
                fail(
                    "FAIL: a User/Group RBAC subject does not carry the RBAC apiGroup:",
                    f"      {binding.name}.{kind} has {api_group!r}.",
                )
    ca_binding = find(found, "kubernetes_role_binding", "sol_kafka_ca_reader")
    ca_binding_ok = ca_binding is not None and (
        (tfconfig.blocks(ca_binding.body, "metadata") or [{}])[0].get("namespace")
        == "${kubernetes_namespace.redpanda.metadata[0].name}"
        and any(
            r.get("name") == "${kubernetes_role.sol_kafka_ca_reader.metadata[0].name}"
            for r in tfconfig.blocks(ca_binding.body, "role_ref")
        )
        and any(literal(s.get("name")) == "sol:deployers" for s in tfconfig.blocks(ca_binding.body, "subject"))
    )
    if not ca_binding_ok:
        fail("FAIL: the Kafka CA reader Role is not bound to sol:deployers in redpanda")
    network_facts = root / "platform/cloud/modules/platform/platform_network_facts.tf"
    if not network_facts.is_file():
        fail(f"FAIL: {network_facts} is missing")
    network_binding = find(
        tfconfig.resources(network_facts, kinds=("resource",)),
        "kubernetes_role_binding",
        "network_facts",
    )
    if network_binding is None:
        fail("FAIL: kubernetes_role_binding.network_facts not found")
    network_subjects = tfconfig.blocks(network_binding.body, "subject")
    if not any(
        literal(subject.get("kind")) == "ServiceAccount"
        and literal(subject.get("name"))
        == "${kubernetes_service_account_v1.sol_deploy.metadata[0].name}"
        and literal(subject.get("namespace"))
        == "${kubernetes_service_account_v1.sol_deploy.metadata[0].namespace}"
        and literal(subject.get("api_group")) in ("", None)
        for subject in network_subjects
    ):
        fail(
            "FAIL: network_facts does not bind the deploy ServiceAccount;",
            "      the deploy identity cannot read the database-egress fact.",
        )
    lease = find(found, "kubernetes_role", "sol_boundary_lease")
    if lease is None:
        fail("FAIL: kubernetes_role.sol_boundary_lease not found")
    lease_namespace = literal((tfconfig.blocks(lease.body, "metadata") or [{}])[0].get("namespace"))
    lease_rules = rules(lease)
    lease_verbs = {v for _, verbs, _ in lease_rules for v in verbs}
    if (
        lease_namespace != "default"
        or not lease_rules
        or any(resources != ["configmaps"] for resources, _, _ in lease_rules)
        or lease_verbs != {"get", "create", "update", "delete"}
    ):
        fail(
            "FAIL: the boundary-lease Role must grant exactly get/create/update/delete",
            "      on ConfigMaps in the default namespace",
        )
    binding = find(found, "kubernetes_role_binding", "sol_boundary_lease")
    binding_ok = binding is not None and (
        literal((tfconfig.blocks(binding.body, "metadata") or [{}])[0].get("namespace")) == "default"
        and any(
            r.get("name") == "${kubernetes_role.sol_boundary_lease.metadata[0].name}"
            for r in tfconfig.blocks(binding.body, "role_ref")
        )
        and any(literal(s.get("name")) == "sol:deployers" for s in tfconfig.blocks(binding.body, "subject"))
    )
    if not binding_ok:
        fail("FAIL: the boundary-lease Role is not bound to sol:deployers in default")
    lease_impl = (root / "cli/lib/deploy/sol_cli_boundary_lease.ml").read_text()
    operations = sorted(
        {("get" if op == "get_if_present" else op) for op in re.findall(r"Sol_cli_kubectl\.([a-z_]*)", lease_impl)}
        - {"classify"}
    )
    if operations != ["create", "delete", "get", "replace"]:
        fail(
            f"FAIL: boundary-lease kubectl operations changed: {' '.join(operations)}",
            "      update the least-privilege Role and this explicit contract together",
        )
    bindable = [str(n) for r in found for names in tfconfig.attributes(r.body, "resource_names") for n in names]
    if not any("kubernetes_cluster_role.sol_deploy.metadata" in n for n in bindable):
        fail("FAIL: sol-deploy is no longer in the deploy bootstrap's bind allowlist")
    if not any("kubernetes_cluster_role.sol_operator_diagnostics.metadata" in n for n in bindable):
        fail(
            "FAIL: the operator's read-only ClusterRole is not in the deploy bootstrap's",
            "      bind allowlist, so the runtime substrate cannot create the operator's",
            "      RoleBinding (found live, before this was added).",
        )
    if any(literal(n) == "*" for r in found for names in tfconfig.attributes(r.body, "resource_names") for n in names):
        fail(
            "FAIL: the deploy bootstrap's bind allowlist uses a wildcard -- it could then",
            "      bind any ClusterRole.",
        )
    if any("escalate" in verbs for r in found for _, verbs, _ in rules(r)):
        fail(
            "FAIL: the deploy bootstrap grants escalate -- it could then grant any",
            "      permission, which dissolves the identity boundary.",
        )


def check_identities(root):
    aws_main = root / "platform/cloud/aws/cluster/main.tf"
    entries = [str(m.body.get("access_entries", "")) for m in tfconfig.modules(aws_main) if m.name == "eks"]
    if not any(re.search(r'var\.deploy_role_arn\s*==\s*""\s*\?\s*\{\}\s*:\s*\{', e) for e in entries):
        fail(
            "FAIL: the AWS root's access_entries no longer guards deploy_role_arn",
            "      being unset; an empty ARN must create no access entry.",
        )
    bootstrap_tf = root / "platform/cloud/aws/bootstrap/main.tf"
    found = tfconfig.resources(bootstrap_tf, kinds=("data",))
    provisioner = find(found, "aws_iam_policy_document", "provisioner")
    if provisioner is None:
        fail("FAIL: data.aws_iam_policy_document.provisioner not found")
    if not any(sid == "NoImagePublish" and effect == "Deny" and "ecr:PutImage" in actions for sid, effect, actions in statements(provisioner)):
        fail(
            "FAIL: the provisioner policy no longer explicitly denies ecr:PutImage",
            "      (and friends) -- ADR 0002's 'provisioner must not publish' boundary",
            "      would then rest on omission alone.",
        )
    publisher = find(found, "aws_iam_policy_document", "publisher")
    if publisher is None:
        fail("FAIL: data.aws_iam_policy_document.publisher not found")
    publisher_statements = statements(publisher)
    if not any(effect == "Allow" and "ecr:PutImage" in actions for _, effect, actions in publisher_statements):
        fail("FAIL: the publisher policy no longer grants ecr:PutImage")
    if not any(
        sid == "NoProvisionOrDeploy" and effect == "Deny" and {"eks:*", "iam:*"} <= set(actions)
        for sid, effect, actions in publisher_statements
    ):
        fail(
            "FAIL: the publisher policy no longer explicitly denies provisioning/IAM",
            "      mutation -- publishing an image must not also grant those.",
        )
    bootstrap_outputs = root / "platform/cloud/aws/bootstrap/outputs.tf"
    if not any("publisher_policy_json" in {tfconfig.unquote(n) for n in e} for e in tfconfig.load(bootstrap_outputs).get("output", [])):
        fail("FAIL: bootstrap root no longer outputs publisher_policy_json")
    provisioner_rbac = root / "platform/cloud/modules/platform/platform_provisioner_rbac.tf"
    if not provisioner_rbac.is_file():
        fail(f"FAIL: {provisioner_rbac} is missing")
    if any({"escalate", "bind", "*"} & set(verbs) for r in tfconfig.resources(provisioner_rbac, kinds=("resource",)) for _, verbs, _ in rules(r)):
        fail(
            "FAIL: the steady-state platform provisioner RBAC grants escalate/bind;",
            "      the deploy ClusterRole must be created inside the bootstrap-admin",
            "      window, not by widening the provisioner's standing authority.",
        )


def check_platform_roots(root):
    module_dir = root / "platform/cloud/modules/platform"
    if any(backends(tf) for tf in sorted(module_dir.glob("*.tf"))):
        fail(
            "FAIL: the shared platform module declares a backend; a module's backend is",
            "      ignored, so it would only mislead. Backends belong to the provider roots.",
        )
    if "s3" in backends(root / "platform/cloud/gcp/cluster/main.tf"):
        fail("FAIL: the GCP cloud root declares the S3 backend")
    definition = {name for tf in sorted(module_dir.glob("*.tf")) for name in tfconfig.variables(tf)}
    for provider, backend, may_omit in (("aws", "s3", set()), ("gcp", "gcs", GCP_MAY_OMIT)):
        directory = root / f"platform/cloud/{provider}/platform"
        vars_file = directory / "variables.tf"
        if not vars_file.is_file():
            fail(f"FAIL: {vars_file} is missing; the {provider} platform root has no variables")
        if backend not in backends(directory / "main.tf"):
            fail(
                f"FAIL: the {provider} platform root no longer declares the {backend} backend,",
                "      so Sol would initialize it with the wrong backend type.",
            )
        mirrored = set(tfconfig.variables(vars_file))
        unexpected = sorted((definition - mirrored) - may_omit - SYNTHESIZED_MODULE_INPUTS)
        if unexpected:
            fail(
                f"FAIL: the {provider} platform root does not mirror these declared variables:",
                *(f"      {v}" for v in unexpected),
                f"      Add them to platform/cloud/{provider}/platform, or to its exclusion list",
                f"      here with the reason they cannot apply to {provider}.",
            )
        extra = sorted(mirrored - definition)
        if extra:
            fail(
                f"FAIL: the {provider} platform root declares variables the shared definition",
                "      does not, so the module call cannot pass them:",
                *(f"      {v}" for v in extra),
            )
        passed = {
            key
            for module in tfconfig.modules(directory / "main.tf")
            for key, value in module.body.items()
            if tfconfig.variable_reference(value) == key
        }
        unpassed = sorted(mirrored - passed)
        if unpassed:
            fail(
                f"FAIL: the {provider} platform root declares but does not pass to the module:",
                *(f"      {v}" for v in unpassed),
            )


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    rds = check_aws_database(root)
    check_gcp_database(root)
    check_gcp_kafka(root)
    check_final_snapshot(rds)
    check_storage_class(root)
    check_deploy_rbac(root)
    check_identities(root)
    check_platform_roots(root)
    if shutil.which("terraform"):
        fmt = subprocess.run(["terraform", "fmt", "-check", "-recursive", str(root / "platform/cloud")], capture_output=True)
        if fmt.returncode != 0:
            fail("FAIL: platform/cloud is not terraform-fmt clean")
        print("production infra: precondition present, terraform fmt ok")
    else:
        print("production infra: precondition present (terraform not installed, skipped fmt)")


main()
