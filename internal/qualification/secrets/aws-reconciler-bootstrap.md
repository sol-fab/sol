# AWS fenced reconciler bootstrap

`sol grants apply` runs as the target's fenced authorization reconciler and never as the
deploy or ambient identity. It assumes the role before it reads the authorization root's
state, so that role must already exist. A target whose authorization root has never been
applied cannot create the role it needs to assume.

The non-circular bootstrap is one **administrator-authorized Terraform apply** of the
authorization root with no workload grants:

1. The installation administrator applies the root and creates the fenced reconciler role.
2. The qualifier/CI authorization identity (named by the role's trust policy) assumes that
   role for every later `sol grants` operation.
3. `sol grants apply` then manages only workload roles and grants. It never creates its own
   trust principal.

This is a one-time setup action, not part of the qualification run. It creates IAM and must
be approved separately. The secret scenario does not perform it.

## Inputs

- installed release prefix `SOL_INSTALL`, and its
  `share/sol/<version>/platform/cloud/aws/authorization` root;
- target `secret-qual/aws/us-east-1`;
- account `123456789012`, region `us-east-1`;
- state bucket `<state-bucket>`, lock table `<lock-table>`;
- qualifier/authorization principal ARN that may assume the reconciler;
- environment `secret-qual`, cluster `sol-secret-qual`.

The target must declare:

```yaml
aws:
  state_lock_table: <lock-table>
  reconciler_role_arn: arn:aws:iam::123456789012:role/sol/authorization/sol-secret-qual-authorization
  reconciler_trust_principal_arn: arn:aws:iam::<qualifier-or-ci-authorization-role>
```

The role ARN is produced by the bootstrap below; leave the target's value out until it is
known, or set it to the expected `sol-<env>-authorization` name and verify it.

## Bootstrap (one-time administrator credentials)

Use the **one-time installation administrator** identity that created the installation's
five roles. It is the only identity in this procedure allowed to create IAM roles; the
provisioner policy intentionally has no `iam:*`, and the deploy role must never be used.
Start a short administrator session, export its temporary credentials only for this one
apply, and discard the session afterwards. Do not export those credentials into the
qualification attempt.

If the organization forbids a human administrator session, have its IAM pipeline create
the same role, trust and fenced policy from the authorization root and record the resulting
ARN. The preflight verifies the result; it does not require how it was created.

The authorization root's state key is `sol/<target>/authorization.tfstate`. Copy the
release root to a writable temporary directory before `terraform init`; never write
Terraform state or plugins into a read-only install prefix.

```sh
WORKDIR="$(mktemp -d)"
cp -R "$SOL_INSTALL/share/sol/$SOL_VERSION/platform/cloud/aws/authorization" \
  "$WORKDIR/authorization"
AUTH_ROOT="$WORKDIR/authorization"
STATE_BUCKET=<state-bucket>
STATE_LOCK=<lock-table>
TARGET=secret-qual/aws/us-east-1
ENVIRONMENT=secret-qual
TARGET_NAME=secret-qual-aws-us-east-1   # sanitized target name, no slashes
CLUSTER=sol-secret-qual
TRUST_ARN=arn:aws:iam::123456789012:role/<qualifier-or-ci-authorization-role>

terraform -chdir="$AUTH_ROOT" init -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=sol/$TARGET/authorization.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=$STATE_LOCK" \
  -backend-config="encrypt=true"

terraform -chdir="$AUTH_ROOT" apply \
  -var="region=us-east-1" \
  -var="environment=$ENVIRONMENT" \
  -var="target_name=$TARGET_NAME" \
  -var="cluster_name=$CLUSTER" \
  -var="reconciler_trust_principal_arn=$TRUST_ARN" \
  -var='grants=[]'

terraform -chdir="$AUTH_ROOT" output -raw reconciler_role_arn
```

Keep the bootstrap working directory until the role ARN and trust are recorded, then remove
it. Terraform state itself is in the durable S3 backend, not the working directory.

The empty grant set is deliberate: this apply creates the reconciler role and its fence,
not workload roles. A later `sol grants apply` supplies the safe grant set.

## Verification

Read-only, before any workload run:

```sh
aws iam get-role --role-name sol-secret-qual-authorization \
  --query 'Role.{Arn:Arn,Trust:AssumeRolePolicyDocument}'

aws iam get-role --role-name sol-qual5-deploy \
  --query 'Role.Arn'
```

The reconciler ARN must not equal the deploy ARN, its trust policy must name
`$TRUST_ARN`, and its path must be `/sol/authorization/`. The scenario's plan preflight
checks these facts; it does not create the role.

## Failure and recovery

- The bootstrap apply fails: read the Terraform error; do not fall back to ambient grants.
  The authorization state is in the target's durable bucket; an interrupted apply is not
  absence. Re-run the same apply or use the normal Terraform recovery path.
- The role exists with the wrong trust: correct the target trust and re-apply the root as
  the administrator; do not widen the role policy.
- The target's authorization state exists but the role was deleted: the root state still
  represents it; re-apply as administrator to recreate it, then verify trust.
- Never point `reconciler_role_arn` at the deploy role. `sol grants` refuses that
  configuration by design.
