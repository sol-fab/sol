#!/usr/bin/env python3
"""Offline declaration binding; no verdict, policy selection, or provider access.

The existing sol-under-test owner verifies the whole installed candidate before
this tool can invoke its internal producer. This additional check requires the
new files to be archive members (an unrecorded extra executable is insufficient).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field: " + key)
        result[key] = value
    return result


def unsupported_number(value):
    raise ValueError("unsupported declaration number: " + value)


def load(text):
    return json.loads(text, object_pairs_hook=unique_object,
                      parse_float=unsupported_number, parse_constant=unsupported_number)


def declaration(document):
    if not isinstance(document, dict) or set(document) != {"digest", "declaration"}:
        raise ValueError("missing declaration/digest")
    value = document["declaration"]
    if not isinstance(value, dict) or type(value.get("schema")) is not int or value.get("schema") != 1:
        raise ValueError("unsupported declaration schema")
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    if hashlib.sha256(canonical).hexdigest() != document["digest"]:
        raise ValueError("declaration digest mismatch")
    return value


def bind(candidate_path, install, target, workspace):
    candidate = load(candidate_path.read_text())
    # Consume the established candidate/installed-bytes verification owner unchanged.
    owner = Path(__file__).with_name("sol-under-test.sh")
    subprocess.run(["/bin/bash", "-c", 'source "$1"; SOL_INSTALL="$2"; SOL_CANDIDATE="$3"; sol_under_test_resolve',
                    "database-contract-binding", str(owner), str(install), str(candidate_path)],
                   check=True, stdin=subprocess.DEVNULL)
    version = candidate["version"]
    prefix = "sol-" + version + "/"
    definition_rel = "share/sol/" + version + "/database-contract.json"
    producer_rel = "bin/sol-database-contract"
    with tarfile.open(candidate_path.parent / candidate["bundle"]) as archive:
        for relative in (producer_rel, definition_rel):
            matches = [member for member in archive.getmembers() if member.name == prefix + relative]
            if len(matches) != 1 or not matches[0].isfile():
                raise ValueError("candidate lacks a unique regular projection member: " + relative)
    document = load((install / definition_rel).read_text())
    definition = declaration(document)
    if definition.get("product_revision") != candidate["revision"]:
        raise ValueError("declaration is from another product revision")
    producer_env = dict(os.environ)
    producer_env.pop("SOL_HOME", None)
    result = subprocess.run([str(install / producer_rel), "specimen", str(install / definition_rel), target],
                            cwd=workspace, env=producer_env, timeout=30, check=True, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True)
    projection = load(result.stdout)
    value = declaration(projection)
    # Structural completeness only; applicability and truth belong to qualification.
    if (not isinstance(value.get("workloads"), list) or not value["workloads"] or
            not isinstance(value.get("workspace"), str) or not value["workspace"] or
            not isinstance(value.get("target"), str) or not value["target"] or
            "database" not in value or
            (value["database"] is not None and not isinstance(value["database"], dict))):
        raise ValueError("missing or malformed specimen declaration")
    if (value.get("product_revision") != candidate["revision"] or
            value.get("definition_digest") != document["digest"] or value.get("requested_target") != target):
        raise ValueError("specimen declaration binding mismatch")
    return {"candidate": {key: candidate[key] for key in ("version", "revision", "bundle_sha256", "runner_image")},
            "definition": document, "specimen": projection}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--install", required=True, type=Path)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(bind(args.candidate.resolve(), args.install.resolve(), args.target,
                              args.workspace.resolve()), sort_keys=True, separators=(",", ":")))
    except subprocess.TimeoutExpired:
        print("database contract: producer timed out", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        print("database contract: candidate verification or producer failed", file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print("database contract: " + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
