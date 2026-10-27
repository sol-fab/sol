import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = REPO / "internal/ci/check_gcp_standard_substrate.py"
CLUSTER = "platform/cloud/gcp/cluster/main.tf"
CONTRACT = "cli/lib/workspace/sol_cli_config.ml"


def substitute(pattern, replacement, flags=0):
    def mutate(root):
        path = root / CLUSTER
        text, n = re.subn(pattern, replacement, path.read_text(), count=1, flags=flags)
        assert n == 1, "the mutation anchor did not match"
        path.write_text(text)
    return mutate


def remove_node_pool(root):
    path = root / CLUSTER
    text = path.read_text()
    begin = text.index('resource "google_container_node_pool"')
    finish = text.index("\n}\n", begin) + len("\n}\n")
    path.write_text(text[:begin] + text[finish:])


def drop_disk_default(root):
    path = root / "platform/cloud/gcp/cluster/variables.tf"
    text, n = re.subn(
        r'(variable "node_disk_gb" \{[^}]*?)\n\s*default\s*=\s*[^\n]+', r"\1", path.read_text(), count=1
    )
    assert n == 1, "the mutation anchor did not match"
    path.write_text(text)


def sizing_in_contract(root):
    with open(root / CONTRACT, "a", encoding="utf-8") as f:
        f.write("\ntype node_pool = { node_count : int; node_machine_type : string }\n")


CASES = [
    ("autopilot-requested", substitute(
        r"^(\s*)remove_default_node_pool\s*=\s*true\s*$",
        r"\1enable_autopilot = true\n\1remove_default_node_pool = true", re.M)),
    ("autopilot-becomes-a-knob", substitute(
        r"^(\s*)remove_default_node_pool\s*=\s*true\s*$",
        r"\1enable_autopilot = var.enable_autopilot\n\1remove_default_node_pool = true", re.M)),
    ("node-pool-removed", remove_node_pool),
    ("machine-type-hard-coded", substitute(
        r"machine_type\s*=\s*var\.node_machine_type", 'machine_type = "e2-standard-2"')),
    ("sizing-became-target-configuration", sizing_in_contract),
    ("one-sizing-default-removed", drop_disk_default),
    ("cluster-zone-list-dropped", substitute(
        r'\n\s*node_locations = local\.node_zones\n', "\n")),
    ("node-zone-hardcoded", substitute(
        r'node_locations = local\.node_zones', 'node_locations = ["us-east1-a"]')),
    ("control-plane-became-zonal", substitute(
        r"location\s*=\s*var\.region", 'location = "${var.region}-a"')),
]


def tree(scratch, name):
    root = scratch / name
    for rel in (CLUSTER, "platform/cloud/gcp/cluster/variables.tf", CONTRACT, CONTRACT + "i"):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / rel, root / rel)
    return root


def snapshot(root):
    return sorted((p, p.read_bytes()) for p in root.rglob("*") if p.is_file())


def verdict(root):
    run = subprocess.run([sys.executable, str(GUARD), str(root)], capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def main():
    print("check_gcp_standard_substrate mutations")
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
            first = next((l for l in output.splitlines() if l.startswith("FAIL")), "")
            print(f"  rejected: {name} -- {first[:90]}")
        rc, output = verdict(tree(Path(scratch), "real-tree"))
        if rc != 0:
            sys.exit(f"FAIL: the guard rejected the unmutated tree (real-tree):\n{output}")
        print("  accepted: real-tree (unmutated)")
    print("check_gcp_standard_substrate: all mutations rejected, unmutated tree accepted")


main()
