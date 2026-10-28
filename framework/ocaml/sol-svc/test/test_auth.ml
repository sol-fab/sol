let () = Mirage_crypto_rng_unix.use_default ()
let workload_issuer = "https://kubernetes.default.svc"
let workload_audience = "checkout/checkout-svc"
let caller_service_account = "myapp-payments:charge-svc"
let caller_subject = "system:serviceaccount:" ^ caller_service_account
let caller_unit = "payments/charge-svc"
let rsa_priv_jwk = Jose.Jwk.make_priv_rsa (Mirage_crypto_pk.Rsa.generate ~bits:2048 ())
let rsa_jwks = Jose.Jwks.{ keys = [ Jose.Jwk.pub_of_priv rsa_priv_jwk ] }

(* A second issuer key, and the JWKS an issuer serves while both keys overlap
   during a rotation. *)
let rotated_priv_jwk =
  Jose.Jwk.make_priv_rsa (Mirage_crypto_pk.Rsa.generate ~bits:2048 ())
;;

let rotated_jwks =
  Jose.Jwks.
    { keys = [ Jose.Jwk.pub_of_priv rsa_priv_jwk; Jose.Jwk.pub_of_priv rotated_priv_jwk ]
    }
;;

(* The identity key `Auth_internal.get_jwks` caches workload-issuer keys under. *)
let workload_jwks_cache_key = "sol-workload-issuer:" ^ workload_issuer

let workload_identity
      ?(callers = [ caller_service_account, caller_unit ])
      ?(scheme = Auth.Kubernetes_service_account)
      ?(issuer = workload_issuer)
      ?jwks_uri
      ()
  =
  Auth.
    { audience = workload_audience
    ; callers
    ; trusted_issuer = issuer
    ; trusted_jwks_uri = jwks_uri
    ; subject_scheme = scheme
    }
;;

let google_issuer = "https://accounts.google.com"
let google_subject = "123456789012345678901"
let google_email = "caller@example.iam.gserviceaccount.com"

let google_identity ?(callers = [ google_subject, caller_unit ]) () =
  workload_identity
    ~callers
    ~scheme:Auth.Google_oidc_service_account
    ~issuer:google_issuer
    ()
;;

let sign_payload ?(key = rsa_priv_jwk) payload =
  match Jose.Jwt.sign ~payload key with
  | Ok token -> Jose.Jwt.to_string token
  | Error (`Msg message) -> failwith ("sign_workload: " ^ message)
;;

let sign_workload
      ?(key = rsa_priv_jwk)
      ?(sub = caller_subject)
      ?(aud = workload_audience)
      ?(iss = workload_issuer)
      ?email
      ?azp
      ?(exp_offset = 3600.0)
      ()
  =
  sign_payload
    ~key
    (`Assoc
        ((("sub", `String sub)
          :: ("iss", `String iss)
          :: ("aud", `String aud)
          ::
          (match email with
           | None -> []
           | Some email -> [ "email", `String email ]))
         @ (match azp with
            | None -> []
            | Some azp -> [ "azp", `String azp ])
         @ [ "exp", `Int (int_of_float (Unix.gettimeofday () +. exp_offset)) ]))
;;

