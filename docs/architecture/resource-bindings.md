# Resource bindings: durable decisions

This record keeps only decisions that are not obvious from the implementation. The
executable contract lives in the typed configuration, deployment plan, validation, and
tests; this page does not narrate their current structure or provider behavior.

## Decisions

- A unit declares the resources it uses. A target resolves each resource's physical
  binding. The runtime delivers only inputs the unit declared.
- A resource has one producer and one binding selection. A target override replaces the
  whole binding atomically; conflicting producers fail rather than choosing a winner.
- Sol owns the declaration, binding selection, access requirements, and delivery of
  managed resources. Externally owned resources are not provisioned by Sol; their physical
  identifiers and access configuration belong to the target.
- External resource access is expressed in provider terms. Applications use native
  provider SDKs; Sol does not expose a provider-neutral queue or object client.
- Provider-specific bindings are deliberate. There is no universal resource identifier.
- Planning selects credential sources; execution obtains values. Uncertainty is an error,
  not a reason to substitute a default.

Implementation details, current support gaps, and verification evidence belong in the code,
tests, issues, and qualification records—not here.
