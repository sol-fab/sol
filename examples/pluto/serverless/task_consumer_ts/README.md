# Durable task consumer (TypeScript)

The AWS adapter is an SQS-triggered Lambda function deployed by `sol task aws`.
It consumes the shared `Sol_task` envelope and returns `batchItemFailures`; the
`fail` payload is left for SQS retry/dead-letter. `serverless/task_consumer_ts_gcp/Dockerfile` is a
Pub/Sub push HTTP server deployed by `sol task gcp`: 200 Ack, 500 Retry, 400
malformed. Both adapters share `src/task.ts` for envelope validation and outcome
semantics. This is a demo-local shared module because the TypeScript framework
does not yet publish `@sol-fab/task`.
