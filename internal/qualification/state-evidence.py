#!/usr/bin/env python3
"""Project remote Terraform state to credential-free qualification evidence.

State is read through a pipe, never archived. Keep only the public Kafka reference
and the existence of the PostgreSQL setup input, which are what these rows use.
"""
import gzip
import json
import sys


def project(raw):
    if raw.startswith(b'\x1f\x8b'):
        raw = gzip.decompress(raw)
    state = json.loads(raw)
    outputs = state.get("outputs", {})
    authority = outputs.get("kafka_authority", {}).get("value")
    public = None
    if isinstance(authority, dict):
        public = {key: authority[key] for key in ("reference", "secret_name", "resource", "username", "mechanism")
                  if isinstance(authority.get(key), str)}
    postgres = outputs.get("postgres_url", {}).get("value")
    return {"version": state.get("version"), "serial": state.get("serial"),
            "outputs": {"kafka_authority": {"value": public},
                        "postgres_url": {"value": "[redacted nonempty]" if isinstance(postgres, str) and postgres else None,
                                         "sensitive": True}},
            "evidence": "public references and input presence only; not Terraform state"}


if __name__ == "__main__":
    try:
        print(json.dumps(project(sys.stdin.buffer.read()), indent=2))
    except (ValueError, TypeError, AttributeError, OSError):
        print("state evidence is unreadable; raw sensitive content withheld", file=sys.stderr)
        sys.exit(1)
