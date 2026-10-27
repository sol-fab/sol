# sol-svc-core

Runtime-neutral operational, security, and observation semantics for Sol HTTP
services. This package contains no HTTP server, router, or asynchronous runtime.

## Package structure

- `Auth` parses and verifies Sol workload JWTs and authorizes the resulting
  service-account identity against the caller policy. It also decodes the
  CLI-projected caller set so adapters share its fail-closed parsing behavior.
- `Lifecycle` tracks readiness, draining, and in-flight requests using OCaml
  atomics.
- `Observation` defines the framework-neutral HTTP request completion event,
  including the Sol `Internal | External` boundary and optional Sol workload
  principal.

The current `sol-svc` Cohttp/Eio adapter depends on this package. Other HTTP
framework adapters can depend on `sol-svc-core` without taking that server or
runtime dependency.

## Public API

```ocaml
type subject_scheme =
  | Kubernetes_service_account
  | Google_oidc_service_account

type workload_identity_config =
  { audience : string
  ; callers : (string * string) list
  ; trusted_issuer : string
  ; trusted_jwks_uri : string option
  ; subject_scheme : subject_scheme
  }

type key_request =
  { issuer : string
  ; key_id : string option
  }

val callers_of_projection : string -> (string * string) list
val begin_workload_auth
  : workload_identity_config
  -> authorization:string option
  -> (key_request * pending_workload_auth, error) result
val finish_workload_auth
  : pending_workload_auth
  -> jwks:Jose.Jwks.t
  -> now:float
  -> (context, error) result
```

`Lifecycle` exposes readiness, shutdown, draining, and in-flight request leases.
`Observation` exposes `Internal | External` request events and an optional Sol
workload principal separately.

## Configuration

The adapter supplies the callee audience, callers derived from Sol's canonical
`calls` graph, and the issuer established by the deployment target. The
core parses neither process environment nor framework-specific request objects.

## Example usage

An adapter extracts the bearer value from its native request, calls
`begin_workload_auth`, resolves the returned issuer with its own runtime's OIDC
discovery, HTTP client, and key cache, then calls `finish_workload_auth` with the
JWKS and runtime clock. It enforces the returned error or passes the Sol principal to the
application. An external route skips this Sol auth flow and continues through
application middleware.

## Security flow

`Auth.begin_workload_auth` parses the bearer token and requires its unverified
issuer to equal the one trusted issuer projected by Sol. The adapter resolves
signing keys using that issuer and its own runtime's HTTP and cache mechanisms.
It then passes the keys to `Auth.finish_workload_auth`, which verifies the signature, issuer,
audience, time claims, workload subject, and caller authorization.

The core deliberately does not fetch keys, cache them, synchronize refreshes,
or own a clock. Callers supply `now` to the final verification step.

## HTTP boundary

Internal requests require Sol workload authentication by default. An adapter
marks an application route `External` to bypass only Sol workload authentication;
application authentication remains application-owned. Observations report the
boundary independently from a Sol workload principal.

## Out of scope

- HTTP routing, request/response conversion, and listener ownership.
- Customer JWTs, sessions, webhook signatures, and other application auth.
- JWKS network clients, caches, refresh synchronization, and async runtimes.
