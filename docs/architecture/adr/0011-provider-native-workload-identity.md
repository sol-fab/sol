# ADR 0011: Provider-native workload identity

- **Status:** Proposed
- **Date:** 2026-10-27
- **Decision owner:** operator
- **Related:** ADR 0009 (one product contract), ADR 0010 (execution backends),
  DEC-062 (workload authorization), DEC-063 (Sol-to-Sol identity),
  `docs/architecture/proposals/serverless-execution.md`

## Context

The first Cloud Run HTTP slice exposed a real integration blocker. The existing
`sol-svc` workload identity accepts only a Kubernetes subject:

```text
system:serviceaccount:<namespace>:<service-account>
```

`SOL_UNIT` and `SOL_TRUSTED_WORKLOAD_ISSUER` are enough for the service to
start, but not enough for an authorized call. On Cloud Run, the caller is a
Google OIDC workload, not a Kubernetes ServiceAccount. `/readyz` returned 200
while `/quote` remained 401; that is a failed identity integration, not a
partial pass.

The current contract conflates two separate concerns:

- **Sol identity:** which workload is calling, what it may invoke, and which
  issuer/audience/subject are trusted.
- **Kubernetes representation:** how a Kubernetes ServiceAccount happens to be
  encoded in a token subject.

Cloud Run must not be supported by adding a provider-specific escape hatch to
the Kubernetes subject check. The identity contract has to separate the
representation from the authorization model.

## Decision

### 1. One identity model, explicit representation

The shared runtime accepts a declared identity configuration with four
independent parts:

- **issuer:** the authority that signed the token;
- **audience:** the Sol application audience the token is for;
- **subject scheme:** how the authenticated workload is represented;
- **caller policy:** which subjects may invoke the protected operation.

The initial supported subject schemes are:

| Scheme | Subject representation | Intended environment |
|---|---|---|
| `kubernetes_service_account` | `system:serviceaccount:<namespace>:<service-account>` | Kubernetes |
| `google_oidc_service_account` | Google's stable workload subject from the token | Cloud Run |

The exact wire names are an implementation detail; the important contract is
that the scheme is explicit and cannot be inferred from a string prefix alone.

### 2. Kubernetes behavior is unchanged

For `kubernetes_service_account`:

- the exact `system:serviceaccount:` prefix is still required;
- caller entries remain `unit=<namespace>:<service-account>`;
- existing Kubernetes tokens, tests and authorization behavior are unchanged;
- a subject from another scheme is not accepted merely because its text
  resembles an authorized Kubernetes ServiceAccount.

The existing test that rejects a non-workload subject remains valid for the
Kubernetes scheme.

### 3. Google identity for Cloud Run

For `google_oidc_service_account`:

- the adapter configures the trusted issuer. Google documents both
  `https://accounts.google.com` and `accounts.google.com` as valid spellings
  for Google ID tokens; the Google scheme may canonicalize only those two
  spellings to one authority. Kubernetes remains exact-match. Any other value
  is rejected.
- the application audience is explicit and is **not** assumed to equal the
  Cloud Run ingress audience. The Cloud Run service URL audience used by
  ingress IAM is a different audience from the Sol application audience.
- the stable subject is Google's `sub` claim. `email` is not identity
  authority; it is at most display/metadata. The implementation must establish
  the stability of `sub` for the service-account workload and must not fall
  back to an email or unverified claim.
- the caller policy maps the scheme's subject to a Sol caller unit. An unknown
  subject is authenticated but unauthorized, distinct from a missing or
  malformed token.
- the adapter may use Google's discovery/JWKS endpoint to validate the token;
  the application does not hard-code a second trust root.

