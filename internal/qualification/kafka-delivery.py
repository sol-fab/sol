#!/usr/bin/env python3
"""Read-only comparison of provider authority, broker input and workload projections.

No credential is written, hashed, printed, or passed as an argument. The existing
application transaction separately proves broker authentication and message flow.
"""
import argparse
import base64
import json
import subprocess
import sys


class ObservationError(ValueError):
    """Only messages constructed here from safe context, never provider values."""


def read(argv, *, binary=False):
    result = subprocess.run(argv, capture_output=True, timeout=60)
    if result.returncode:
        # stdout/stderr can contain the credential, even on a failed read.
        raise ObservationError(f"{argv[0]} {argv[1]} failed (exit {result.returncode}); credential output withheld")
    return result.stdout if binary else json.loads(result.stdout)


def decode(data, key):
    value = base64.b64decode(data[key], validate=True)
    if not value:
        raise ObservationError("credential projection is empty")
    return value


def observe(args):
    authority = args.authority
    if authority.get("secret_name") != "sol-kafka-" + args.cluster:
        raise ObservationError("the public authority output does not name this target")
    reference = authority["reference"]
    if args.provider == "aws":
        if not reference.startswith(f"arn:aws:secretsmanager:{args.region}:{args.account}:secret:{authority['secret_name']}-"):
            raise ObservationError("authority reference does not belong to the observed AWS scope")
        password = read(["aws", "secretsmanager", "get-secret-value", "--secret-id", reference,
                         "--region", args.region, "--output", "json"])["SecretString"].encode()
    else:
        # Terraform exposes a project ID or project number in the full reference.
        if reference != f"projects/{args.project}/secrets/{authority['secret_name']}":
            project = read(["gcloud", "projects", "describe", args.project, "--format=json"])
            number = project.get("projectNumber")
            if (project.get("projectId") != args.project or not isinstance(number, str)
                    or not number.isdigit()
                    or reference != f"projects/{number}/secrets/{authority['secret_name']}"):
                raise ObservationError("authority reference does not belong to the observed GCP project")
        password = read(["gcloud", "secrets", "versions", "access", "latest", "--secret", reference,
                         "--project", args.project], binary=True)
    if not password:
        raise ObservationError("provider authority is empty")
    kube = ["kubectl"] + (["--kubeconfig", args.kubeconfig] if args.kubeconfig else [])

    def secret(namespace, name):
        return read(kube + ["get", "secret", name, "-n", namespace, "-o", "json"])["data"]

    users = decode(secret("redpanda", "redpanda-users"), "users.txt")
    expected = authority["username"].encode() + b":" + password + b":" + authority["mechanism"].encode()
    if users.strip().splitlines() != [expected]:
        raise ObservationError("broker input does not match provider authority")
    ca = decode(secret("redpanda", "redpanda-default-cert"), "ca.crt")
    consumers = []
    for namespace in args.namespaces:
        deployments = read(kube + ["get", "deployments", "-n", namespace, "-o", "json"])["items"]
        for deployment in deployments:
            pod = deployment["spec"]["template"]["spec"]
            for container in pod["containers"]:
                env = {item["name"]: item for item in container.get("env", [])}
                if "KAFKA_SASL_PASSWORD" not in env:
                    continue
                source = env["KAFKA_SASL_PASSWORD"]["valueFrom"]["secretKeyRef"]
                projection = secret(namespace, source["name"])
                if source["key"] != "KAFKA_SASL_PASSWORD" or decode(projection, source["key"]) != password:
                    raise ObservationError("consumer password does not match provider authority")
                if decode(projection, "KAFKA_SSL_CA_CERT") != ca:
                    raise ObservationError("consumer trust does not match broker CA")
                # The workload must mount the same projected CA it was compared against.
                volumes = {v["name"]: v.get("secret", {}) for v in pod.get("volumes", [])}
                if not any(volumes.get(m["name"], {}).get("secretName") == source["name"]
                           and any(i.get("key") == "KAFKA_SSL_CA_CERT"
                                   for i in volumes[m["name"]].get("items", []))
                           for m in container.get("volumeMounts", [])):
                    raise ObservationError("consumer does not mount the verified trust projection")
                consumers.append(namespace + "/" + deployment["metadata"]["name"])
    if not consumers or set(consumers) != set(args.consumer):
        raise ObservationError("authenticated consumers differ from the scenario requirement")
    return {"authority": reference, "broker_matches_authority": True,
            "consumer_password_and_ca_match": True, "consumers": sorted(consumers),
            "credential_values": "never recorded"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("aws", "gcp"))
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--account", default="")
    parser.add_argument("--project", default="")
    parser.add_argument("--kubeconfig", default="")
    parser.add_argument("--consumer", action="append", required=True)
    parser.add_argument("namespaces", nargs="+")
    args = parser.parse_args()
    try:
        args.authority = json.load(sys.stdin)
        print(json.dumps(observe(args), indent=2))
    except ObservationError as error:
        print(f"Kafka authority/delivery observation failed: {error}", file=sys.stderr)
        return 1
    except (ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        # Never include exception text: a malformed provider object can contain
        # credential values in arbitrary positions, including map keys.
        print("Kafka authority/delivery observation failed; credentials withheld; absence of evidence is not success", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
