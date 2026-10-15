#!/usr/bin/env python3
import re
import sys
from pathlib import Path

NAME = "check_resource_identity"

EXPECTED_TYPE_RULES = ["kubernetes_", "helm_", "terraform_data", "random_", "null_resource"]

ENTRY = re.compile(
    r'entry\s+"(?P<address>[a-z0-9_]+\.[a-z0-9_]+)(?P<key>\[[^\]]*\])?"\s+'
    r"\(?(?P<ownership>[A-Za-z_]+)"
)
IMPORT = re.compile(r'~import_identity:\s*(?P<value>"[^"]*"|[^\n;]*)')
CLASS = re.compile(r'~resource_class:\s*(?P<value>"[^"]*")')
OBSERVED = re.compile(r'~observed_as:\s*(?P<value>"[^"]*"|[^\n;]*)')
TYPE_RULE = re.compile(r'terraform_type\s*=\s*"(?P<value>[^"]*)"')
CLASS_NAMES = re.compile(r'class_names\s*=\s*\[(?P<body>[^\]]*)\]', re.S)
CLASS_NAME = re.compile(r'"(?P<value>[^"]+)"')


def unquote(value):
    return value.strip().strip('"') if value else ""


def registry(path):
    text = path.read_text() if path.exists() else ""
    entries = {}
    for match in ENTRY.finditer(text):
        window = text[match.end() :]
        following = window.find("; entry")
        if following != -1:
            window = window[:following]
        window = window[:600]
        import_match = IMPORT.search(window)
        class_match = CLASS.search(window)
        observed_match = OBSERVED.search(window)
        entries[match.group("address")] = {
            "address": match.group("address") + (match.group("key") or ""),
            "ownership": match.group("ownership").lower(),
            "import_identity": unquote(import_match.group("value")) if import_match else "",
            "resource_class": unquote(class_match.group("value")) if class_match else "",
            "observed_as": unquote(observed_match.group("value")) if observed_match else "",
        }
    type_rules = [m.group("value") for m in TYPE_RULE.finditer(text)]
    return text, entries, type_rules


def inventory_classes(path):
    text = path.read_text() if path.exists() else ""
    match = CLASS_NAMES.search(text)
    if not match:
        return []
    return [m.group("value") for m in CLASS_NAME.finditer(match.group("body"))]


def root_addresses(root):
    found = []
    for tf in sorted(root.glob("*.tf")):
        text = tf.read_text()
        for match in re.finditer(
            r'^resource\s+"(?P<type>[a-z0-9_]+)"\s+"(?P<name>[a-z0-9_]+)"', text, re.M
        ):
            found.append(f'{match.group("type")}.{match.group("name")}')
    return found