let unsigned_none_token claims =
  let encode value =
    Base64.encode_string
      ~pad:false
      ~alphabet:Base64.uri_safe_alphabet
      (Yojson.Safe.to_string value)
  in
  encode (`Assoc [ "alg", `String "none"; "typ", `String "JWT" ])
  ^ "."
  ^ encode claims
  ^ "."
;;

let headers token = Http.Header.of_list [ "authorization", "Bearer " ^ token ]

let with_env bindings f =
  let previous = List.map (fun (key, _) -> key, Sys.getenv_opt key) bindings in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (key, value) ->
           match value with
           | Some value -> Unix.putenv key value
           | None -> Unix.putenv key "")
        previous)
    (fun () ->
       List.iter (fun (key, value) -> Unix.putenv key value) bindings;
       f ())
;;

let test_service_reads_the_sol_projected_trust_and_call_policy () =
  with_env
    [ "SOL_UNIT", workload_audience
    ; "SOL_CALLED_BY", caller_unit ^ "=" ^ caller_service_account
    ; "SOL_TRUSTED_WORKLOAD_ISSUER", workload_issuer
    ; "SOL_WORKLOAD_SUBJECT_SCHEME", "kubernetes_service_account"
    ]
    (fun () ->
       match
         Service.For_testing.workload_identity_config
           [ Route.get "/probe" (fun _ -> Response.ok "") ]
           `Public
       with
       | Error (`Config message) -> Windtrap.fail message
       | Ok None -> Windtrap.fail "an internal route did not request workload identity"
       | Ok (Some config) ->
         Windtrap.equal
           Windtrap.string
           ~msg:"projected audience"
           workload_audience
           config.audience;
         Windtrap.equal
           (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
           ~msg:"calls-derived caller set"
           [ caller_service_account, caller_unit ]
           config.callers;
         Windtrap.equal
           Windtrap.string
           ~msg:"target capability issuer projection"
           workload_issuer
           config.trusted_issuer;
         Windtrap.equal
           Windtrap.string
           ~msg:"explicit Kubernetes subject scheme"
           "kubernetes_service_account"
           (Auth.subject_scheme_to_string config.subject_scheme))
;;

let test_internal_route_without_target_issuer_fails_startup () =
  with_env
    [ "SOL_UNIT", workload_audience
    ; "SOL_CALLED_BY", ""
    ; "SOL_TRUSTED_WORKLOAD_ISSUER", ""
    ; "SOL_WORKLOAD_SUBJECT_SCHEME", "kubernetes_service_account"
    ]
    (fun () ->
       match
         Service.For_testing.workload_identity_config
           [ Route.get "/probe" (fun _ -> Response.ok "") ]
           `Public
       with
       | Error (`Config message) ->
         Windtrap.is_true
           ~msg:"startup failure names the missing target projection"
           (List.mem "SOL_TRUSTED_WORKLOAD_ISSUER" (String.split_on_char ' ' message))
       | Ok _ -> Windtrap.fail "an internal route started without a target-trusted issuer");
  with_env
    [ "SOL_UNIT", ""
    ; "SOL_CALLED_BY", ""
    ; "SOL_TRUSTED_WORKLOAD_ISSUER", ""
    ; "SOL_WORKLOAD_SUBJECT_SCHEME", "kubernetes_service_account"
    ]
    (fun () ->
       match
         Service.For_testing.workload_identity_config
           [ Route.external_ (Route.get "/probe" (fun _ -> Response.ok "")) ]
           `Public
       with
       | Ok None -> ()
       | Error (`Config message) -> Windtrap.fail message
       | Ok (Some _) ->
         Windtrap.fail "an external-only service requested Sol workload identity")
;;

let dispatch
      ?identity
      ?(callers = [ caller_service_account, caller_unit ])
      ?(fetch_workload_jwks = fun _ -> Ok rsa_jwks)
      ?on_boundary
      headers
  =
  let identity =
    match identity with
    | Some identity -> identity
    | None -> workload_identity ~callers ()
  in
  let handler req =
    match req.Request.auth with
    | Some { Auth.principal = Auth.Unit { unit; service_account }; _ } ->
      Response.json
        (Yojson.Safe.to_string
           (`Assoc [ "unit", `String unit; "service_account", `String service_account ]))
    | _ -> Response.internal_error "workload principal missing"
  in
  Service.For_testing.dispatch
    ~fetch_workload_jwks
    ~workload_identity:identity
    ?on_boundary
    ~routes:[ Route.get "/probe" handler ]
    (Http.Request.make ~meth:`GET ~headers "/probe")
    (Cohttp_eio.Body.of_string "")
;;

let test_declared_workload_authenticates_and_authorizes () =
  let boundary = ref None in
  let response =
    dispatch ~on_boundary:(fun b -> boundary := Some b) (headers (sign_workload ()))
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"internal request boundary"
    (Some "internal")
    (Option.map Observation.boundary_to_string !boundary);
  Windtrap.equal Windtrap.int ~msg:"status" 200 response.Response.status;
  let payload = Yojson.Safe.from_string response.Response.body in
  Windtrap.equal
    Windtrap.string
    ~msg:"caller unit"
    caller_unit
    (Yojson.Safe.Util.member "unit" payload |> Yojson.Safe.Util.to_string)
;;

let test_undeclared_caller_is_forbidden () =
  Windtrap.equal
    Windtrap.int
    ~msg:"authenticated caller outside graph → 403"
    403
    (dispatch ~callers:[] (headers (sign_workload ()))).Response.status
;;

let test_untrusted_issuer_is_unauthorized () =
  let fetched = ref false in
  let response =
    dispatch
      ~fetch_workload_jwks:(fun _ ->
        fetched := true;
        Ok rsa_jwks)
      (headers (sign_workload ~iss:"https://attacker.example" ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"issuer is not trusted → 401"
    401
    response.Response.status;
  Windtrap.is_false ~msg:"an untrusted issuer never reaches key resolution" !fetched
;;

let test_discovery_must_bind_keys_to_the_trusted_issuer () =
  let parse body =
    Service.For_testing.jwks_uri_of_discovery ~issuer:workload_issuer body
  in
  let good_uri = workload_issuer ^ "/keys" in
  let discovery issuer jwks_uri =
    Yojson.Safe.to_string
      (`Assoc [ "issuer", `String issuer; "jwks_uri", `String jwks_uri ])
  in
  (match parse (discovery workload_issuer good_uri) with
   | Ok uri -> Windtrap.equal Windtrap.string ~msg:"discovered JWKS URI" good_uri uri
   | Error error -> Windtrap.fail error);
  (match parse (discovery "https://attacker.example" good_uri) with
   | Error error ->
     Windtrap.is_true
       ~msg:"mismatched discovery issuer is rejected"
       (String.equal
          error
          "OIDC discovery issuer does not match the trusted target issuer")
   | Ok _ -> Windtrap.fail "a mismatched discovery issuer was accepted");
  (match parse (discovery workload_issuer "https://attacker.example/keys") with
   | Error error ->
     Windtrap.is_true
       ~msg:"cross-origin JWKS endpoint is rejected"
       (String.equal
          error
          "OIDC discovery jwks_uri must use the trusted issuer's HTTPS origin")
   | Ok _ -> Windtrap.fail "a cross-origin JWKS endpoint was accepted");
  match parse (discovery workload_issuer "http://kubernetes.default.svc/keys") with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "an insecure JWKS endpoint was accepted"
;;

let test_jwks_resolution_failure_fails_closed () =
  Service.For_testing.reset_jwks_cache ();
  let response =
    dispatch
      ~fetch_workload_jwks:(fun _ -> Error "issuer discovery unavailable")
      (headers (sign_workload ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"key resolution failure does not authenticate the request"
    500
    response.Response.status;
  Service.For_testing.reset_jwks_cache ()
;;

let test_wrong_audience_is_unauthorized () =
  Windtrap.equal
    Windtrap.int
    ~msg:"wrong audience → 401"
    401
    (dispatch (headers (sign_workload ~aud:"another/unit" ()))).Response.status
;;

let test_tampered_signature_is_unauthorized () =
  let token = sign_workload () in
  let parts = String.split_on_char '.' token in
  let tampered =
    match parts with
    | [ header; payload; signature ] ->
      let replacement = if signature.[0] = 'A' then 'B' else 'A' in
      String.concat
        "."
        [ header
        ; payload
        ; String.make 1 replacement ^ String.sub signature 1 (String.length signature - 1)
        ]
    | _ -> failwith "signed token should have three parts"
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"signature must verify → 401"
    401
    (dispatch (headers tampered)).Response.status
;;

let test_non_workload_subject_is_forbidden () =
  Windtrap.equal
    Windtrap.int
    ~msg:"verified user subject → 403"
    403
    (dispatch (headers (sign_workload ~sub:"customer-123" ()))).Response.status
;;

let test_missing_token_is_unauthorized () =
  Windtrap.equal
    Windtrap.int
    ~msg:"missing bearer → 401"
    401
    (dispatch (Http.Header.of_list [])).Response.status
;;

let test_jwks_cache_reuses_resolved_keys () =
  Service.For_testing.reset_jwks_cache ();
  let fetches = ref 0 in
  let fetch issuer =
    incr fetches;
    if issuer = workload_issuer then Ok rsa_jwks else Error "unexpected JWKS URL"
  in
  let token = headers (sign_workload ()) in
  let first = dispatch ~fetch_workload_jwks:fetch token in
  let second = dispatch ~fetch_workload_jwks:fetch token in
  Windtrap.equal Windtrap.int ~msg:"first request succeeds" 200 first.Response.status;
  Windtrap.equal Windtrap.int ~msg:"second request succeeds" 200 second.Response.status;
  Windtrap.equal Windtrap.int ~msg:"cached JWKS is reused" 1 !fetches;
  Service.For_testing.reset_jwks_cache ()
;;

(* A rotation: the cache holds only the old key and is younger than the 300s
   freshness window, so the primary lookup returns it; the token's unknown kid
   must trigger the unknown-kid refetch and pick up the overlapping new key. *)
let test_jwks_unknown_kid_refetches_a_rotation () =
  Service.For_testing.reset_jwks_cache ();
  Service.For_testing.seed_stale_jwks_cache
    ~url:workload_jwks_cache_key
    ~age_s:60.0
    ~jwks:(Jose.Jwks.to_string rsa_jwks);
  let fetches = ref 0 in
  let fetch issuer =
    incr fetches;
    if issuer = workload_issuer then Ok rotated_jwks else Error "unexpected JWKS URL"
  in
  let response =
    dispatch ~fetch_workload_jwks:fetch (headers (sign_workload ~key:rotated_priv_jwk ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"a token signed by the rotated key authenticates after the refetch"
    200
    response.Response.status;
  Windtrap.equal Windtrap.int ~msg:"the unknown kid caused exactly one refetch" 1 !fetches;
  Service.For_testing.reset_jwks_cache ()
;;

(* Kid-flood resistance: an unknown kid does not refetch a cache younger than
   the 30s unknown-kid interval, and the request stays refused rather than
   authenticating against a key that is not in the set. *)
let test_jwks_unknown_kid_refetch_is_debounced () =
  Service.For_testing.reset_jwks_cache ();
  Service.For_testing.seed_stale_jwks_cache
    ~url:workload_jwks_cache_key
    ~age_s:5.0
    ~jwks:(Jose.Jwks.to_string rsa_jwks);
  let fetches = ref 0 in
  let fetch issuer =
    incr fetches;
    if issuer = workload_issuer then Ok rotated_jwks else Error "unexpected JWKS URL"
  in
  let response =
    dispatch ~fetch_workload_jwks:fetch (headers (sign_workload ~key:rotated_priv_jwk ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"a fresh cache is not refetched on an unknown kid"
    0
    !fetches;
  Windtrap.equal
    Windtrap.int
    ~msg:"and the request is refused"
    401
    response.Response.status;
  Service.For_testing.reset_jwks_cache ()
;;

let test_external_route_bypasses_only_sol_workload_auth () =
  let boundary = ref None in
  let workload_principal = ref (Some ("unexpected", "principal")) in
  let response =
    Service.For_testing.dispatch
      ~on_boundary:(fun b -> boundary := Some b)
      ~on_workload_principal:(fun principal -> workload_principal := principal)
      ~routes:
        [ Route.external_
            (Route.get "/probe" (fun req ->
               match
                 req.Request.auth, Http.Header.get req.Request.headers "x-customer-token"
               with
               | Some _, _ -> Response.internal_error "Sol principal on external route"
               | None, None -> Response.unauthorized
               | None, Some "valid" -> Response.ok "application authenticated"
               | None, Some _ -> Response.unauthorized))
        ]
      (Http.Request.make ~meth:`GET "/probe")
      (Cohttp_eio.Body.of_string "")
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"external route can apply application-owned auth"
    401
    response.Response.status;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"external boundary is observed"
    (Some "external")
    (Option.map Observation.boundary_to_string !boundary);
  Windtrap.equal
    (Windtrap.option (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"external route has no Sol workload principal"
    None
    !workload_principal;
  let response =
    Service.For_testing.dispatch
      ~routes:
        [ Route.external_
            (Route.get "/probe" (fun req ->
               match
                 req.Request.auth, Http.Header.get req.Request.headers "x-customer-token"
               with
               | Some _, _ -> Response.internal_error "Sol principal on external route"
               | None, Some "valid" -> Response.ok "application authenticated"
               | _ -> Response.unauthorized))
        ]
      (Http.Request.make
         ~meth:`GET
         ~headers:(Http.Header.of_list [ "x-customer-token", "valid" ])
         "/probe")
      (Cohttp_eio.Body.of_string "")
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"application auth succeeds independently"
    200
    response.Response.status
;;

let test_google_authorized_caller_authenticates () =
  let response =
    dispatch
      ~identity:(google_identity ())
      (headers
         (sign_workload ~iss:google_issuer ~sub:google_subject ~email:google_email ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"Google caller authorized → 200"
    200
    response.Response.status;
  let payload = Yojson.Safe.from_string response.Response.body in
  Windtrap.equal
    Windtrap.string
    ~msg:"Google subject is the caller identity"
    google_subject
    (Yojson.Safe.Util.member "service_account" payload |> Yojson.Safe.Util.to_string)
;;

let test_google_alternate_issuer_spelling_is_accepted () =
  let response =
    dispatch
      ~identity:(google_identity ())
      (headers (sign_workload ~iss:"accounts.google.com" ~sub:google_subject ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"Google's alternate issuer spelling is the same authority"
    200
    response.Response.status
;;

let test_google_wrong_issuer_is_rejected () =
  Windtrap.equal
    Windtrap.int
    ~msg:"Wrong Google issuer → 401"
    401
    (dispatch
       ~identity:(google_identity ())
       (headers (sign_workload ~iss:"https://attacker.example" ~sub:google_subject ())))
      .Response.status
;;

let test_google_wrong_audience_is_rejected () =
  Windtrap.equal
    Windtrap.int
    ~msg:"Wrong Google audience → 401"
    401
    (dispatch
       ~identity:(google_identity ())
       (headers
          (sign_workload ~iss:google_issuer ~sub:google_subject ~aud:"other/unit" ())))
      .Response.status
;;

let test_google_unauthorized_subject_is_rejected () =
  Windtrap.equal
    Windtrap.int
    ~msg:"Authenticated but unauthorized Google subject → 403"
    403
    (dispatch
       ~identity:(google_identity ())
       (headers (sign_workload ~iss:google_issuer ~sub:"999999999" ())))
      .Response.status
;;

let test_google_email_is_not_authority () =
  Windtrap.equal
    Windtrap.int
    ~msg:"An allowed email does not authorize a different sub → 403"
    403
    (dispatch
       ~identity:(google_identity ~callers:[ google_email, caller_unit ] ())
       (headers
          (sign_workload ~iss:google_issuer ~sub:"different-sub" ~email:google_email ())))
      .Response.status
;;

let test_scheme_confusion_is_forbidden () =
  Windtrap.equal
    Windtrap.int
    ~msg:"Google subject is not a Kubernetes callers entry → 403"
    403
    (dispatch
       ~identity:(workload_identity ())
       (headers (sign_workload ~iss:workload_issuer ~sub:google_subject ())))
      .Response.status;
  Windtrap.equal
    Windtrap.int
    ~msg:"Kubernetes-style subject is not a Google subject → 403"
    403
    (dispatch
       ~identity:(google_identity ~callers:[ caller_subject, caller_unit ] ())
       (headers (sign_workload ~iss:google_issuer ~sub:caller_subject ())))
      .Response.status
;;

let test_identity_configuration_fails_closed () =
  let config bindings =
    with_env bindings (fun () ->
      Service.For_testing.workload_identity_config
        [ Route.get "/probe" (fun _ -> Response.ok "") ]
        `Public)
  in
  (match
     config
       [ "SOL_UNIT", ""
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "kubernetes_service_account"
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"empty audience is invalid"
       (String.starts_with
          ~prefix:"a route uses Workload_identity auth but SOL_UNIT"
          message)
   | Ok _ -> Windtrap.fail "empty audience was accepted");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", ""
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "kubernetes_service_account"
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"empty issuer is invalid"
       (String.starts_with
          ~prefix:
            "a route requires Sol workload authentication but SOL_TRUSTED_WORKLOAD_ISSUER"
          message)
   | Ok _ -> Windtrap.fail "empty issuer was accepted");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", ""
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"explicitly empty scheme is invalid"
       (String.equal message "SOL_WORKLOAD_SUBJECT_SCHEME must not be empty")
   | Ok _ -> Windtrap.fail "explicitly empty subject scheme was accepted");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "unknown"
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"unknown scheme names the supported values"
       (String.starts_with ~prefix:"unknown workload identity subject scheme" message)
   | Ok _ -> Windtrap.fail "unknown subject scheme was accepted");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "google_oidc_service_account"
       ; "SOL_TRUSTED_WORKLOAD_JWKS_URI", "https://www.googleapis.com/oauth2/v3/certs"
       ; "SOL_CALLED_BY", "a=123,b=123"
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"duplicate caller subjects are rejected"
       (String.equal message "duplicate workload identity caller subject \"123\"")
   | Ok _ -> Windtrap.fail "duplicate caller subjects were accepted");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "google_oidc_service_account"
       ; "SOL_TRUSTED_WORKLOAD_JWKS_URI", "https://www.googleapis.com/oauth2/v3/certs"
       ; "SOL_CALLED_BY", "a=123"
       ]
   with
   | Ok (Some config) ->
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"explicit cross-origin Google JWKS URI is projected"
       (Some "https://www.googleapis.com/oauth2/v3/certs")
       config.Auth.trusted_jwks_uri
   | Error (`Config message) -> Windtrap.fail message
   | Ok None -> Windtrap.fail "Google config did not request workload identity");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "google_oidc_service_account"
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"Google scheme requires an explicit JWKS URI"
       (String.starts_with ~prefix:"the Google OIDC subject scheme requires" message)
   | Ok _ -> Windtrap.fail "Google scheme accepted without a JWKS URI");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", workload_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "kubernetes_service_account"
       ; "SOL_TRUSTED_WORKLOAD_JWKS_URI", "https://www.googleapis.com/oauth2/v3/certs"
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"Kubernetes scheme rejects an explicit JWKS URI"
       (String.starts_with
          ~prefix:"SOL_TRUSTED_WORKLOAD_JWKS_URI is only supported"
          message)
   | Ok _ -> Windtrap.fail "Kubernetes scheme accepted an explicit JWKS URI");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "google_oidc_service_account"
       ; "SOL_TRUSTED_WORKLOAD_JWKS_URI", "http://www.googleapis.com/certs"
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"insecure JWKS URI is rejected"
       (String.starts_with ~prefix:"SOL_TRUSTED_WORKLOAD_JWKS_URI must be" message)
   | Ok _ -> Windtrap.fail "insecure JWKS URI was accepted");
  (match
     config
       [ "SOL_UNIT", workload_audience
       ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
       ; "SOL_WORKLOAD_SUBJECT_SCHEME", "google_oidc_service_account"
       ; "SOL_TRUSTED_WORKLOAD_JWKS_URI", ""
       ]
   with
   | Error (`Config message) ->
     Windtrap.is_true
       ~msg:"empty JWKS URI is treated as missing and rejected"
       (String.starts_with ~prefix:"the Google OIDC subject scheme requires" message)
   | Ok _ -> Windtrap.fail "empty JWKS URI was accepted");
  match
    config
      [ "SOL_UNIT", workload_audience
      ; "SOL_TRUSTED_WORKLOAD_ISSUER", google_issuer
      ; "SOL_WORKLOAD_SUBJECT_SCHEME", "google_oidc_service_account"
      ; "SOL_TRUSTED_WORKLOAD_JWKS_URI", "https://www.googleapis.com/oauth2/v3/certs"
      ; "SOL_CALLED_BY", "a=system:serviceaccount:ns:sa"
      ]
  with
  | Error (`Config message) ->
    Windtrap.is_true
      ~msg:"Kubernetes subject under Google scheme is rejected at configuration"
      (String.starts_with ~prefix:"workload identity caller" message)
  | Ok _ -> Windtrap.fail "Kubernetes subject was accepted under Google scheme"
;;

let test_google_missing_subject_is_forbidden () =
  let token =
    sign_payload
      (`Assoc
          [ "iss", `String google_issuer
          ; "aud", `String workload_audience
          ; "exp", `Int (int_of_float (Unix.gettimeofday () +. 3600.0))
          ])
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"Google token without sub → 403"
    403
    (dispatch ~identity:(google_identity ()) (headers token)).Response.status
;;

let test_google_expired_token_is_unauthorized () =
  Windtrap.equal
    Windtrap.int
    ~msg:"Google expired token → 401"
    401
    (dispatch
       ~identity:(google_identity ())
       (headers
          (sign_workload ~iss:google_issuer ~sub:google_subject ~exp_offset:(-10.0) ())))
      .Response.status
;;

let test_google_unsupported_algorithm_is_unauthorized () =
  let token =
    unsigned_none_token
      (`Assoc
          [ "iss", `String google_issuer
          ; "aud", `String workload_audience
          ; "sub", `String google_subject
          ; "exp", `Int (int_of_float (Unix.gettimeofday () +. 3600.0))
          ])
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"Google token with alg=none → 401"
    401
    (dispatch ~identity:(google_identity ()) (headers token)).Response.status
;;

let test_google_invalid_signature_is_unauthorized () =
  let token = sign_workload ~iss:google_issuer ~sub:google_subject () in
  match String.split_on_char '.' token with
  | [ header; payload; signature ] ->
    let replacement = if signature.[0] = 'A' then 'B' else 'A' in
    let tampered =
      String.concat
        "."
        [ header
        ; payload
        ; String.make 1 replacement ^ String.sub signature 1 (String.length signature - 1)
        ]
    in
    Windtrap.equal
      Windtrap.int
      ~msg:"Google tampered signature → 401"
      401
      (dispatch ~identity:(google_identity ()) (headers tampered)).Response.status
  | _ -> Windtrap.fail "signed Google token should have three parts"
;;

let test_google_missing_audience_is_unauthorized () =
  let token =
    sign_payload
      (`Assoc
          [ "iss", `String google_issuer
          ; "sub", `String google_subject
          ; "exp", `Int (int_of_float (Unix.gettimeofday () +. 3600.0))
          ])
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"Google token without aud → 401"
    401
    (dispatch ~identity:(google_identity ()) (headers token)).Response.status
;;

let test_google_azp_is_not_caller_authority () =
  (* Google documents azp as the presenting client's identifier, not the
     workload subject. Sol authorizes the service-account sub against the
     application audience; a different azp does not create a different Sol
     caller. This is a deliberate policy decision, not an omitted check. *)
  let response =
    dispatch
      ~identity:(google_identity ())
      (headers
         (sign_workload
            ~iss:google_issuer
            ~sub:google_subject
            ~azp:"another-presenting-client"
            ()))
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"azp is not a Sol caller identity; authorized sub still succeeds"
    200
    response.Response.status
;;

let test_numeric_https_jwks_uri () =
  Windtrap.equal
    Windtrap.string
    ~msg:"HTTPS JWKS gets numeric 443 port"
    "https://www.googleapis.com:443/oauth2/v3/certs"
    (Service.For_testing.numeric_https_uri "https://www.googleapis.com/oauth2/v3/certs");
  Windtrap.equal
    Windtrap.string
    ~msg:"explicit port is preserved"
    "https://example.test:8443/certs"
    (Service.For_testing.numeric_https_uri "https://example.test:8443/certs");
  Windtrap.equal
    Windtrap.string
    ~msg:"http is unchanged"
    "http://example.test/certs"
    (Service.For_testing.numeric_https_uri "http://example.test/certs")
;;

let () =
  Windtrap.run
    "sol-svc workload identity"
    [ Windtrap.test
        "service consumes the Sol-projected issuer and caller contract"
        test_service_reads_the_sol_projected_trust_and_call_policy
    ; Windtrap.test
        "internal routes fail closed without issuer; external-only routes do not require \
         it"
        test_internal_route_without_target_issuer_fails_startup
    ; Windtrap.test
        "declared caller authenticates and authorizes"
        test_declared_workload_authenticates_and_authorizes
    ; Windtrap.test "undeclared caller is forbidden" test_undeclared_caller_is_forbidden
    ; Windtrap.test
        "untrusted issuer is unauthorized"
        test_untrusted_issuer_is_unauthorized
    ; Windtrap.test
        "OIDC discovery and JWKS stay bound to the trusted issuer"
        test_discovery_must_bind_keys_to_the_trusted_issuer
    ; Windtrap.test
        "workload authentication fails closed when key resolution fails"
        test_jwks_resolution_failure_fails_closed
    ; Windtrap.test "wrong audience is unauthorized" test_wrong_audience_is_unauthorized
    ; Windtrap.test
        "tampered signature is unauthorized"
        test_tampered_signature_is_unauthorized
    ; Windtrap.test
        "non-workload subject is forbidden"
        test_non_workload_subject_is_forbidden
    ; Windtrap.test "missing token is unauthorized" test_missing_token_is_unauthorized
    ; Windtrap.test "JWKS cache reuses resolved keys" test_jwks_cache_reuses_resolved_keys
    ; Windtrap.test
        "an unknown kid refetches and picks up a rotated issuer key"
        test_jwks_unknown_kid_refetches_a_rotation
    ; Windtrap.test
        "an unknown kid does not refetch a cache younger than the refetch interval"
        test_jwks_unknown_kid_refetch_is_debounced
    ; Windtrap.test
        "external route bypasses only Sol workload auth"
        test_external_route_bypasses_only_sol_workload_auth
    ; Windtrap.test
        "Google authorized caller authenticates"
        test_google_authorized_caller_authenticates
    ; Windtrap.test
        "Google alternate issuer spelling is accepted"
        test_google_alternate_issuer_spelling_is_accepted
    ; Windtrap.test "Google wrong issuer is rejected" test_google_wrong_issuer_is_rejected
    ; Windtrap.test
        "Google wrong audience is rejected"
        test_google_wrong_audience_is_rejected
    ; Windtrap.test
        "Google unauthorized subject is rejected"
        test_google_unauthorized_subject_is_rejected
    ; Windtrap.test "Google email is not authority" test_google_email_is_not_authority
    ; Windtrap.test
        "Kubernetes and Google schemes cannot be confused"
        test_scheme_confusion_is_forbidden
    ; Windtrap.test
        "identity configuration fails closed"
        test_identity_configuration_fails_closed
    ; Windtrap.test
        "Google missing subject is forbidden"
        test_google_missing_subject_is_forbidden
    ; Windtrap.test "numeric HTTPS JWKS port" test_numeric_https_jwks_uri
    ; Windtrap.test
        "Google azp is not caller authority"
        test_google_azp_is_not_caller_authority
    ; Windtrap.test
        "Google expired token is unauthorized"
        test_google_expired_token_is_unauthorized
    ; Windtrap.test
        "Google unsupported algorithm is unauthorized"
        test_google_unsupported_algorithm_is_unauthorized
    ; Windtrap.test
        "Google invalid signature is unauthorized"
        test_google_invalid_signature_is_unauthorized
    ; Windtrap.test
        "Google missing audience is unauthorized"
        test_google_missing_audience_is_unauthorized
    ]
;;
