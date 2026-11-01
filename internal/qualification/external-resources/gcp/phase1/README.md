# GCP external queue/object Phase 1

This unexecuted fixture binds one Cloud Run Job function to an external Pub/Sub
topic/subscription and GCS bucket. Do not run it until the live qualification is
approved.

## Hard operational limit

- One job, one execution, `max-retries=0`, task timeout 600s.
- One test message and one small object.
- Delete every resource immediately after evidence capture.
- Maximum live lifetime: 30 minutes.

## Required permissions

- enable only `run.googleapis.com`;
- Pub/Sub Admin on the two test resources;
- bucket-scoped Storage Admin;
- Artifact Registry Writer on `sol-extqual-gcp-1`;
- Cloud Run Admin;
- Service Account Admin and Project IAM Admin for the test identities;
- `iam.serviceAccounts.actAs`.

## Sequence

1. Create topic, subscription, bucket, Artifact Registry repository.
2. Build and push the image to `us-central1-docker.pkg.dev/sol-qualification/sol-extqual-gcp-1/extqual-gcp-1-fn:<tag>`.
3. Run `sol deploy extqual-gcp-1/gcp/us-central1 --image-tag <tag> --image-ref extqual_gcp_fn=<digest>`.
4. Confirm the job exit output and Cloud Run logs.
5. Run negative checks against an unrelated topic and bucket with the job service account.
6. Delete the job, repository/image, bucket/objects, subscription, topic, service account, IAM bindings, and state objects.
7. Independently verify absence.

## Expected cost

Under $1 for a short run; operational ceiling $2.