def root_instance_keys(root):
    """Addresses whose resource block declares count/for_each, with the kind of key.

    A counted or for_each'd resource has an indexed Terraform address. A registry entry
    that names the bare resource cannot be resolved by `terraform import` (it fails with
    "Configuration for import target does not exist") and cannot match a state read, so a
    Direct entry for such a resource must carry the instance key (#1476)."""
    keys = {}
    for tf in sorted(root.glob("*.tf")):
        text = tf.read_text()
        for match in re.finditer(
            r'^resource\s+"(?P<type>[a-z0-9_]+)"\s+"(?P<name>[a-z0-9_]+)"\s*\{(?P<body>.*?)^\}',
            text,
            re.M | re.S,
        ):
            body = match.group("body")
            if re.search(r"^\s*count\s*=", body, re.M):
                kind = "count"
            elif re.search(r"^\s*for_each\s*=", body, re.M):
                kind = "for_each"
            else:
                continue
            keys[f'{match.group("type")}.{match.group("name")}'] = kind
    return keys


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(".")
    registry_path = root / "cli/lib/cloud/sol_cli_resource_identity.ml"
    text, entries, type_rules = registry(registry_path)
    problems = []
    if not entries:
        problems.append(f"the identity registry could not be read at {registry_path}")
    if sorted(type_rules) != sorted(EXPECTED_TYPE_RULES):
        problems.append(
            "the registry must carry the class-level rules for Terraform-internal and in-cluster "
            f"families: expected {EXPECTED_TYPE_RULES}, read {type_rules}"
        )

    declared = {}
    instance_keys = {}
    checked = 0
    for provider in ("gcp", "aws"):
        for tf_root in (
            root / f"platform/cloud/{provider}/cluster",
            root / "platform/cloud/modules/platform",
        ):
            if tf_root.exists():
                declared.setdefault(provider, set()).update(root_addresses(tf_root))
                instance_keys.setdefault(provider, {}).update(root_instance_keys(tf_root))

    for provider, addresses in sorted(declared.items()):
        for address in sorted(addresses):
            checked += 1
            terraform_type = address.split(".")[0]
            entry = entries.get(address)
            if entry is None:
                if any(terraform_type.startswith(rule) for rule in type_rules):
                    continue
                problems.append(
                    f"{provider}: {address} is declared by a root but the identity registry does "
                    "not account for it: every directly Terraform-managed resource must declare "
                    "how it is rediscovered at the provider, or fall under a class-level "
                    "ownership rule (FND-0070)"
                )
                continue
            kind = instance_keys.get(provider, {}).get(address)
            if kind is not None and entry["ownership"] == "direct":
                key = re.search(r"(\[[^\]]*\])$", entry["address"])
                if key is None:
                    problems.append(
                        f"the registry entry {entry['address']} is Direct and its Terraform "
                        f"resource declares {kind}, so the address must name an instance: "
                        "`terraform import` resolves the address against the configuration and a "
                        "counted or for_each'd resource has no bare address (#1476)"
                    )
                elif kind == "count" and key.group(1) != "[0]":
                    problems.append(
                        f"the registry entry {entry['address']} is Direct and counted, so its "
                        f"instance key must be [0], not {key.group(1)}: count is a 0/1 enable "
                        "flag here and the import address is the one the state read reports "
                        "(#1476)"
                    )
            if entry["ownership"] == "direct":
                if entry["import_identity"] == "":
                    problems.append(
                        f"the registry entry for {entry['address']} is Direct, so it must carry an "
                        "~import_identity: the provider identity Sol would import to restore "
                        "Terraform ownership of an unadopted resource (FND-0070)"
                    )
                if entry["observed_as"] == "":
                    problems.append(
                        f"the registry entry for {entry['address']} is Direct, so it must carry an "
                        "~observed_as: the provider name the independent inventory reports, "
                        "which is how a found resource is mapped back to this address (FND-0070)"
                    )

    for provider, addresses in sorted(declared.items()):
        for address in sorted(entries):
            if address not in addresses and address not in {
                a for other in declared.values() for a in other
            }:
                problems.append(
                    f"the identity registry names {address}, which no provider root or the shared "
                    "platform module declares: a stale entry passes off a resource Sol does not "
                    "have (FND-0070)"
                )

    compared = set()
    for provider in ("gcp", "aws"):
        path = root / f"cli/lib/cloud/sol_cli_{provider}_absence.ml"
        compared.update(inventory_classes(path))
    for address, entry in sorted(entries.items()):
        resource_class = entry["resource_class"]
        if resource_class and resource_class not in compared:
            problems.append(
                f"the registry entry for {address} names the class {resource_class!r}, which no "
                "provider inventory reports: the inventory maps what it finds back to an address "
                "by class and name, so a class it never reports cannot be matched (FND-0070)"
            )

    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        return 1
    print(
        f"{NAME}: {checked} declared terraform resource(s) carry an ownership kind, every Direct "
        "one an import identity and the provider name the inventory reports, no stale entry, and "
        "every class a mapping names is one an inventory reports"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
