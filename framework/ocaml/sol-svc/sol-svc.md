# sol-svc

`sol-svc` is Sol's current Cohttp/Eio HTTP adapter. Runtime-neutral workload
authentication, lifecycle state, and request observations live in
[`sol-svc-core`](../sol-svc-core/sol-svc-core.md). This adapter owns route
matching and translates Cohttp/Eio requests and server hooks into those shared
semantics. Route handlers do not import Cohttp types.

The built-in HTTP engine is **cohttp-eio**. Other HTTP adapters can use
`sol-svc-core` directly without depending on this server or router.

---

## Package Structure

```
framework/ocaml/sol-svc/
  lib/
    auth_internal.ml      ← validation (private module)
    peer.ml/.mli          ← peer address of the connection
    request.ml/.mli       ← request type seen by handlers
    response.ml/.mli      ← response helpers
    route.ml/.mli         ← route type and constructors
    route_internal.ml     ← path matching (private module)
    service.ml/.mli       ← HANDLER module type + Make functor
    dune                  ← (name sol_svc) (public_name sol-svc) (wrapped false)
  test/
    test_routing.ml       ← path matching, method dispatch (no server)
    test_auth.ml          ← auth validation logic (no server)
    test_peer.ml
    test_service.ml       ← full round-trip tests (live server, OS-assigned port)
  sol-svc.md
framework/ocaml/sol-svc-core/
  lib/auth.ml/.mli       ← workload token verification and caller authorization
  lib/lifecycle.ml/.mli  ← readiness, draining, and in-flight request semantics
  lib/observation.ml/.mli ← framework-neutral request completion events
  sol-svc-core.md
```

### Module names

`sol-svc` is `(wrapped false)`, like every Sol library, so its modules are used
directly at top level through `sol-svc`'s dependency on `sol-svc-core`: `Auth`,
`Lifecycle`, and `Observation`, alongside `Route`, `Request`, `Response`, and
`Service`. There is no
`Sol_svc` namespace module to open. The names are short; an application that links a
library exporting the same top-level names must alias one side.

---

## Module: `Auth`

### Types

```ocaml
(** Auth levels below are used for the built-in /metrics endpoint. Application
    routes use workload identity by default or explicitly opt out with
    [Route.external_]; application authentication remains application-owned. *)
type jwt_algorithm = [ `HS256 | `RS256 | `ES256 | `ES384 | `ES512 ]

type jwt_key_source =
  | Hs256_secret of string
      (** Shared secret. Verified through [jose]'s HS256 path — never a
          hand-rolled HMAC comparison. *)
  | Jwks_static of string
      (** A JWKS document (RFC 7517), e.g. baked into config for a fixed,
          non-rotating key set. *)
  | Jwks_url of string
      (** HTTPS URL of a JWKS endpoint (Auth0/Cognito/Okta-style). Fetched
          over TLS and cached for 5 minutes; never fetched on every request.
          A URL that is not absolute https:// is a startup [`Config] error
          (SEC-009). *)

type jwt_verified_config =
  { issuer : string
  ; audience : string
  ; algorithms : jwt_algorithm list
  (** Allowlist. A token whose header [alg] is not in this list is rejected
      before any key lookup or signature check runs. *)
  ; key_source : jwt_key_source
  }

type jwt_verification =
  | Verified_signature_required of jwt_verified_config
  | Unverified_dev_only
  (** [Verified_signature_required] is the production-facing mode: signature,
      issuer, audience, and algorithm allowlist are all checked before a
      token is trusted. [Unverified_dev_only] decodes unsigned v1 tokens and
      must only be used for local development and tests. *)

type jwt_config =
  { scopes : string list
  (** Required scopes, e.g. ["write:payments"]. All must be present. *)
  ; verification : jwt_verification
  }

type workload_identity_config =
  { audience : string
  ; callers : (string * string) list
      (** service account ["<namespace>:<serviceaccount>"] -> caller unit *)
  ; trusted_issuer : string
      (** target-established Kubernetes service-account issuer *)
  }

type level =
  [ `Public
  | `Api_key
  | `Jwt of jwt_config
  | `Workload_identity
  ]

(** Resolved identity after successful validation.
    Available in the handler via [Request.t.auth]. *)
