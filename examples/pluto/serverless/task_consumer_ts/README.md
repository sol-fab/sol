# Durable task consumer (TypeScript)

An SQS-triggered Lambda function deployed by `sol task aws`. It consumes the
shared `Sol_task` envelope and returns `batchItemFailures`; the `fail` payload
is left for SQS retry/dead-letter. This is a provider-native demo because the
TypeScript framework does not yet publish a `@sol-fab/task` runtime.
