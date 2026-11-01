#!/usr/bin/env python3
"""Static scope check for the GCP external-resource authorization root."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
text = (root / "platform/cloud/gcp/authorization/main.tf").read_text()
checks = {
    "Pub/Sub publisher": 'role     = "roles/pubsub.publisher"',
    "Pub/Sub subscriber": 'role         = "roles/pubsub.subscriber"',
    "GCS reader": 'role     = "roles/storage.objectViewer"',
    "GCS writer custom role": 'permissions = ["storage.objects.create", "storage.objects.update"]',
    "Kubernetes workload identity": 'svc.id.goog[${each.value.namespace}/${each.value.unit}]',
    "serverless service account": 'google_service_account.serverless[each.value.unit].email',
}
missing = [name for name, needle in checks.items() if needle not in text]
if missing:
    print("GCP external authorization is missing: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
print("GCP external authorization scoping passed")