type principal =
  | Public
  | Service of { key_id : string }
      (** [key_id] = first 8 chars of validated key. Safe to log. *)
  | User of
      { sub    : string
      ; scopes : string list
      ; claims : Yojson.Safe.t
        (** Full decoded JWT payload as JSON. JWT claims are not always strings
            ([exp] is int, custom claims may be arrays or objects). Returning the
            raw [Yojson.Safe.t] avoids lossy coercion to [(string * string) list]. *)
      }
  | Unit of
      { unit : string
      ; service_account : string
        (** The authenticated caller's Sol unit and the
            ["<namespace>:<serviceaccount>"] it proved. *)
      }

type context = { principal : principal }
```

### Public API

`Auth` exposes workload-authentication primitives from `sol-svc-core`; adapters
resolve signing keys in their own runtime and pass them to shared verification.
The built-in `/metrics` endpoint also uses the `Auth.level` policy values above.

### Auth strategy details

**`` `Public ``** — no validation. Returns `{ principal = Public }` immediately.

**`` `Api_key ``** — validates `X-Api-Key: <key>` header. Key source resolution
(checked in order):

1. `SOL_API_KEY_FILE` env var — path to a file containing the key.
2. `SOL_API_KEY` env var — direct value; for local development only.

Either source is read **once, when the service starts** (`Service.Make.run`), and an
empty or unreadable file is a startup `Config` error. A rotated key therefore takes
effect only after a restart, whichever source is used: `sol secret set` restarts the
workloads for this reason.

`Api_key` applies to the built-in `/metrics` endpoint (`metrics_auth`). It is **not**
applied to application routes: an internal route authenticates with `` `Workload_identity``
and an external route (`Route.external_`) is unauthenticated. Per-route API-key auth is not
implemented; endpoint-level API-key auth is future work.

On success: `Service { key_id }` where `key_id` is the first 8 characters of the
validated key. Missing header or wrong value → 401.

**`` `Jwt config ``** — validates `Authorization: Bearer <token>`.

> **`Unverified_dev_only` does not check the signature.** Anyone can mint a token with
> any `sub` and any scopes, and it will be accepted. It exists for local development
> and tests only. Never put it on a route reachable from outside a developer machine;
> use `Verified_signature_required` (below) everywhere else. `Service.Make.run` refuses
> to start (`Config` error) when a route or `metrics_auth` uses it, unless
> `SOL_ALLOW_UNVERIFIED_JWT=1`. `sol local deploy` sets that on the local cluster only;
> `sol deploy` and GitOps emission never do (SEC-006).

For local development only (`verification = Unverified_dev_only`):

1. Split on `.`, assert three segments (header.payload.signature).
2. Base64url-decode the payload. Parse as JSON with `Yojson.Safe.from_string`.
3. Check `exp` claim (integer) is not in the past (`Unix.gettimeofday`).
4. Check every scope in `config.scopes` is present in the token's `scope` claim
   (space-separated string or JSON array).
5. Return `User { sub; scopes = token_scopes; claims = full_payload_json }`.

For production mode (`verification = Verified_signature_required vconfig`):

1. Parse the token (header + payload) with [`jose`](https://github.com/ulrikstrid/ocaml-jose) —
   no hand-rolled base64/signature comparison anywhere in this path.
2. Reject if the header's `alg` is not in `vconfig.algorithms` — before any key
   lookup or signature check.
3. Resolve the verification key from `vconfig.key_source`:
   - `Hs256_secret secret` — a `jose` HS256 (`Oct`) key built from the shared secret.
   - `Jwks_static doc` — parse the JWKS document, look up by the token's `kid`.
   - `Jwks_url url` — fetch the JWKS over HTTPS (`https-eio`, so RNG seeding and
     CA-bundle handling are inherited, not reimplemented), cache it for 5 minutes,
     look up by `kid`. A fetch or parse failure returns `Server_error` (500) —
     it never falls back to `Unverified_dev_only` behavior. The refresh is
     single-flight under an `Eio.Mutex`: requests that miss the cache together
     wait for one fetch (BUG-053). A `kid` missing from the cached set triggers one
     refetch, at most every 30 s, so a key the IdP just rotated in is accepted; if
     that refetch fails the token is a 401 (the cached set is authoritative). A
     failed fetch is shared with every waiting request for 5 s rather than repeated.
4. Verify the signature via `Jose.Jwt.validate_signature` (which performs no claim
   checks), then validate the temporal claims directly: `nbf`, when present, must
   not be in the future, and `exp`, when present, must not be in the past. Both are
   read as finite NumericDate values (`Int` or `Float` per RFC 7519 §2); a temporal
   claim that is present but not a finite number is a typed 401, never a 500. The
   policy is **no clock-skew allowance** — the issuer and verifier are expected to
   agree on time, so a token outside its declared window is rejected exactly (BUG-079).
5. Check `iss` equals `vconfig.issuer` and `aud` contains `vconfig.audience`
   (`aud` may be a single string or a JSON array per RFC 7519).
6. Check every scope in `config.scopes` is present in the token's `scope` claim.
7. Return `User { sub; scopes = token_scopes; claims = full_payload_json }`.

A payload that is valid JSON but not an object is a 401 in both modes (BUG-053).

HS256 support exists alongside JWKS-based RS256/ES256/ES384/ES512 because plenty
of real deployments are HS256-only — but it always goes through the same `jose`
verification call, never a separate hand-rolled comparison. There is no code
path where an attacker-supplied `alg` can force HMAC verification against an
RSA/EC public key: `jose`'s `Jws.validate` dispatches on the concrete key value
you pass it (a GADT), not on the token's claimed `alg`, so key selection is
driven by `kid` lookup in the JWKS, not by attacker input.

**`` `Workload_identity ``** — DEC-063 Sol-to-Sol authentication. It validates
`Authorization: Bearer <projected ServiceAccount token>` locally:

