# External queues and object stores

Declare a logical queue or object store in `sol.yml`; bind it per target in
`sol/environments.yml`. The application uses its native provider SDK.

```yaml
resources:
  jobs: { type: queue }
  uploads: { type: object_store }
services:
  worker:
    type: worker
    uses: [jobs, uploads]
```

```yaml
targets:
  aws/us-east-1:
    resources:
      jobs:
        binding:
          ownership: external
          store: external
          connection:
            QUEUE_ARN: arn:aws:sqs:us-east-1:123456789012:jobs
            QUEUE_URL: https://sqs.us-east-1.amazonaws.com/123456789012/jobs
      uploads:
        binding:
          ownership: external
          store: external
          connection:
            OBJECT_ARN: arn:aws:s3:::uploads/*
            OBJECT_BUCKET: uploads
  gcp/us-central1:
    resources:
      jobs:
        binding:
          ownership: external
          store: external
          connection:
            TOPIC: jobs
            SUBSCRIPTION: jobs-worker
      uploads:
        binding:
          ownership: external
          store: external
          connection:
            BUCKET: uploads
```

Sol requires workload identity; secret-reference authentication for external
queues/object stores is refused. Missing, malformed, or unsupported bindings
fail before provider mutation.

| Capability | AWS | GCP |
|---|---|---|
| `message.publish` | SQS `SendMessage` | Pub/Sub Publisher |
| `message.subscribe` | SQS receive/delete/change-visibility | Pub/Sub Subscriber |
| `object.read` | S3 `GetObject` | Cloud Storage objectViewer |
| `object.write` | S3 `PutObject` | Cloud Storage create/update |

AWS uses per-unit IAM roles and permissions boundaries. GCP uses per-unit
service accounts or Workload Identity principals; it has no permissions
boundary equivalent. GCP object write does not include delete.
