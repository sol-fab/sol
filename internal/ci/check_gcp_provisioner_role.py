import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

ROOT = Path(__file__).resolve().parents[2]
ALLOWED = {
    "container.clusters.get",
    "container.clusters.list",
    "container.clusters.getCredentials",
    "container.clusters.connect",
    "container.serviceAccounts.createToken",
}
OBJECT_AUTHORITY = re.compile(
    r"^container\.(deployments|pods|namespaces|jobs|secrets|configMaps|clusterRoles|roleBindings)\."
)


def fail(message):
    sys.exit(f"check_gcp_provisioner_role: {message}")


def strings(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)
    elif isinstance(node, str):
        yield node


def main():
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "platform/cloud/gcp/cluster/main.tf"
    found = tfconfig.resources(source)
    role = next(
        (r for r in found if r.type == "google_project_iam_custom_role" and r.name == "provisioner_cluster_access"),
        None,
    )
    if role is None:
        fail("custom provisioner role is missing")
    if any("roles/container.developer" in s for r in found for s in strings(r.body)):
        fail("predefined roles/container.developer grant is present")
    permissions = [tfconfig.unquote(p) for p in role.body.get("permissions", [])]
    for permission in sorted(ALLOWED):
        if permission not in permissions:
            fail(f"custom role is missing {permission}")
    if any(OBJECT_AUTHORITY.match(p) for p in permissions):
        fail("custom role grants Kubernetes-object authority")
    if {p for p in permissions if p.startswith("container.")} != ALLOWED:
        fail("custom role contains a container permission outside the narrow allowlist")
    print("check_gcp_provisioner_role: provisioner IAM is discovery/credential/token-only")


main()