1. Require the token's `iss` to equal the trusted issuer projected by Sol.
   An issuer outside that target-established trust root is a 401.
2. Resolve the issuer's OIDC discovery document and JWKS using the adapter's
   HTTP runtime and cache. The discovery document must report the exact trusted
   issuer, and its `jwks_uri` must use that issuer's HTTPS origin. Then check
   `aud` equals `config.audience`, and `exp`/`nbf`.
3. Map `sub = system:serviceaccount:<namespace>:<serviceaccount>` to a Sol unit
   through `config.callers`. A valid signature whose subject is not a workload
   identity, or whose unit is not declared, is a 403.

`config.audience` comes from `SOL_UNIT`, `config.callers` from `SOL_CALLED_BY`,
`config.trusted_issuer` from `SOL_TRUSTED_WORKLOAD_ISSUER`, an optional explicit
JWKS URL from `SOL_TRUSTED_WORKLOAD_JWKS_URI` (needed where the provider's
discovery document uses a different JWKS origin, such as Google), and the subject
scheme from `SOL_WORKLOAD_SUBJECT_SCHEME` (default
`kubernetes_service_account`). Sol
derives the first three from the caller-owned `calls` graph or target capability
and projects them into the workload. The Google scheme uses the token's stable
`sub` as the caller subject; an email is never authority. Application code calls `Service.run` without choosing a trusted issuer.
A route that requires workload authentication without any required projection fails
at startup with a `Config` error.

**Error responses:**

