# AWS serverless `-fn` target lifecycle (2026-10-28)

**Verdict: the AWS serverless `-fn` vertical slice is established at mechanism
level.** One dependency-free `-fn` deployed through `sol deploy`, published an
immutable Lambda version, moved the `live` alias, invoked `{}` through that alias
and received `{"status":"ok"}`, deployed a second version, rolled back to version
1 with the ownership record rewritten, destroyed the function, and left no
Lambda function, ECR repository, execution role, or function log group behind.

This is **experimental, mechanism-only** evidence. It is not a production-profile
claim, not a GCP `-fn` claim, and not a trigger/schedule claim.

## Specimen

| Field | Value |
|---|---|
| Checkout | `/home/logan/Code/sol-cloud/sol-fn-serverless` (PR head; base `30abedc3`) |
| Target | `live/aws/us-east-1` |
| Project | `sol-fn-live` |
| Sol service | `checkout_fn` (`type: fn`) |
| Provider function | `checkout-fn` |
| AWS account / region | `<aws-account>` (redacted) / `us-east-1` |
| ECR repository | `sol-fn-target-live`, deleted after the run |
| Image digest | `sha256:7e7ce15725ae10d686c41e1f2e42b7ba333a6114015f8702c99434f8f6de427e` |
| Execution role | `arn:aws:iam::<aws-account>:role/sol-fn-target-live-exec`, deleted after the run |
| Evidence directory | `/home/logan/Code/sol-cloud/sol-fn-serverless/.qualification/fn-target-live/` |
| Owned-resource cleanup | independently re-read: functions `[]`, ECR repositories `[]`, role `NoSuchEntity`, `/aws/lambda/checkout` log groups `[]` |

The image is the `Fn.Lambda` run-once container used by the prior manual AWS
experiment. It has no Function URL and no event source mapping.

## Claims established

| Claim | Result | Evidence |
|---|---|---|
| Target deploy dispatches a dependency-free `-fn` | PASS | `deploy-1.log`: `Run: deploy-20261029T042957Z-80248`, release `{"kind":"fn",...,"version":"1"}` |
| Release record distinguishes `kind: fn` and carries no HTTP URL | PASS | `deploy-1.log`; record has `kind`, `function_name`, `version`, `alias`, `image`, `role_arn` and no `url` |
| Immutable image and explicit execution role are used | PASS | `get-function-1.json`: `PackageType=Image`, `State=Active`, `Role=...:role/sol-fn-target-live-exec` |
| Ownership tags are written | PASS | `tags-1.json`: `sol-owned=lambda-fn-experiment`, `sol-service=checkout-fn` |
| Version plus `live` alias | PASS | `versions-1.json`: `$LATEST`, `1`; `alias-1.json`: `live` -> `1` |
| Deploy invokes `{}` and requires `{"status":"ok"}` | PASS | `deploy-1.log` succeeded; independent `invoke-1.json` returned `{"status":"ok"}`, `StatusCode=200`, `ExecutedVersion=1` |
| No Function URL | PASS | `function-url-absent.txt`: `ResourceNotFoundException` for `GetFunctionUrlConfig` |
| No trigger or event source mapping | PASS | `event-sources-1.json`: `[]` |
| Second deploy publishes a new immutable version | PASS | `deploy-2.log`: `"version":"2"`; `versions-2.json`: `$LATEST`, `1`, `2`; alias moved to `2` |
| Target rollback moves `live` and re-invokes | PASS | `rollback.log`: observed `"version":"1"`, `"invocation_status":"ok"`; `alias-after-rollback.txt`: `1`; `invoke-body-after-rollback.txt`: `{"status":"ok"}` |
| Rollback rewrites the ownership record | PASS | `release-after-rollback.json` has `"version":"1"`; `release-before-rollback.json` had `"version":"2"` |
| Target destroy deletes the function and verifies absence | PASS | `destroy.log` exit 0; `functions-after-destroy.json`: `[]`; `get-function-after-destroy.txt`: `ResourceNotFoundException` |
| Sol does not delete the ECR repository or execution role | PASS | both remained after `sol destroy` and were deleted by the explicit experiment cleanup |
| Cleanup is independently verified | PASS | `final-absence.txt`: Lambda functions `[]`, ECR repositories `[]`, role `NoSuchEntity`, log groups `[]` |

## Provider-observation notes

- `aws lambda get-function --qualifier live` did not return the tags in this run;
  `aws lambda list-tags` and unqualified `get-function` did. The adapter's
  `describe` uses unqualified `get-function`, which observed them.
- The `live` alias was the execution identity for every invocation;
  `ExecutedVersion` reported `1` after rollback.
- Deleting the function also removed its versions and alias. The adapter does not
  delete account resources outside the function, so the ECR repository, execution
  role, and Lambda-created log group were cleaned up explicitly and re-read.
- The cleanup also removed the pre-existing `/aws/lambda/checkout-svc` log group
  left by the earlier HTTP target experiment. That log group was not created by
  this run and is not part of this claim.

## Recorded as NOT RUN / not claimed

| Item | Status | Why |
|---|---|---|
| `FunctionError` rejection against a live failing handler | NOT RUN LIVE | The fake-provider lifecycle regression `test_target_serverless_fn.sh` exercises a provider `FunctionError` on rollback, asserts the command fails, and asserts the record names the alias the provider moved (version 2) while the alias stays on that version. No live failing-handler image was built for this bounded run. |
| GCP `-fn` (Cloud Run Jobs) | NOT RUN | Not implemented; no parity is assumed. |
| Triggers, schedules, event sources | NOT RUN | Deliberately out of contract for this slice. |
| AWS-native incoming identity for `-svc` | NOT RUN | The `-fn` slice has no incoming callers; `-svc` remains the Google-token experiment. |
| Serverless `-worker` and queues | NOT RUN | No provider queue semantics are accepted. |
| Production profile, TLS, public SSO | NOT CLAIMED | Experimental target only. |
| Managed ECR/IAM provisioning | NOT CLAIMED | The adapter consumes an existing repository and role. |
| Observability acceptance | NOT CLAIMED | Application/CloudWatch logs exist; no Sol-managed acceptance. |

## What this establishes, and what it does not

It establishes the first serverless `-fn` vertical slice on AWS: target-scoped
deploy, provider-native immutable version and alias, run-once invocation through
Sol, ownership-record rollback, kind-aware destroy, and independently verified
cleanup.

It does not establish function triggers, GCP function execution, production
guarantees, or any change to the `-worker`/queue contract.
