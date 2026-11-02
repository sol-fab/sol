# AWS Lambda external SQS/S3 mechanism exercise

**Verdict: MECHANISM, not a production qualification record.**

This exercise used a branch build, not a released candidate, and did not run the
shared attempt/record pipeline. It establishes that the AWS path can work against
real SQS and S3; it does not establish a production claim.

- Account/region: `<aws-account>` / `us-east-1`
- Queue: `sol-extqual-1-jobs`
- Bucket: `sol-extqual-1-uploads-<aws-account>`
- Function: `extqual-fn`
- Runtime identity: `sol-extqual-1-extqual-extqual_fn`
- Boundary: `sol-extqual-1-workload-boundary`
- Image: ECR digest `sha256:472123f079fa183e9017927e39fb92bfe00ca095c68da170675bf15e5073f355`

Observed:

- Lambda invoked successfully and returned `status: ok`, a message ID, and an object key.
- SQS showed zero visible and zero in-flight messages after consume/delete.
- The object was readable in S3.
- IAM simulation with the boundary allowed the bound queue/bucket and denied unrelated queue/bucket.
- Removing `QUEUE_ARN` failed before mutation; the function version stayed `$LATEST`.
- Cleanup removed the Lambda, queue, bucket, ECR repository, role, boundary, log group, and state objects; independent inventory found none.

Not established:

- released-candidate provenance;
- shared qualification evidence/record;
- EKS runtime path;
- any GCP runtime behavior.