| Condition | HTTP status |
|---|---|
| Missing `Authorization` / `X-Api-Key` header | 401 |
| Wrong API key | 401 |
| `SOL_API_KEY` and `SOL_API_KEY_FILE` both unset while `/metrics` uses `` `Api_key `` | the service does not start: `run` returns a `Config` error |
| Workload identity: untrusted `iss`, bad signature, wrong `aud`, missing/expired token | 401 |
| Workload identity: authenticated subject is not a workload identity, or its unit is not allowed by the declared `calls` graph | 403 |
| Workload identity: `SOL_UNIT` unset, no trusted-issuer root supplied, or an invalid/contradictory subject scheme or caller mapping | the service does not start: `run` returns a `Config` error |
| Workload identity: discovery or JWKS fetch/parse/issuer/origin validation fails | 500 (fail closed) |

---

## Module: `Peer`

`Peer` is the outbound helper for declared `[service] calls`.

```ocaml
type error = [ `Config of string ]

type t
val env_var : string -> string
val token_file_env_var : string -> string
val url : t -> (Uri.t, error) result

val headers
  :  env:< fs : Eio.Fs.dir_ty Eio.Path.t ; .. >
  -> peer:t
  -> ?trace_ctx:Obs_trace.t
  -> ?headers:(string * string) list
  -> unit
  -> ((string * string) list, error) result
```

Sol generates `Peer_bindings` from each workload's `[service] calls`. For example,
`Peer_bindings.checkout_checkout_svc` is the handle for
`calls = ["checkout/checkout_svc"]`; `Peer.url` and `Peer.headers` accept that
handle instead of an arbitrary peer name. `Peer.headers` reads the projected
ServiceAccount token named by `CHECKOUT_SVC_TOKEN_FILE` and
attaches it as `Authorization: Bearer`; a declared projection that is missing or
unreadable is a config error, never a fallback. Only a deliberate local
development opt-in (`SOL_ALLOW_PLAINTEXT_PEER_AUTH=1`, reserved in `sol.toml` and
`sol secret set`) lets a caller with no declared projection use `x-api-key` from
`SOL_API_KEY_FILE`/`SOL_API_KEY` instead. Either way it adds `traceparent` when
given the current span context.

---

## Module: `Route`

### Types

```ocaml
type handler = Request.t -> Response.t

type pattern_segment =
  | Literal of string
  | Param of string

type pattern = private
  { source : string
  ; segments : pattern_segment list
  ; trailing_slash : bool
  }

type t =
  { method_ : Request.method_
  ; pattern : pattern
  ; is_external : bool
  ; handler : handler
  }
```

### Public API

```ocaml
val get    : string -> handler -> t
val post   : string -> handler -> t
val put    : string -> handler -> t
val patch  : string -> handler -> t
val delete : string -> handler -> t
val external_ : t -> t
```

Routes require Sol workload identity by default. Mark a route with
`Route.external_` to exempt it from Sol workload authentication; this says
nothing about customer authentication, which remains application-owned. `/healthz`, `/readyz` and
`/metrics` are built in; metrics uses its configured auth policy.

### HTTP method mapping

cohttp exposes `Http.Method.t`, which includes `HEAD`, `OPTIONS`, `CONNECT`,
`TRACE`, and an open `Other of string` catch-all. The framework maps incoming
methods to `Request.method_` internally:

```ocaml
let method_of_http : Http.Method.t -> method_ option = function
  | `GET    -> Some `GET
  | `POST   -> Some `POST
  | `PUT    -> Some `PUT
  | `PATCH  -> Some `PATCH
  | `DELETE -> Some `DELETE
  | _       -> None
```

`None` (HEAD, OPTIONS, etc.) → 405 before routing. This prevents a pattern-match
exception from an unhandled constructor. `HEAD` and `OPTIONS` support deferred to
a later phase.

### Path matching

Route patterns use `:name` segments to declare path parameters:

| Pattern | Request path | Match? | Params |
|---|---|---|---|
| `/users/:id` | `/users/42` | yes | `[("id","42")]` |
| `/users/:uid/posts/:pid` | `/users/1/posts/99` | yes | `[("uid","1");("pid","99")]` |
| `/users` | `/users/` | no | — trailing slash is significant |
| `/users/:id` | `/users/1/extra` | no | — segment count differs |

**Rules:**
- Split path on `/`, filter empty strings. Segment counts must be equal.
- Literal segments match exactly (case-sensitive).
- `:name` captures one segment (no slashes within a capture).
- No wildcards, no optional segments in v1.

**Matching order — strictly top-to-bottom:**
1. Built-in routes: `/healthz` first, then `/metrics`.
2. User routes (`H.routes`) in declaration order; first match wins.
3. Method mismatch on a path that matches → 405.
4. No match → 404.

Built-in routes are not shadowable by user-defined routes. If a user defines
`GET /healthz`, it is never reached. The `/metrics` auth level is configurable
via the `~metrics_auth` argument on `run` (see below) — there is no need to
shadow it with a user route.

---

## Module: `Request`

```ocaml
type t =
  { method_  : method_
  ; path     : string
  ; headers  : Http.Header.t
  (** [Http.Header.t] from the [http] package. Case-insensitive, O(log N) lookup. *)
  ; params   : (string * string) list   (* extracted path params *)
  ; uri      : Uri.t
  (** Full request URI. Use [Uri] functions for query string access. *)
  ; body     : string                   (* pre-read, bounded by max_body_bytes *)
  ; auth     : Auth.context option
  ; trace_ctx : Obs_trace.t option
  (** W3C [traceparent] extracted from the incoming request headers. Pass as
      [?parent] to [Obs_eio.with_span] to link child spans to the caller. *)
  }

val param : t -> string -> string option
(** Path parameter lookup. [param req "id"] → [Some "42"] or [None]. *)

val param_exn : t -> string -> string
(** Path parameter lookup; raises [Not_found] if absent.
    Use when the route pattern guarantees the param — e.g. in a GET /users/:id handler,
    [param_exn req "id"] is always safe. *)

val query_param : t -> string -> string option
(** First value of a query parameter. [query_param req "page"].
    Uses [Uri.get_query_param] — handles percent-decoding, bare flags, multi-value. *)

val query_params : t -> string -> string list
(** All values of a query parameter. [query_params req "tags"] for [?tags=a&tags=b]. *)

val header : t -> string -> string option
(** Case-insensitive header lookup via [Http.Header.get]. [header req "content-type"] *)
```

**`Http.Header.t`:** The `http` package (bundled with cohttp-eio) provides a
normalised header representation with correct case-insensitive semantics and O(log N)
lookup. A plain `(string * string) list` requires manual case folding and O(N) scan.

**`Uri.t` for queries:** `Uri.get_query_param` and `Uri.get_query_params` handle
percent-decoding, multi-value params, and bare flags correctly. Parse once at request
construction time; all query helpers delegate to it.

**Body pre-reading:** The framework reads the entire body before calling the handler,
up to `max_body_bytes`. Streaming bodies deferred to a later phase.

---

## Module: `Response`

```ocaml
type t =
  { status  : int
  ; headers : (string * string) list
  ; body    : string
  }

(* 2xx *)
val ok          : ?headers:(string * string) list -> string -> t   (* 200 *)
val created     : ?headers:(string * string) list -> string -> t   (* 201 *)
val no_content  : t                                                 (* 204 *)

(* 4xx *)
val bad_request     : string -> t   (* 400, Content-Type: text/plain *)
val unauthorized    : t             (* 401 *)
val forbidden       : t             (* 403 *)
val not_found       : t             (* 404 *)
val unprocessable   : string -> t   (* 422, Content-Type: text/plain *)
val payload_too_large : t           (* 413, returned by framework before handler *)

(* 5xx *)
val internal_error  : string -> t   (* 500, Content-Type: text/plain *)

(** [json ?status ?headers body] sets Content-Type: application/json automatically.
    [status] defaults to 200. *)
val json : ?status:int -> ?headers:(string * string) list -> string -> t
```

---

## Module: `Service`

### `HANDLER` module type

```ocaml
module type HANDLER = sig
  val routes : Route.t list
end
```

### `Make` functor

```ocaml
module Make (H : HANDLER) : sig
  val run
    :  env:
         < net : _ Eio.Net.t
         ; clock : _ Eio.Time.clock
         ; fs : Eio.Fs.dir_ty Eio.Path.t
         ; .. >
    -> ?port:int
       (** Default: 8080. Overridden by PORT env var if set (empty counts as unset);
           a PORT that is not a port number is a startup [`Config] error. Pass 0 for
           OS-assigned port (use with [on_listen] in tests). *)
    -> ?metrics_auth:Auth.level
       (** Auth strategy for the built-in /metrics endpoint. Default: [`Public].
           Set to [`Api_key] for production clusters that don't use NetworkPolicy
           to restrict Prometheus scraper access. *)
    -> ?ot:Sol_obs.t
       (** Observability handle. When provided, sol_svc_requests_total/
           sol_svc_request_duration_seconds are emitted per request, and
           GET /metrics renders from the same handle. If omitted,
           GET /metrics → 404. *)
    -> ?observe:Observation.sink
       (** Framework-neutral request completion observations. *)
    -> ?max_body_bytes:int
       (** Maximum request body size in bytes. Default: 10_485_760 (10 MB).
           Requests exceeding this limit receive 413 before the handler is called. *)
    -> ?drain_timeout_s:float
       (** Seconds to wait for active requests after the listener closes. Default: 30.0. *)
    -> ?shutdown_delay_s:float
       (** On a stop, GET /readyz turns 503 at once and the listener keeps serving
           for this long before it closes (INFRA-073). Default: 5.0. Keep
           shutdown_delay_s + drain_timeout_s under terminationGracePeriodSeconds
           (Sol renders 45). *)
    -> ?stop:unit Eio.Promise.t
       (** External stop signal. Resolve to request graceful shutdown: readiness
           turns 503, the listener closes after [shutdown_delay_s], and in-flight
           requests get up to [drain_timeout_s] before forced cancellation. *)
    -> ?on_listen:(int -> unit)
       (** Called with the actual bound port immediately before the accept loop.
           Use with [~port:0] in tests to discover the OS-assigned port. *)
    -> unit
    -> (unit, run_error) result
