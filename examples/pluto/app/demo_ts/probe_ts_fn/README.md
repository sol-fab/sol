# Serverless probe (TypeScript)

A run-once AWS Lambda probe. The image uses the AWS Lambda Node.js base image,
not `@sol-fab/fn` (that package is the Kubernetes CronJob runtime). It is
deployed by the `serverless` target's `-fn` lifecycle and must answer `{}` with
`{"status":"ok"}`.
