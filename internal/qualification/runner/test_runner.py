"""Offline mutations of the executable boundary; never contacts a cluster."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
declaration = (
    "sol-database-identity: target=qual/aws/us-east-1 resource=postgres "
    "namespace=payments ddl-creds=declared-ddl authority=declared-authority "
    "ca-configmap=declared-ca\n"
)


def configmap(namespace):
    return {"apiVersion": "v1", "kind": "ConfigMap",
            "metadata": {"namespace": namespace, "name": "declared-ca"},
            "ca_present": True}


def deployment(namespace, name):
    return {"apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {"namespace": namespace, "name": name},
            "spec": {"template": {"spec": {"volumes": [
                {"name": "db-ca", "configMap": {"name": "declared-ca"}}
            ]}}}}


baseline = {
    "configmap/payments/declared-ca": configmap("payments"),
    "configmap/comms/declared-ca": configmap("comms"),
    "deployment/payments/service": deployment("payments", "service"),
    "deployment/comms/worker": deployment("comms", "worker"),
}

# The executable adapter implements Kubernetes reads, not verdicts. Verify argv
# boundaries and identity explicitly so fixture success cannot bypass the runner.
adapter = '''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
assert args[:2] == ["--kubeconfig", "explicit identity"], args
assert args[2] == "get" and args[5] == "--namespace", args
assert args[7:9] == ["--ignore-not-found=true", "-o"], args
assert args[9].startswith("go-template="), args
assert ".data" not in args[9] or 'index .data "ca.crt"' in args[9], args
assert ".containers" not in args[9], args
data = json.loads(Path(os.environ["QUAL_FIXTURE"]).read_text())
key = "/".join([args[3], args[6], args[4]])
obj = data[key]
if isinstance(obj, dict) and "_mode" in obj:
    mode = obj["_mode"]
    if mode == "denied":
        print("Forbidden: original provider diagnostic", file=sys.stderr)
        sys.exit(1)
    if mode == "timeout":
        print("partial provider diagnostic", file=sys.stderr, flush=True)
        subprocess.Popen([sys.executable, "-c",
            "import pathlib,time; time.sleep(1); pathlib.Path(" +
            repr(os.environ["QUAL_CHILD_MARKER"]) + ").write_text('survived')"])
        time.sleep(30)
    if mode == "malformed":
        print("not JSON")
        sys.exit(0)
if obj is not None:
    print(json.dumps(obj))
'''

count = 0
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    executable = root / "observer with spaces"
    executable.write_text(adapter)
    executable.chmod(0o700)
    fixture = root / "fixture.json"
    log = root / "deploy.log"

    def run(data=None, text=declaration, consumers=("payments/service", "comms/worker"),
            expected=1, extra=()):
        global count
        count += 1
        fixture.write_text(json.dumps(baseline if data is None else data))
        log.write_text(text)
        evidence = root / f"evidence-{count}"
        args = [str(binary), "--deploy-log", str(log), "--target", "qual/aws/us-east-1",
                "--kubeconfig", "explicit identity", "--kubectl", str(executable),
                "--evidence", str(evidence), "--timeout", "2"]
        for consumer in consumers:
            args += ["--consumer", consumer]
        result = subprocess.run(args + list(extra), capture_output=True, text=True,
                                env={**os.environ, "QUAL_FIXTURE": str(fixture),
                                     "QUAL_CHILD_MARKER": str(root / "child-marker")}, timeout=8)
        assert result.returncode == expected, (result.stdout, result.stderr, expected)
        report = json.loads((evidence / "report.json").read_text()) if expected != 2 else None
        if report is not None:
            assert report["passed"] == (expected == 0)
            assert (evidence.stat().st_mode & 0o777) == 0o700
            for path in evidence.iterdir():
                assert (path.stat().st_mode & 0o777) == 0o600
        return evidence, report, args

    def verdicts(report):
        return {claim["id"]: claim["result"]["verdict"] for claim in report["claims"]}

    evidence, report, args = run(expected=0)
    assert len(report["claims"]) == 6
    assert set(verdicts(report).values()) == {"PASS"}
    assert report["target"] == "qual/aws/us-east-1"
    assert report["kubeconfig"] == "explicit identity"
    assert len(report["observations"]) == 4
    for observation in report["observations"]:
        execution = json.loads((evidence / observation["execution"]).read_text())
        assert execution["status"] == {"exit_code": 0}
        assert execution["finished_at"] >= execution["started_at"]
        assert (evidence / execution["stdout"]).exists()
        assert (evidence / execution["stderr"]).exists()
    # Existing evidence cannot be overwritten, even after a successful run.
    before = (evidence / "report.json").read_bytes()
    refused = subprocess.run(args, capture_output=True, timeout=8)
    assert refused.returncode == 2
    assert (evidence / "report.json").read_bytes() == before

    # Positive missing object versus unreadable observation remain distinct.
    for key in baseline:
        for mode, verdict in [(None, "FAIL"), ({"_mode": "denied"}, "UNKNOWN"),
                              ({"_mode": "malformed"}, "UNKNOWN")]:
            data = copy.deepcopy(baseline)
            data[key] = mode
            evidence, report, _ = run(data)
            assert verdict in verdicts(report).values(), (key, mode, report)
            assert len(list(evidence.glob("command-*.json"))) == 4
            if mode == {"_mode": "denied"}:
                assert any("Forbidden: original provider diagnostic" in path.read_text()
                           for path in evidence.glob("*.stderr"))

    for namespace in ("payments", "comms"):
        data = copy.deepcopy(baseline)
        data[f"configmap/{namespace}/declared-ca"]["ca_present"] = False
        _, report, _ = run(data)
        assert verdicts(report)[f"database-ca/configmap/{namespace}"] == "FAIL"

    for mutation in ("wrong-ca", "wrong-volume", "no-volumes", "wrong-identity"):
        data = copy.deepcopy(baseline)
        obj = data["deployment/comms/worker"]
        if mutation == "wrong-ca":
            obj["spec"]["template"]["spec"]["volumes"][0]["configMap"]["name"] = "other-ca"
        elif mutation == "wrong-volume":
            obj["spec"]["template"]["spec"]["volumes"][0]["name"] = "other-volume"
        elif mutation == "no-volumes":
            obj["spec"]["template"]["spec"]["volumes"] = []
        else:
            obj["metadata"]["namespace"] = "other-namespace"
        _, report, _ = run(data)
        expected = "UNKNOWN" if mutation == "wrong-identity" else "FAIL"
        assert verdicts(report)["database-ca/deployment/comms/worker"] == expected

    for text in ("", declaration.replace("ca-configmap=declared-ca", ""),
                 declaration + declaration.replace("qual/aws/us-east-1", "another-target"),
                 declaration.replace("resource=postgres", "namespace=duplicate"),
                 declaration.replace("ca-configmap=declared-ca", "ca-configmap=")):
        evidence, report, _ = run(text=text)
        assert verdicts(report)["database-ca/declaration"] == "UNKNOWN"
        assert "NOT_RUN" in verdicts(report).values()
        assert not list(evidence.glob("command-*.json"))

    _, report, _ = run(consumers=())
    assert verdicts(report)["database-ca/selection"] == "FAIL"

    # The writer's declared namespace is not assumed to be a consumer namespace.
    data = copy.deepcopy(baseline)
    data["configmap/setup/declared-ca"] = configmap("setup")
    _, report, _ = run(data, text=declaration.replace("namespace=payments", "namespace=setup"),
                       expected=0)
    assert verdicts(report)["database-ca/configmap/setup"] == "PASS"

    data = copy.deepcopy(baseline)
    data["configmap/comms/declared-ca"] = {"_mode": "timeout"}
    evidence, report, _ = run(data, extra=("--timeout", "0.3"))
    assert verdicts(report)["database-ca/configmap/comms"] == "UNKNOWN"
    assert any("partial provider diagnostic" in path.read_text()
               for path in evidence.glob("*.stderr"))
    assert any(json.loads(path.read_text())["status"] == "TIMEOUT"
               for path in evidence.glob("command-*.json"))
    # By now the other reads have completed. Give a mistakenly surviving descendant
    # its full opportunity to write, independently of the command parent's status.
    import time
    time.sleep(1.1)
    assert not (root / "child-marker").exists()

    run(extra=("--timeout", "nan"), expected=2)
    run(extra=("--timeout", "0"), expected=2)
    run(extra=("--timeout", "0.000000001"))
    run(extra=("--kubectl", str(root / "missing-observer")))

print(f"{count} offline runner scenarios passed")