end
```

`run` returns only when the accept loop has stopped and drained — normally because
`?stop` was resolved or a shutdown signal arrived. The functional
`Service.run` (routes passed directly rather than through a `HANDLER` module) takes
the same arguments with the routes list first, and the same
`(unit, run_error) result`.

---

## Runtime Loop

### Startup sequence

```
1. Resolve port: PORT env var > ~port arg > 8080 (a malformed PORT → `Config` error)
2. Bind: Eio.Net.listen ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.any, port))
3. Discover actual port via Eio.Net.listening_addr (handles port 0)
4. Call on_listen actual_port (if provided)
5. Log "sol-svc listening on :<port>" to stderr
6. Enter structured shutdown + accept loop
```

### Structured shutdown model

The design requires two properties:
- Receiving SIGTERM while idle (no active connections) must exit promptly, not wait
  for the next TCP connection to arrive.
- Active connections must drain cleanly after the accept loop stops, but the drain
  window must cap out at `drain_timeout_s` — the server must not hang indefinitely
  if connections are slow.

**The flaw in a pure nested-switch approach:** forking the timeout fiber into
`connections_sw` prevents early exit — the timeout keeps the switch alive even
after all connections finish. An `Eio.Fiber.first` drain race is required instead.

**The flaw in a `Promise.peek` accept loop:** `Eio.Net.accept_fork` blocks until
a connection arrives. SIGTERM on an idle server resolves the stop promise, but the
loop does not observe it until the next connection — potentially never. The signal
fiber must cancel the accept switch directly.

**Correct model — three scopes:**

```
outer_sw         — entire server lifespan
  accept_sw      — governs only the accept loop; signal fiber cancels this
  connections_sw — governs all connection handler fibers; outlives accept_sw
