# Backend composition: minimal next contracts

**Status:** proposal. This page records the smallest coherent designs for the remaining
backend gaps. It is not a current-behavior claim. Each section states the evidence used,
the proposed contract, and the product tradeoff that needs approval.

## Existing evidence

- Compute is contracted for `_svc`, `_worker`, and `_fn`; target-scoped serverless supports
  every selected `_svc`/`_fn` and per-unit identity.
- The canonical requirement type is `Sol_cli_grant.requirement`; the only realized
  capability is `Secret_access`.
- `sol.yml` resources already carry `type`, ownership, binding keys, connection, and
  credential-class paths. `uses` is the resource dependency edge.
- Kafka is a stream dependency consumed by `_worker`; SQS/Pub/Sub task queues are owned by
  the standalone `sol task aws`/`sol task gcp` lifecycles.
- Release records are provider-specific: AWS Lambda/task and GCP Cloud Run/Job/task carry
  different identity and provider fields.
- Mixed backend observability now has a target contract; resource and task backends do not.

## 1. Queue capability

**Do not replace Kafka semantics with a generic queue.** Kafka remains a stream resource
for `_worker`; a queue is an at-least-once work-delivery backend for task handlers and
simple producers.

Minimal contract:

- resource type `queue` with `Ownership_external` first;
- canonical capabilities `Message_publish` and `Message_subscribe`;
- binding provides `endpoint`, `queue` (or topic/subscription), and a credential source;
- provider translation:
  - AWS SQS: queue URL/ARN, publish/send and receive/delete grants;
  - GCP Pub/Sub: topic/subscription, publisher/subscriber grants;
  - SQS-compatible third party: endpoint override plus the same publish/subscribe contract;
- application delivery is provider-neutral keys such as
  `QUEUE_ENDPOINT`, `QUEUE_NAME`, `QUEUE_KIND`, plus the existing secret delivery.

The contract does not promise ordering, exactly-once, consumer groups, or replay. Those are
stream properties and stay with Kafka.

**Approval needed:** whether `queue` is a resource type or only a capability attached to a
task component; whether managed provider queues are provisioned in the first increment.

## 2. Storage capability

Minimal contract:

- resource type `object_store`, initially external ownership only;
- capabilities `Object_read` and `Object_write`;
- binding provides endpoint, bucket/container, region, and a credential secret source;
- provider translation: S3, GCS, and S3-compatible endpoints; no provider SDK in application
  manifests;
- delivery: provider-neutral bucket/endpoint keys and scoped credentials.

Managed bucket provisioning is a separate increment. It requires a storage backend contract
for lifecycle, retention, and deletion that the current resource model does not have.

**Approval needed:** whether the first increment is external-only; the retention/deletion
contract for a future managed resource.

## 3. Target-scoped tasks with thin standalone commands

The task handler is a library, not a workload kind. A target-scoped task therefore needs a
declaration before `sol deploy` can own it.

Minimal shape:

- one shared `task` lifecycle model containing component identity, image, queue binding,
  retry/DLQ policy, runtime identity, release record, and rollback identity;
- target-scoped deploy resolves the queue and runtime identity from the target and calls the
  lifecycle;
- standalone `sol task aws/gcp` commands construct the same model from their explicit flags
  and call the same lifecycle adapter; they become thin compatibility commands, not a second
  lifecycle;
- provider adapters keep SQS/Lambda and Pub/Sub/Cloud Run mechanics.

**Approval needed:** how a task is declared in the workspace. Options are a new manifest
kind/primitive or a task-specific declaration under an existing unit. That is a product
contract decision, not an implementation detail.

## 4. Shared release-record schema

Proposed envelope, additive to provider-specific detail:

```json
{
  "schema": 1,
  "component": { "kind": "svc", "name": "checkout_svc" },
  "artifact": { "image": "repo@sha256:..." },
  "identity": { "runtime": "..." },
  "provider": { "name": "aws", "record": { "...": "adapter fields" } },
  "rollback": { "identity": "..." }
}
```

Rules:

- the envelope is provider-independent and versioned;
- provider adapters may retain their full current records under `provider.record`;
- readers accept old records only through the adapter that owns them;
- no second source of truth for component/artifact/identity.

**Approval needed:** whether to version/replace existing records or dual-write the envelope.
Live release records make that a compatibility decision.

## Sequence

1. Approve queue/storage semantics and the task declaration shape.
2. Implement one external backend translation end-to-end before adding managed variants.
3. Introduce the shared release envelope once the component/task declaration is stable.
4. Add live qualification only with explicit authorization.
