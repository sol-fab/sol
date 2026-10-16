# Candidate database declaration preparation

The product declaration is **input to future qualification**, never a verdict or an
applicability catalog. Existing live harnesses and matrices remain authoritative. The
internal producer and binding tool do not call the typed qualification runner or change its
MECHANISM-only fixture binding. Product-authority review is required before adoption.

## Two declarations, two scopes

A factory release cannot contain every future application's consumer list. Its bundle carries
`share/sol/<version>/database-contract.json` and the internal
`bin/sol-database-contract` producer, built from the same clean revision as other release
assets. The definition declares product CA key/file, credential vocabulary and rendering
identities. A target-specific specimen declaration comes from that exact producer using
canonical configuration, workspace facts, whole-target selection and planning. The producer
cannot accept a caller-supplied workload subset. Declaration planning is the shared planning
body before readiness preflight: unpublished images or unmet profile guarantees must not erase
expected subjects. Execution planning retains its existing preflight; declaring metadata grants
no deployment or qualification authority.

The specimen lists every planned workload, including nonconsumers, with canonical resource
kind, namespace/name, declared resource uses, database binding, consuming container identities,
DML credential references and optional Sol CA delivery. Target omissions come from the existing
target selection owner. Unimplemented declarations or missing active Dockerfiles refuse
complete declaration; they cannot silently disappear. Deployment, Rollout and CronJob are
reported explicitly. An observer that supports only Deployments must refuse unsupported
requirements rather than drop scheduled/progressive consumers.

The target's database declares its ownership, durable credential-authority reference, transient
administrative references and a **separate migration execution context**. Migration CA and DDL
references name the database namespace and migration container, not an application workload.
The Job is ephemeral: its exact execution identity must come from an execution receipt, not a
reader's reconstructed name or an application-consumer alias. This prepares the separate
migration-specific CA obligation/evaluator; it does not implement that evaluator.

The durable credential authority holds DDL/DML role passwords; it is not the transient setup
Secret containing administrative connection material. Both identities remain explicit and
separate. External databases retain all declared DML consumers and migration DDL delivery,
while declaring no Sol CA or Sol administrative reference. These are product facts, not
permission to waive qualification obligations. Actual DML authority and TLS behavior still
require independent qualification evidence.

## Volume identity

The public delivery promise is the expected ConfigMap/key, consuming container and CA file
location (also used by runtime `sslrootcert`). The literal volume name links fields inside a
pod template. Product documentation does not expose it as an application-facing identifier.
The definition records the renderer's canonical spelling under `rendering`, classified as
`internal_linkage`; cross-tests still require the actual writer to match its declaration.
This proposes accepting consistently renamed but correctly linked volumes in qualification.
The existing AWS name check is retained until that classification and policy cutover are
reviewed. It is not silently removed to make the I4 comparison equivalent.

## Version, digest and binding

Each envelope has exactly `declaration` and `digest`. The digest is SHA-256 of UTF-8 JSON for
the declaration with recursively sorted unique object keys, compact separators, literal UTF-8
strings, and no floats or non-JSON extensions. Array order is preserved. Definitions and
specimens use schema `1`; definitions include the full product revision, and specimens include
that revision plus the definition digest. No timestamps, credentials, certificate bytes or
image placeholders enter these envelopes. Requested target and resolved target are separate
fields. The product decoder supports only its own schema/definition; missing, altered or
unsupported declarations fail closed without guessing from a tag or parsing product source.

The offline binding entry point is:

```sh
python3 internal/qualification/database-contract-binding.py \
  --candidate /path/candidate.json --install /path/sol-<version> \
  --workspace /path/specimen --target dev/aws/region
```

It invokes the existing `sol-under-test.sh` candidate/installed-bytes verifier unchanged.
It additionally requires the definition and producer to be unique regular members of that
recorded archive: an unrecorded extra executable in the install cannot substitute a producer.
It verifies declaration revision/digest/schema, runs the recorded producer, and binds the
specimen to the definition and requested target. Ambient `SOL_HOME` cannot replace candidate
assets. Output records the existing candidate identity and both declarations; it does not
produce a release verdict. No old Bash declaration parser is a fallback. Existing candidates
without these members, including alpha.37, remain unsupported by this new entry point.

The trust boundary remains the reviewed local producer and trusted candidate record. Content
addressing and archive equality detect corruption/substitution; they do not authenticate an
untrusted publisher or attest that arbitrary `--binary`/`--contract-binary` build inputs were
compiled from the claimed source. Release assembly preserves its existing clean-revision and
trusted-build-input model. A future release qualification must also consume the existing
attempt/specimen binding and independent observation context; this helper does not replace them.

## Offline verification and cutover

Product tests compare declarations to independently decoded real rendered workloads,
ConfigMaps, migration Jobs and runtime URL inputs across AWS/GCP, including scheduled and
nonconsuming workloads. They check the complete reviewed definition shape and target omission
boundary, and reject mutations to declaration keys/paths and rendered sources/containers.
Installed-candidate tests use the actual internal producer, archive verification, hostile
schema/digest/revision/member changes and command traps proving provider operations are absent.

Before adoption: review this product declaration boundary, introduce supported future candidates,
implement migration-specific CA observation/evaluation, decode the declaration into complete
qualification-owned obligations, and review claim-family ownership and live transport. Preserve
independent absence verification. Only a later adoption change may remove legacy predicates.
