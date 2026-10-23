#!/usr/bin/env python3
"""The GCP CI publisher may write images, never the Kubernetes API."""

import argparse
import re
import sys
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[2]


def fail(message):
    print(f"check_gcp_publisher_role: {message}", file=sys.stderr)
    raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", help="repository root (default: this checkout)")
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else DEFAULT_ROOT
    main_tf = root / "platform/cloud/gcp/cluster/main.tf"
    text = main_tf.read_text(encoding="utf-8")
    start = text.find('resource "google_artifact_registry_repository_iam_member" "publisher"')
    if start < 0:
        fail("google_artifact_registry_repository_iam_member.publisher is missing")
    end = text.find("\n}", start)
    block = text[start:end] if end >= 0 else text[start:]
    if 'role       = "roles/artifactregistry.writer"' not in block:
        fail("the publisher grant is not roles/artifactregistry.writer")
    if "count" not in block or "publisher_service_account" not in block:
        fail("the publisher grant is not conditional on the declared publisher identity")
    if re.search(r"roles/container\.", block):
        fail("the publisher grant carries Kubernetes API authority")
    if re.search(r"google_project_iam_member", block):
        fail("the publisher grant is project-wide, not repository-scoped")
    print("check_gcp_publisher_role: publisher is repository-scoped Artifact Registry writer only")


main()
