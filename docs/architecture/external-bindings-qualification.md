# External queue/object-storage qualification audit

**Status:** audit; live run not started. No cloud resources were created.

## What is implemented

`queue` and `object_store` are external-first resource types. When a service declares
`uses: [name]`, the deployment plan appends the binding's `connection` pairs to that
unit's environment. Managed queue/object-store bindings are refused.

Offline coverage proves that:

- `connection` entries reach the workload spec;
- external queue and object-store resources can be composed with observability in one
  spec;
- managed bindings fail closed;
- capability names exist: `message.publish`, `message.subscribe`, `object.read`,
  `object.write`.

## What is not implemented

The external binding currently delivers **configuration only**:

- `keys` and `credentials` are not delivered for queue/object-store resources;
- the `message.*` and `object.*` capabilities are not translated into provider IAM;
- no application runtime client or provider-neutral queue/object contract exists;
- there is no application in the repository that consumes a Sol external queue or
  object-store binding.

The only runtime fact exercised offline is that environment variables appear. No real
queue publish/consume, object write/read, credential resolution, or authorization
behavior is covered.

## Qualification environments

Read-only inspection:

- AWS `876701109436` / `us-east-1`: no SQS queues; only the state bucket exists. SSO
  credentials are currently valid.
- GCP `sol-qualification`: no Pub/Sub topics/subscriptions; only the state bucket
  exists. Cloud Run and Cloud Scheduler APIs remain disabled.
- No pre-existing external queue or object-store resources are suitable for reuse.

## Provider choice

**AWS is the first candidate** if the product gap is resolved:

- SQS and S3 are available without enabling new APIs;
- compute can be a single unscheduled Lambda `_fn`;
- test resources can be isolated with unique names and a unique target/state key;
- GCP would additionally require enabling disabled APIs and building a Cloud Run image.

However, proceeding today would require a test application that directly uses the AWS
SDK and a manually attached SQS/S3 IAM policy. That would prove application/provider
glue, not Sol composition. It would also bypass the missing capability translation.

## Smallest isolated setup (proposed, not created)

- Unique environment/target, e.g. `extqual-1`, with its own state key under the existing
  state bucket and lock table.
- One AWS Lambda `_fn` image built from a small qualification app.
- One temporary SQS queue.
- One temporary S3 bucket or a dedicated bucket prefix.
- One Sol workspace declaring `type: queue` and `type: object_store` external
  bindings and `uses` from the function.
- No scheduler, database, Kafka, TLS, DNS, or external managed services.

Expected cost: a few Lambda invocations, a handful of SQS/S3 requests, one small image,
and negligible storage for the duration of the run.

Cleanup would require: Sol function destroy, queue/bucket deletion, image/repository
cleanup, target-specific authorization-root cleanup, and verification of absence.

## Decision required

Live qualification cannot establish the claimed platform behavior until one of these is
chosen:

1. **Implement external credential/capability delivery** so a provider-neutral app can
   authenticate via Sol-resolved identity or secret references; or
2. **Declare external bindings configuration-only** and explicitly accept that the
   application owns provider SDK calls and authorization; then live qualification proves
   configuration delivery, not composition.

Creating the queue/bucket and a hand-written AWS SDK app before this decision would not
qualify Sol's contract.