The exact Google claim set must be recorded in the implementation tests,
including `iss`, `aud`, `sub`, `exp`, and the absence of a Kubernetes subject.
The implementation uses a locally generated RSA key for the token fixture; it
does **not** establish that Google will issue the expected production token or
that the intended caller can obtain a token with the Sol application audience.
See Google's
[OpenID Connect documentation](https://developers.google.com/identity/openid-connect/openid-connect).

### 4. Audience and ingress are independent

Cloud Run IAM and Sol application authorization serve different roles:

- Cloud Run IAM can decide who reaches the service;
- Sol validates the token presented to the protected route and enforces its
  caller policy.

The Cloud Run URL audience and the Sol application audience need not be the
same. If one token cannot satisfy both, the options are:

1. use an application-level token with the Sol audience while allowing the
   request to reach the container; or
2. use an explicit token-exchange/proxy component.

The implementation must not disable application validation, treat every request
that reached the container as trusted, or infer trust from network location.
For the experimental slice, option 1 is the default: the application token is
validated by Sol; Cloud Run ingress IAM may be configured separately or left out
while that is documented and tested.

### 5. Rejection and confused-deputy rules

The protected route must reject:

- a missing or malformed authorization header;
- an expired or not-yet-valid token;
- a wrong issuer;
- a wrong application audience;
- an unsupported subject scheme;
- a valid token from a trusted issuer whose subject is not in the caller policy;
- a token issued for another service/audience, even from the same issuer;
- a request that is only authenticated by Cloud Run ingress but lacks the
  application-level identity expected by Sol.

Authentication failures are 401; an authenticated but unauthorized subject is
403. A token that is valid for a different audience must not be accepted just
because its issuer is trusted.

### 6. Adapter configuration and failure

The execution adapter supplies the identity configuration; the application
does not implement provider-specific IAM logic. The current environment names
may be used internally, but they are not a universal provider API.

Missing, contradictory or unsupported identity configuration must fail:

- before deployment where it can be validated statically;
- at startup/readiness where it requires provider state;
- never by declaring a workload healthy without an authenticated caller test.

### 7. Local development

Local development uses the existing Kubernetes subject scheme against a local
cluster and an explicitly local issuer. It must not trust the production issuer
implicitly, and it must not require production credentials. The local test path
exercises the same caller-policy semantics as a real backend, using locally
established identities; no separate unverified local scheme is introduced.

### 8. Implementation gates

The contract change is accepted only when:

| Gate | Evidence |
|---|---|
| Contract | Issuer, audience, subject scheme and caller policy are separate typed/configured concerns. |
| Kubernetes regression | Existing Kubernetes tests and authorization remain unchanged. |
| Google identity | A real Google workload token is validated and mapped to an authorized Sol caller. |
| Negative authorization | Missing, malformed, expired, wrong-issuer, wrong-audience, wrong-scheme and unauthorized tokens are rejected. |
| Confused deputy | A token valid for another service/audience does not become valid here. |
| Configuration safety | Missing/contradictory identity configuration fails closed before a healthy deployment is claimed. |
| Local development | Local identity is explicit and does not trust the production issuer. |
| End-to-end | An authorized `/quote` request succeeds and an unauthorized request fails; `/readyz` alone is not evidence. |

## Rejected alternatives

### Cloud Run IAM-only delegation

This would make Sol's application-level caller policy dependent on ingress
configuration and treat every request that reaches the container as trusted. It
may be a valid future product decision, but it changes the security boundary and
is not adopted to unblock the first adapter.

### Token-exchange/proxy first

An additional identity-bearing component adds a trust boundary and failure
surface. It is premature until direct validation of a provider-native token has
been attempted and its precise limitation is recorded.

## Consequences

- `sol-svc-core` needs a typed identity configuration and scheme-aware subject
  mapping, while preserving the Kubernetes default.
- The Cloud Run adapter must project issuer, application audience, scheme and
  caller policy, and must not rely on ingress IAM as application authorization.
- The Cloud Run HTTP slice is blocked until this contract and its tests exist;
  the deployment lifecycle work is separate.
- The queue and production-profile claims remain separate gates.

## Non-goals

- Provider-native identity for every cloud.
- Changing the Kubernetes authorization model.
- Treating Cloud Run ingress as sufficient application authorization.
- A token-exchange service.
- Production-profile qualification.