```

```ocaml
Eio.Switch.run (fun outer_sw ->
  Eio.Switch.run (fun connections_sw ->
    let active       = Atomic.make 0 in
    let all_done, all_done_r = Eio.Promise.create () in

    (try
      Eio.Switch.run (fun accept_sw ->
        (* Signal fiber: cancels the accept loop, not the connection handlers *)
        Eio.Fiber.fork ~sw:outer_sw (fun () ->
          await_signal ();
          Eio.Switch.turn_off accept_sw Exit
        );
        while true do
          Eio.Net.accept_fork ~sw:connections_sw socket ~on_error:log_exn
            (fun conn _addr ->
              Atomic.incr active;
              Fun.protect
                ~finally:(fun () ->
                  (* Resolve all_done when the last connection finishes *)
                  if Atomic.fetch_and_add active (-1) = 1 then
                    (try Eio.Promise.resolve all_done_r ()
                     with Invalid_argument _ -> ()))
                (fun () -> handle_connection conn))
        done
      )
    with Exit | Eio.Cancel.Cancelled _ -> ());

    (* Accept loop stopped. Drain: race all handlers finishing vs timeout.
       Eio.Fiber.first runs both fibers in its own internal switch — they do
       NOT live in connections_sw, so neither extends the switch lifetime. *)
    if Atomic.get active = 0 then
      (try Eio.Promise.resolve all_done_r () with Invalid_argument _ -> ());

    Eio.Fiber.first
      (fun () -> Eio.Promise.await all_done)
      (fun () ->
        Eio.Time.sleep env#clock drain_timeout_s;
        Eio.Switch.turn_off connections_sw Exit)
  )
)
```

**Why `Eio.Fiber.first` is correct here:**
- `Eio.Fiber.first` runs its two fibers in its own internal switch, independent of
  `connections_sw`. The timeout fiber does not hold `connections_sw` open.
- If all connections finish first: `all_done` resolves, `Eio.Fiber.first` cancels
  the timeout fiber and returns.
- If timeout fires first: `Eio.Switch.turn_off connections_sw Exit` cancels all
  remaining connection fibers, then `Eio.Fiber.first` completes.
- Zero-connection idle server: `Atomic.get active = 0` after the accept loop
  pre-resolves `all_done_r`; `Eio.Fiber.first` returns immediately.
- The `Invalid_argument` catch guards against the rare race where the last
  connection finishes between the `active = 0` check and the manual resolve.

**Note on `await_signal`:** The exact OCaml surface depends on the Eio version in
use (`Eio_unix.Signal`, `Sys.set_signal` from within a fiber, etc.). The contract
is: block until SIGTERM or SIGINT, then return. Validate against the Eio version
in use at implementation time.

### Connection lifecycle (single request)

```
TCP accept
  └─ map Http.Method.t → Request.method_
  │     unknown method  → 405, close
  └─ read headers       (Http.Header.t)
  └─ read body, enforce max_body_bytes
  │     exceeded        → 413, close (do not call handler)
  └─ parse URI          (Uri.of_string)
  └─ match method + path
  │     no match        → 404, close
  │     method mismatch → 405, close
  └─ validate auth      (Auth internal)
  │     Unauthorized    → 401, close
  │     Forbidden       → 403, close
  │     JWKS unavailable → 500, close
  └─ call handler
  │     exception       → 500, log via obs, close
  │  (any exception from the steps above, outside the handler too → 500, logged;
  │   every request gets a response — BUG-053)
  └─ write response     (cohttp-eio)
  └─ close connection
