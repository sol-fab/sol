# Task handler fixture

A minimal durable-task handler used by the task execution exercises and live
procedures. It is a fixture, not an example workspace: the application contract
and developer workflow are in
[`sol-task.md`](../../../framework/ocaml/sol-task/sol-task.md) and
[`task-handlers.md`](../../../docs/guides/task-handlers.md).

`T.handle` returns `Ack` for payload `ack` and `Retry` for payload `fail`, and
logs the stable `task_id`, `kind`, and idempotency key. The binary selects the
runtime from `SOL_TASK_RUNTIME`:

- `lambda` — `Sol_task_lambda` (SQS event)
- `pubsub` — `Sol_task_pubsub` (Pub/Sub push HTTP)

## Build

From the repository root:

```sh
eval "$(opam env)"
dune build internal/fixtures/task-handler/task_handler.exe
```

The resulting binary is `_build/default/internal/fixtures/task-handler/task_handler.exe`.

## Image

```sh
ctx=$(mktemp -d)
cp _build/default/internal/fixtures/task-handler/task_handler.exe "$ctx/task_handler"
cp internal/fixtures/task-handler/Dockerfile "$ctx/Dockerfile"
# Lambda accepts a Docker v2 manifest, not an OCI image index.
docker buildx build --platform linux/amd64 --provenance=false --sbom=false \
  --output "type=image,name=<registry>/<repo>:<tag>,push=true,oci-mediatypes=false" \
  "$ctx"
```

Push the image to ECR or Artifact Registry and deploy it with `sol task aws` or
`sol task gcp`; see
[`internal/qualification/task-execution/README.md`](../../../internal/qualification/task-execution/README.md).
