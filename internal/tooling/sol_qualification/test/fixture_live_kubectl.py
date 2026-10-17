#!/usr/bin/python3
"""Process fixture for the actual kubectl invocation boundary; no provider calls."""
import json
import os
import re
from pathlib import Path
import sys
import time

args = sys.argv[1:]
world = json.loads(Path(os.environ["SOL_TEST_WORLD"]).read_text())
state_path = Path(os.environ["SOL_TEST_CALLS"])
state = json.loads(state_path.read_text()) if state_path.exists() else {"calls": []}
assert args[:2] == ["--context", "explicit-observer"]
assert os.environ["KUBECONFIG"] == os.environ["SOL_TEST_KUBECONFIG"]
args = args[2:]
state["calls"].append(args)
key = args[0]
state[key] = state.get(key, 0) + 1
state_path.write_text(json.dumps(state))
if args[0] == "apply":
    document = Path(args[2]).read_text()
    kind = re.search(r"^kind: (\w+)$", document, re.M).group(1)
    name = re.search(r"^  name: ([^\n]+)$", document, re.M).group(1)
    namespace = re.search(r"^  namespace: ([^\n]+)$", document, re.M).group(1)
    if kind == "Job" and world.get("apply_error"):
        print("Forbidden DISTINCTIVE_PROCESS_SECRET", file=sys.stderr)
        sys.exit(1)
    if kind == "Job" and args[-2:] == ["-o", "json"]:
        value = json.loads(Path(world["jobs"]).read_text())
        value["metadata"].update({"name": name, "namespace": namespace})
        if world.get("missing_uid"):
            del value["metadata"]["uid"]
        if world.get("wrong_submission_namespace"):
            value["metadata"]["namespace"] = "another-namespace"
        Path(world["submitted_job"]).write_text(json.dumps(value))
    else:
        print(kind + "/" + name + " configured")
        sys.exit(0)
elif args[0] == "create":
    print("created")
    sys.exit(0)
elif args[0] == "logs":
    print("migration fixture completed")
    sys.exit(0)
elif args[0] == "delete":
    if args[1] == "job" and world.get("submitted_job"):
        Path(world["submitted_job"]).unlink(missing_ok=True)
    print("deleted")
    sys.exit(0)
elif args[:2] == ["get", "job"]:
    print("1")
    sys.exit(0)
elif args[:2] == ["config", "view"]:
    value = world.get("after_config", world["config"]) if state["config"] > 1 else world["config"]
elif args[:2] == ["auth", "whoami"]:
    if state["auth"] > 1 and world.get("expired"):
        print("Unauthorized DISTINCTIVE_PROCESS_SECRET", file=sys.stderr)
        sys.exit(1)
    value = world.get("after_whoami", world["whoami"]) if state["auth"] > 1 else world["whoami"]
elif args[:2] == ["auth", "can-i"]:
    # Collection reads require list. With deny_reads, model get-only authority:
    # the former get preflight would pass even though the observation cannot.
    allowed = (args[2] == "list" and not world.get("deny_reads")) or (
        args[2] == "get" and world.get("deny_reads"))
    print("yes" if allowed else "no")
    sys.exit(0)
elif args[:3] == ["get", "namespace", "kube-system"]:
    n = sum(1 for call in state["calls"] if call[:3] == args[:3])
    value = world.get("after_cluster", world["cluster"]) if n > 1 else world["cluster"]
else:
    assert args[0] == "get" and args[-2:] == ["-o", "json"]
    assert args[2] == "--namespace" and args[4] == "--field-selector"
    assert args[5].startswith("metadata.name=")
    if world.get("sleep"):
        time.sleep(16)
    if world.get("read_error"):
        print('{"apiVersion":"v1","kind":"ConfigMapList","metadata":{"resourceVersion":"1"},"items":[]}')
        print("Forbidden DISTINCTIVE_PROCESS_SECRET", file=sys.stderr)
        sys.exit(world["read_error"])
    if world.get("malformed"):
        print("not JSON DISTINCTIVE_PROCESS_SECRET")
        sys.exit(0)
    resource = args[1]
    names = {"deployments.apps": "deployments", "configmaps": "configmaps", "jobs.batch": "jobs"}
    source = world[names[resource]]
    if resource == "jobs.batch" and world.get("submitted_job") and Path(world["submitted_job"]).exists():
        source = world["submitted_job"]
    value = json.loads(Path(source).read_text())
    if resource == "jobs.batch" and value.get("kind") == "Job":
        value = {"apiVersion": "batch/v1", "kind": "JobList",
                 "metadata": {"resourceVersion": "24"}, "items": [value]}
    if resource == "configmaps" and value.get("kind") == "ConfigMap":
        value = {"apiVersion": "v1", "kind": "ConfigMapList",
                 "metadata": {"resourceVersion": "24"}, "items": [value]}
    if isinstance(value, dict) and "items" in value:
        value["items"] = [item for item in value["items"]
            if item["metadata"]["namespace"] == args[3] and item["metadata"]["name"] == args[5].split("=", 1)[1]]
        if world.get("partial"):
            value["metadata"]["continue"] = "more"
    if world.get("missing_ca") and resource == "configmaps":
        value["items"] = []
    if world.get("wrong_ca") and resource == "deployments.apps":
        for item in value["items"]:
            for volume in item["spec"]["template"]["spec"]["volumes"]:
                if "configMap" in volume:
                    volume["configMap"]["name"] = "another-ca"
print(json.dumps(value))