```

Keep-alive: not supported in v1. One request per TCP connection.

---

## Built-in Endpoints

Checked before any route in `H.routes`. Cannot be shadowed by user routes.

| Path | Method | Auth | Response |
|---|---|---|---|
| `/healthz` | GET | `` `Public `` | 200 `{"status":"ok"}`, `application/json` (liveness, startup) |
| `/readyz` | GET | `` `Public `` | 200 `{"status":"ready"}`; 503 `{"status":"shutting down"}` once a stop begins (readiness) |
| `/metrics` | GET | `~metrics_auth` arg | 200 Prometheus text (if renderer wired), else 404 |

**`/healthz` and `/readyz` always `Public`:** k8s probes call them without
credentials. `/healthz` is for the `startupProbe` and `livenessProbe`; `/readyz` is the
readiness endpoint (INFRA-073). Sol's rendered manifests use `/readyz` for
workloads with an explicitly declared language; when language is omitted, the
readiness probe falls back to `/healthz`. On SIGTERM (or `?stop`) `/readyz`
turns 503 while the listener keeps serving for `shutdown_delay_s`, so the pod
leaves the Service's endpoints before it stops accepting. Closing the listener
at once, as before, refused requests that kube-proxy was still routing to the
pod.

**`/healthz` not `/health`:** The `z` suffix is the k8s control-plane convention
(kube-apiserver, etcd, kubelet). The ROADMAP listed `/health`; this spec supersedes it.

**`/metrics` auth is configurable:** Pass `~metrics_auth:\`Api_key` if the cluster
does not use `NetworkPolicy` to restrict Prometheus scraper access. Default is
`` `Public `` because in a properly configured cluster, the `NetworkPolicy` is the
access control boundary. The `~metrics_auth` arg eliminates the need for user-defined
shadowing routes, which the routing order would make unreachable anyway.

---

## Dune Setup

The build files are `framework/ocaml/sol-svc/lib/dune` and `framework/ocaml/sol-svc/test/dune`;
they are the source of truth for the library's dependencies. Note `(wrapped false)` and
`(private_modules auth_internal route_internal)` in the library stanza.

**opam packages:** `cohttp-eio`, `http` (bundled with cohttp), `uri`, `yojson`.

---

## Test Plan

All pure-logic tests run without a server. Only `test_service.ml` starts a live
listener on an OS-assigned port.

### Port discovery pattern in `test_service.ml`

```ocaml
let actual_port = ref 0 in
let server_ready, resolve_ready = Eio.Promise.create () in
Eio.Fiber.fork ~sw (fun () ->
  let module S = Service.Make (H) in
  ignore
    (S.run ~env ~port:0 ~stop
       ~on_listen:(fun p ->
         actual_port := p;
         Eio.Promise.resolve resolve_ready ())
       ()));
