#!/usr/bin/env python3
"""AWS external queue/object capability translation must stay resource-scoped."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
aws = (ROOT / "platform/cloud/aws/authorization/main.tf").read_text()

required = [
    '"message.publish"',
    '"sqs:SendMessage"',
    '"message.subscribe"',
    '"sqs:ReceiveMessage"',
    '"sqs:DeleteMessage"',
    '"sqs:ChangeMessageVisibility"',
    '"object.read"',
    '"s3:GetObject"',
    '"object.write"',
    '"s3:PutObject"',
    "SolCapability${i}",
    "ExternalQueue${",
    "ExternalObject${",
    "Resource = (",
    "[grant.resource]",
]
for fragment in required:
    if fragment not in aws:
        raise SystemExit(f"external AWS authorization missing {fragment!r}")

print("external AWS authorization scoping passed")
