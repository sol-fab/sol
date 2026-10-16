# Typed qualification prototype

This internal, opt-in executable investigates whether typed qualification contracts
can make the cloud harnesses easier to maintain. It implements one representative
contract: database CA ConfigMap delivery and Deployment volume references. The live
AWS/GCP entry points continue to own their existing phases and assertions.

The [qualification ownership proposal](architecture-proposal.md) assigns semantic
receipt matching to the evaluator, checks the complete obligation universe, separates
product declarations from qualification policy, and defines durable commit/recovery.
The [implementation plan](implementation-plan.md) names the replacement/deletion
points and hostile acceptance tests. This update remains design-only; PR #1487
stays draft and the active harnesses are unchanged.

**Known contract mismatch:** this prototype checks `ca.crt`, but Sol's database
contract declares `ca.pem`. Its offline fixtures repeated the wrong premise.
The executable's mechanism tests do not establish agreement with the product
contract, and it must not replace a live assertion in its current form. The
proposal identifies the owning declaration and the correction required before
adoption. This design revision does not change the executable.

## Boundaries

`database_ca.ml` defines the claim and an `Observer` module interface. The observer
returns a readable object, positive absence, or an unreadable observation. It never
decides the claim. `main.ml` implements independent Kubernetes reads through an
explicit kubeconfig. It does not invoke Sol's renderer or lifecycle implementation.

`command.ml` executes structured argv with GNU `timeout`, stdin closed, inherited
environment, and separate output files. GNU timeout supplies process-group termination
and a two-second kill grace period; there is no custom process supervisor. The runner
records completion status, timestamps and output references, preserving diagnostics
even when an observation times out. A nonzero command exit is evidence, not a verdict.
For these read-only observations it means UNKNOWN. A future action expecting refusal
would need its own evaluator; treating every nonzero exit as success is not supported.

`contract.ml` records PASS, FAIL, UNKNOWN and NOT_RUN. An unreadable declaration is
UNKNOWN; dependent observations are NOT_RUN. Independent observations continue after
a failure. Any result other than all PASS exits unsuccessfully. Empty consumer
selection fails, so an unexercised contract cannot pass vacuously.

The contract reads the latest complete `sol-database-identity:` report from the final
deploy log, checks its target and full field set, and uses its declared CA name and
namespace. It does not reconstruct Sol's naming rules. Consumer Deployment addresses
are explicit inputs: the existing harness should supply its selected database consumers
when adopting this executable. This prototype cannot prove that a manually supplied
selection includes every workload.

For the declared namespace and every consumer namespace, the CA ConfigMap must exist
with nonempty `ca.crt`. Every selected Deployment must have a `db-ca` pod volume
referencing that ConfigMap. It does not establish CA equality, certificate validity,
container volumeMounts, successful TLS connections, DML delivery, Job behavior, or teardown.

## Run and inspect

Build from this worktree with the README's pinned dependencies:

```sh
eval "$(opam env)"
dune build internal/qualification/runner/main.exe
```

The invocation shape below illustrates the read-only prototype. The known key
mismatch above must be corrected before using its verdict against a live specimen:

```sh
dune exec internal/qualification/runner/main.exe -- \
  --deploy-log /path/to/attempt/app-deploy.log \
  --target qualreg-ATTEMPT/aws/us-east-1 \
  --kubeconfig /path/to/attempt/deploy.kubeconfig \
  --consumer pluto-payments/charge-svc \
  --consumer pluto-comms/notify-worker \
  --evidence /path/to/attempt/database-ca-prototype
```

Select every database consumer, including other services in the target. Namespace and
Deployment names above are examples, not a selection authority. The kubeconfig selects
the observation identity; authentication helpers may use its inherited environment.
The runner neither loads a password store nor elevates identity. The phase driver's
pattern of exporting a Terraform password without passing it on argv remains an
operator concern; no password is needed for this contract.

The evidence directory must be new. Directory mode is 0700 and files are 0600.
`report.json` records target, observer, kubeconfig path, verdicts and links from each
observed resource to its execution record; those records name stdout and stderr files.
Kubernetes output is projected before capture: ConfigMaps yield identity and a boolean;
Deployments yield identity and volume references. No Secrets, certificate material or
container environment values are requested. Generic command callers must likewise
choose outputs that are safe to retain. Reports are conservatively labeled MECHANISM
and do not promote provider matrices or release verdicts automatically.

Exit 0 means every selected claim passed; 1 means a claim was not established; 2 means
invalid invocation or an evidence I/O failure. A forced interruption can leave partial
files without a final report. This read-only prototype owns no resources and performs
no teardown. Moving mutation into it requires a separate lifecycle design preserving
the existing capture-before-cleanup and independent absence guarantees.

Offline checks (no provider credentials or infrastructure):

```sh
eval "$(opam env)"
dune build @internal/qualification/runner/runtest
```

The executable tests mutate each namespace/workload observation, denied reads,
malformed output, timeout, missing executable, wrong target, declaration schema,
empty selection and evidence reuse. They are included in `@ci-unit`.

## Assessment and adoption

The concrete duplication is execution and evidence policy, not identical provider
lifecycles. AWS and GCP already share `transaction.py`, while their database delivery
assertions still duplicate policy and GCP repeats capture/freeze/finalise branches.
The AWS CA regression (#1481/#1483) provides a useful failure boundary for this slice.

This prototype is larger than the individual Bash CA assertion. Its benefit is an
explicit observation interface, per-claim accounting and reusable command evidence;
it does not yet demonstrate a net reduction in the complete harness. Do not build a
generic workflow engine or rewrite both providers on that evidence alone.

Review the authoritative interface model first: complete selection, contract inputs,
observation facts, execution identity, evidence provenance and lifecycle supervision.
The proposal gives ownership boundaries, a dependency graph and the migration sequence.
Fixture comparison remains a migration check after that review, rather than the next
architectural deliverable. The live alpha.37 driver and publisher/destroy identity
work (#1485) remain independent. Keep the current harnesses and provider absence
observers unchanged during this design review.