Eio.Promise.await server_ready;
(* fire client requests at localhost:!actual_port *)
```

### `test_routing.ml`

- Exact literal match routes to correct handler
- Trailing slash distinction: `/users` ≠ `/users/`
- Single param: `/users/:id` vs `/users/42` → `params = [("id","42")]`
- Multi-param correct extraction
- Method discrimination: GET route vs POST request → 405
- Unknown HTTP method (OPTIONS) → 405
- First-match-wins: two overlapping user patterns, first wins
- Built-in `/healthz` not reachable via user route of same path
- Unknown path → 404

### `test_auth.ml`

- DEC-063 workload identity: declared caller accepted; undeclared caller 403;
  untrusted issuer, wrong audience, missing token, and bad signature 401;
  non-service-account subject 403

### `test_service.ml`

- GET `/healthz` → 200 `{"status":"ok"}`
- GET `/metrics` without renderer → 404
- GET `/metrics` with renderer → 200 Prometheus text
- GET `/metrics` with `~metrics_auth:\`Api_key`, correct key → 200
- GET `/metrics` with `~metrics_auth:\`Api_key`, no key → 401
- POST body under limit → handler receives full body
- POST body over `max_body_bytes` → 413, handler not called
- External route without a Sol workload token → 200, boundary reported as external
- Handler raising exception → 500, server continues accepting
- Unknown path → 404; wrong method → 405
- Graceful shutdown: SIGTERM turns `/readyz` 503, keeps serving for `shutdown_delay_s`, then stops new accepts; active request completes cleanly
- Drain timeout: active request that exceeds drain window is cancelled

---

## Example Usage

```ocaml
(* app/payments/charge-svc/bin/main.ml -- sol-svc's modules are unwrapped, so there is
   nothing to open *)

let handle_charge req =
  let _body = req.Request.body in
  (* parse body, validate, charge ... *)
  Response.json ~status:201 {|{"status":"charged"}|}

let handle_internal req =
  let _who = req.Request.auth.Auth.principal in
  Response.json ~status:201 {|{"status":"charged"}|}

module H = struct
  let routes =
    [ Route.external_ (Route.post "/payments/charge" handle_charge)
    ; Route.post "/payments/internal/charge" handle_internal
    ]
end

module S = Service.Make (H)

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"charge-svc"
      ()
  in
  S.run ~env ~ot:obs ()
  |> Result.map_error Service.run_error_to_string
  |> function
  | Ok () -> ()
  | Error e -> failwith e
```

---

## Out of Scope (v1)

- **Tokens without `exp`** — accepted without an expiry check; issue tokens with `exp`
- **HTTPS / TLS** — terminate at k8s ingress; plain HTTP inside the cluster
- **HTTP keep-alive** — one request per TCP connection
- **Request body streaming** — body pre-read to string (bounded by `max_body_bytes`)
- **HEAD / OPTIONS / CONNECT / TRACE** — unknown methods return 405
- **Routing trie** — linear scan only; add if >100 routes appears in profiling
- **Path wildcards / optional segments** — strict segment-count matching only
- **User middleware chain** — auth is the only framework middleware in v1
- **Auto-metrics per route** (request count, latency, error rate) — Phase 3
- **WebSocket / SSE** — HTTP/1.1 request-response only
- **Multi-domain parallelism** — single Eio domain; add `Domain_manager` if benchmarks show need
- **Request ID propagation** — Phase 3 observability auto-wiring
