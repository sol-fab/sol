#!/usr/bin/python3
"""Run literal legacy functions in an isolated, offline process, not preflight."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

source, provider, world_path, directory = map(Path, sys.argv[1:])
provider = str(provider)
text = source.read_text()

def function(name):
    matches = list(re.finditer(r"^" + re.escape(name) + r"\(\) \{", text, re.M))
    if len(matches) != 1:
        raise RuntimeError("missing/ambiguous legacy function: " + name)
    start = matches[0].start()
    first_end = text.find("\n", start)
    # These known sources use either a one-line definition or a top-level
    # closing brace. This is deliberately not a reusable shell parser.
    if text[start:first_end].rstrip().endswith("}"):
        return text[start:first_end]
    end = re.search(r"^\}", text[first_end:], re.M)
    if end is None:
        raise RuntimeError("unterminated legacy function: " + name)
    return text[start:first_end + end.end()]

names = ["app_database_declaration", "app_database_field", "app_class_credential_name",
         "app_namespaces", "app_verify_database_delivery"]
if provider == "aws":
    names += ["unit_dir", "k8s_name", "app_unit_addresses", "app_verify_database_ca"]
elif provider == "gcp":
    names += ["app_services", "app_context_path"]
else:
    raise RuntimeError("unknown provider")
functions = "\n\n".join(function(name) for name in names)
world = json.loads(world_path.read_text())
if provider == "aws":
    default = re.search(r'^APP_UNITS="\$\{APP_UNITS:-([^}]+)\}"$', text, re.M)
    if default is None or default.group(1).split() != world["legacy"]["default_units"]:
        raise RuntimeError("AWS default selection changed; review comparison specimen")
script = "set -uo pipefail\n" + functions + "\nsay() { printf '%s\\n' \"$*\"; }\n"
selector = "app_unit_addresses" if provider == "aws" else "app_services"
script += selector + ' >"$HOME/selection.txt" || exit 125\n'
script += 'app_verify_database_ca "$DECLARED_NS"\n' if provider == "aws" and world["legacy"].get("ca_only") else "app_verify_database_delivery\n"
(directory / "extracted.sh").write_text(script)
subprocess.run(["/bin/bash", "-n", str(directory / "extracted.sh")], check=True)
# Deliberately exclude inherited credentials, BASH_ENV, HOME and cloud tools.
# The private PATH contains the fixture kubectl and only the text tools needed by
# these exact functions. There is no fallback to a host kubectl/aws/gcloud.
env = {"PATH": str(directory / "bin"), "HOME": str(directory),
       "LC_ALL": "C", "I4_WORLD": str(world_path),
       "I4_CALLS": str(directory / "legacy-calls.jsonl"),
       "WORKSPACE": str(directory / "workspace"), "LOG_DIR": str(directory / "logs"),
       "DEPLOY_KUBECONFIG": str(directory / "offline-kubeconfig"),
       **world["legacy"]["env"]}
result = subprocess.run(["/bin/bash", str(directory / "extracted.sh")], env=env,
                        stdin=subprocess.DEVNULL, capture_output=True, text=True,
                        timeout=10, cwd=directory)
print(json.dumps({"status": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
                  "selected": (directory / "selection.txt").read_text().split(),
                  "source_sha256": hashlib.sha256(text.encode()).hexdigest(), "functions": names}))
