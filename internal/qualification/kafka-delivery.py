#!/usr/bin/env python3
"""Value-free check of managed Kafka credential delivery.

Establishes three things without reading credential values:

* the public authority output names this target's managed broker authority and
  its reference is in the observed provider scope;
* every expected consumer Deployment projects the delivered credential Secret
  for the SASL password and the broker CA;
* the declared credential Secret exists in each consumer namespace (metadata
  only, read with the deploy identity that wrote it).

It never reads the broker users Secret or any Secret ``data``. Authentication
and broker trust are established separately by the application transaction,
whose evidence path is passed in and whose exercised consumers are recorded.
The qualification identity therefore never needs broker credential material.
"""
import argparse
import json
import subprocess
import sys


class ObservationError(ValueError):
    """Only messages constructed here from safe context, never provider values."""


def read_json(argv, what):
    result = subprocess.run(argv, capture_output=True, timeout=60)
    if result.returncode:
        # stdout/stderr can contain a credential, even on a failed read.
        raise ObservationError(
            f"{argv[0]} {what} failed (exit {result.returncode}); output withheld"
        )
    return json.loads(result.stdout)


def read_text(argv, what):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ObservationError(
            f"{argv[0]} {what} failed (exit {result.returncode}); output withheld"
        )
    return result.stdout.strip()


def authority_scope(args):
    authority = args.authority
    if authority.get("secret_name") != "sol-kafka-" + args.cluster:
        raise ObservationError("the public authority output does not name this target")
    reference = authority["reference"]
    if args.provider == "aws":
        prefix = (
            f"arn:aws:secretsmanager:{args.region}:{args.account}:secret:"
            f"{authority['secret_name']}-"
        )
        if not reference.startswith(prefix):
            raise ObservationError("authority reference does not belong to the observed AWS scope")
    else:
        # Terraform exposes a project ID or project number in the full reference.
        # This is project metadata, not secret material.
        if reference != f"projects/{args.project}/secrets/{authority['secret_name']}":
            project = read_json(
                ["gcloud", "projects", "describe", args.project, "--format=json"],
                "projects describe",
            )
            number = project.get("projectNumber")
            if (
                project.get("projectId") != args.project
                or not isinstance(number, str)
                or not number.isdigit()
                or reference != f"projects/{number}/secrets/{authority['secret_name']}"
            ):
                raise ObservationError(
                    "authority reference does not belong to the observed GCP project"
                )
    return reference


def consumer_projections(args):
    kube = ["kubectl"] + (["--kubeconfig", args.kubeconfig] if args.kubeconfig else [])
    findings = []
    consumers = []
    for namespace in args.namespaces:
        deployments = read_json(
            kube + ["get", "deployments", "-n", namespace, "-o", "json"],
            "deployments",
        )["items"]
        for deployment in deployments:
            pod = deployment["spec"]["template"]["spec"]
            for container in pod["containers"]:
                env = {item["name"]: item for item in container.get("env", [])}
                if "KAFKA_SASL_PASSWORD" not in env:
                    continue
                source = env["KAFKA_SASL_PASSWORD"].get("valueFrom", {}).get("secretKeyRef", {})
                if (
                    source.get("name") != args.credential_secret
                    or source.get("key") != "KAFKA_SASL_PASSWORD"
                ):
                    raise ObservationError(
                        "consumer password projection does not name the delivered credential"
                    )
                volumes = {
                    volume["name"]: volume.get("secret", {})
                    for volume in pod.get("volumes", [])
                }
                mounted = False
                for mount in container.get("volumeMounts", []):
                    volume = volumes.get(mount["name"], {})
                    if volume.get("secretName") == args.credential_secret and any(
                        item.get("key") == "KAFKA_SSL_CA_CERT"
                        for item in volume.get("items", [])
                    ):
                        mounted = True
                if not mounted:
                    raise ObservationError("consumer does not mount the delivered CA projection")
                consumer = namespace + "/" + deployment["metadata"]["name"]
                consumers.append(consumer)
                findings.append(
                    {
                        "consumer": consumer,
                        "credential_secret": args.credential_secret,
                        "password_key": "KAFKA_SASL_PASSWORD",
                        "ca_key": "KAFKA_SSL_CA_CERT",
                    }
                )
    if not consumers or set(consumers) != set(args.consumer):
        raise ObservationError("projected consumers differ from the scenario requirement")
    return consumers, findings


def credential_metadata(args, consumers):
    """Read only the Secret's name with the deploy identity; never its data."""
    secret_kube = ["kubectl"] + (
        ["--kubeconfig", args.secret_kubeconfig] if args.secret_kubeconfig else []
    )
    for namespace in sorted({consumer.split("/", 1)[0] for consumer in consumers}):
        name = read_text(
            secret_kube
            + [
                "get",
                "secret",
                args.credential_secret,
                "-n",
                namespace,
                "-o",
                "jsonpath={.metadata.name}",
            ],
            "secret metadata",
        )
        if name != args.credential_secret:
            raise ObservationError(
                "delivered credential Secret is not present in a consumer namespace"
            )


def behavioral_evidence(args, consumers):
    try:
        with open(args.transaction, encoding="utf-8") as handle:
            transcript = handle.read()
    except OSError as error:
        raise ObservationError("application transaction evidence is unreadable") from error
    causal = any(prefix in transcript for prefix in ("charge id:", "order id:"))
    if not causal or "read-back: " not in transcript:
        raise ObservationError(
            "application transaction does not establish Kafka authentication and consumption"
        )
    behavioral = list(args.behavioral_consumer or [])
    if not behavioral:
        raise ObservationError("no behavioral consumer is named")
    if not set(behavioral) <= set(consumers):
        raise ObservationError("a behavioral consumer is not an expected consumer")
    return behavioral


def observe(args):
    reference = authority_scope(args)
    if not args.credential_secret or any(ch.isspace() for ch in args.credential_secret):
        raise ObservationError("the delivered credential Secret name is not declared")
    consumers, findings = consumer_projections(args)
    credential_metadata(args, consumers)
    behavioral = behavioral_evidence(args, consumers)
    return {
        "authority": reference,
        "authority_secret": args.authority["secret_name"],
        "credential_secret": args.credential_secret,
        "consumers": sorted(consumers),
        "projection": findings,
        "secret_metadata": "present in each consumer namespace (deploy identity; data not read)",
        "authentication": {
            "evidence": args.transaction,
            "consumers": sorted(behavioral),
        },
        "credential_values": "never read",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", required=True, choices=("aws", "gcp"))
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--account", default="")
    parser.add_argument("--project", default="")
    parser.add_argument("--kubeconfig", default="")
    parser.add_argument("--secret-kubeconfig", required=True)
    parser.add_argument("--credential-secret", required=True)
    parser.add_argument("--transaction", required=True)
    parser.add_argument("--behavioral-consumer", action="append", required=True)
    parser.add_argument("--consumer", action="append", required=True)
    parser.add_argument("namespaces", nargs="+")
    args = parser.parse_args()
    try:
        args.authority = json.load(sys.stdin)
        print(json.dumps(observe(args), indent=2))
    except ObservationError as error:
        print(f"Kafka delivery observation failed: {error}", file=sys.stderr)
        return 1
    except (ValueError, KeyError, TypeError, AttributeError, OSError, subprocess.SubprocessError):
        # Never include exception text: a malformed provider object can contain
        # credential values in arbitrary positions, including map keys.
        print(
            "Kafka delivery observation failed; values withheld; "
            "absence of evidence is not success",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
