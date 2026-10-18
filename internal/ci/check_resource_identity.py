#!/usr/bin/env python3
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
import tfconfig

NAME = "check_resource_identity"

EXPECTED_TYPE_RULES = ["kubernetes_", "helm_", "terraform_data", "random_", "null_resource"]

ENTRY = re.compile(
    r'entry\s+"(?P<address>(?:module\.[a-z0-9_]+\.)*[a-z0-9_]+\.[a-z0-9_]+)(?P<key>\[[^\]]*\])?"\s+'
    r"\(?(?P<ownership>[A-Za-z_]+)"
)
IMPORT = re.compile(r'~import_identity:\s*(?P<value>"[^"]*"|[^\n;]*)')
CLASS = re.compile(r'~resource_class:\s*(?P<value>"[^"]*")')
OBSERVED = re.compile(r'~observed_as:\s*(?P<value>"[^"]*"|[^\n;]*)')
TYPE_RULE = re.compile(r'terraform_type\s*=\s*"(?P<value>[^"]*)"')


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
    indexed_modules = {}
    checked = 0
    for provider in ("gcp", "aws"):
        for tf_root in (
            root / f"platform/cloud/{provider}/cluster",
            root / "platform/cloud/modules/platform",
        ):
            if tf_root.exists():
                try:
                    resources = tfconfig.native_resources(tf_root, boundary=root / "platform/cloud")
                except (OSError, ValueError) as error:
                    problems.append(str(error))
                    continue
                declared.setdefault(provider, set()).update(r.address for r in resources)
                for r in resources:
                    for kind in ("count", "for_each"):
                        if kind in r.body:
                            instance_keys.setdefault(provider, {})[r.address] = kind
                    if r.indexed_module:
                        indexed_modules.setdefault(provider, set()).add(r.address)

    for provider, addresses in sorted(declared.items()):
        for address in sorted(addresses):
            checked += 1
            terraform_type = address.split(".")[-2]
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
            if entry["ownership"] == "direct" and address in indexed_modules.get(provider, set()):
                problems.append(
                    f"{provider}: {address} is Direct beneath a counted or for_each module; "
                    "recovery requires an explicit module-instance policy, not a guessed address"
                )
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
                        f"instance key must be [0], not {key.group(1)}: every counted resource "
                        "in these roots is a zero-or-one enable flag, so [0] is the only "
                        "instance and the import address must be the one the state read "
                        "reports (#1476). This checker models that singleton contract, not "
                        "arbitrary counted collections"
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

    # Executable probe coverage is checked against these recovery mappings by the
    # compiled CLI tests. Source text cannot establish which probes actually run.

    if problems:
        for problem in problems:
            print(f"{NAME}: {problem}", file=sys.stderr)
        return 1
    print(
        f"{NAME}: {checked} declared terraform resource(s) carry an ownership kind, every Direct "
        "one an import identity and the provider name the inventory reports, no stale entry, and "
        "compiled CLI tests independently check executable observation coverage"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
