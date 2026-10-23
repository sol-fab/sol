#!/usr/bin/env python3
"""The GCP qualification app phase must publish as the declared publisher.

The issue decision is explicit: the operator's ambient gcloud identity must not
be the image-push identity. This checks the harness's push path, its target
declaration and the documented input.
"""

import argparse
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]
HARNESS = "internal/qualification/gcp/live-qual.sh"


def fail(message):
    print(f"check_gcp_qualification_publisher: {message}", file=sys.stderr)
    raise SystemExit(1)


def section(text, header):
    start = text.find(header)
    if start < 0:
        fail(f"{header!r} is missing")
    end = text.find("\n}", start)
    return text[start:end] if end >= 0 else text[start:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", help="repository root (default: this checkout)")
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    path = root / HARNESS
    if not path.is_file():
        fail(f"{path} is missing")
    text = path.read_text(encoding="utf-8")

    push = section(text, "push_app_images()")
    for needle in [
        'print-access-token --impersonate-service-account "$PUBLISHER_SERVICE_ACCOUNT"',
        "docker login -u oauth2accesstoken --password-stdin",
    ]:
        if needle not in push:
            fail(f"the GCP push path does not contain {needle!r}")
    if "gcloud auth configure-docker" in push:
        fail("the GCP push path still authenticates with the ambient gcloud identity")
    if "unset token" not in push:
        fail("the publisher token is not cleared after docker login")

    if text.count("publisher_service_account: $PUBLISHER_SERVICE_ACCOUNT") < 2:
        fail("both qualification target writers must declare the publisher service account")
    if "PUBLISHER_SERVICE_ACCOUNT" not in section(text, "required\n"):
        fail("the required-input documentation does not name PUBLISHER_SERVICE_ACCOUNT")

    print(
        "check_gcp_qualification_publisher: app pushes mint a token as the declared "
        "publisher and never use the ambient gcloud identity"
    )


main()
