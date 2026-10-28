open Auth

let validate_api_key ~read_api_key headers =
  match Http.Header.get headers "x-api-key" with
  | None -> Error (`Unauthorized "Missing X-Api-Key header")
  | Some provided ->
    (match read_api_key () with
     | None ->
       Error
         (`Server_error "API key not configured (set SOL_API_KEY or SOL_API_KEY_FILE)")
     | Some "" ->
       Error (`Server_error "API key is empty (set SOL_API_KEY or SOL_API_KEY_FILE)")
     | Some _ when provided = "" -> Error (`Unauthorized "Invalid API key")
     | Some expected ->
       if constant_time_equal provided expected
       then (
         let key_id = String.sub provided 0 (min 8 (String.length provided)) in
         Ok { principal = Service { key_id } })
       else Error (`Unauthorized "Invalid API key"))
;;

let base64url_decode s =
  let s =
    String.map
      (function
        | '-' -> '+'
        | '_' -> '/'
        | c -> c)
      s
  in
  let pad =
    match String.length s mod 4 with
    | 2 -> s ^ "=="
    | 3 -> s ^ "="
    | _ -> s
  in
  match Base64.decode pad with
  | Ok s -> Some s
  | Error _ -> None
;;

let token_scopes json =
  match Yojson.Safe.Util.member "scope" json with
  | `String s -> String.split_on_char ' ' s |> List.filter (fun s -> s <> "")
  | `List lst ->
    List.filter_map
      (function
        | `String s -> Some s
        | _ -> None)
      lst
  | _ -> []
;;

open Result.Syntax

type jwt_parts =
  { header_b64 : string
  ; payload_b64 : string
  ; signature_b64 : string
  }

let bearer_token headers =
  let* auth =
    Http.Header.get headers "authorization"
    |> Option.to_result ~none:(`Unauthorized "Missing Authorization header")
  in
  let prefix = "Bearer " in
  let plen = String.length prefix in
  if String.length auth < plen || String.sub auth 0 plen <> prefix
  then Error (`Unauthorized "Authorization header must be 'Bearer <token>'")
  else Ok (String.sub auth plen (String.length auth - plen))
;;

let split_jwt token =
  match String.split_on_char '.' token with
  | [ header_b64; payload_b64; signature_b64 ] ->
    Ok { header_b64; payload_b64; signature_b64 }
  | _ -> Error (`Unauthorized "Malformed JWT: expected header.payload.signature")
;;

let decode_jwt_payload parts =
  base64url_decode parts.payload_b64
  |> Option.to_result ~none:(`Unauthorized "Malformed JWT: cannot decode payload")
;;

let require_claims_object = function
  | `Assoc _ as json -> Ok json
  | _ -> Error (`Unauthorized "Malformed JWT: payload is not a JSON object")
;;

let parse_jwt_payload payload_str =
  match Yojson.Safe.from_string payload_str with
  | exception ((Out_of_memory | Stack_overflow | Sys.Break) as exn) -> raise exn
  | exception Yojson.Json_error _ ->
    Error (`Unauthorized "Malformed JWT: payload is not valid JSON")
  | json -> require_claims_object json
;;

let jwt_expired ~now json =
  match Yojson.Safe.Util.member "exp" json with
  | `Int n -> float_of_int n < now
  | `Float f -> f < now
  | _ -> false
;;

let check_jwt_expiry json =
  if jwt_expired ~now:(Unix.gettimeofday ()) json
  then Error (`Unauthorized "JWT expired")
  else Ok ()
;;

let numeric_date_claim json name =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | None | Some `Null -> Ok None
     | Some (`Int n) -> Ok (Some (float_of_int n))
     | Some (`Float f) when Float.is_finite f -> Ok (Some f)
     | Some _ ->
       Error (`Unauthorized (Printf.sprintf "JWT %s claim is not a numeric date" name)))
  | _ -> Error (`Unauthorized "Malformed JWT: payload is not a JSON object")
;;

let check_temporal_claims ~now json =
  let* nbf = numeric_date_claim json "nbf" in
  let* exp = numeric_date_claim json "exp" in
  match nbf, exp with
  | Some nbf, _ when now < nbf -> Error (`Unauthorized "JWT not yet valid")
  | _, Some exp when now >= exp -> Error (`Unauthorized "JWT expired")
  | _ -> Ok ()
;;

let validate_required_scopes ~required ~actual =
  match List.filter (fun scope -> not (List.mem scope actual)) required with
  | [] -> Ok ()
  | scope :: _ -> Error (`Forbidden ("Missing required scope: " ^ scope))
;;

let token_sub json =
  match Yojson.Safe.Util.member "sub" json with
  | `String s -> s
  | _ -> ""
;;

let validate_unverified_jwt config headers =
  let* token = bearer_token headers in
  let* parts = split_jwt token in
  let* payload_str = decode_jwt_payload parts in
  let* json = parse_jwt_payload payload_str in
  let* () = check_jwt_expiry json in
  let scopes = token_scopes json in
  let* () = validate_required_scopes ~required:config.scopes ~actual:scopes in
  Ok { principal = User { sub = token_sub json; scopes; claims = json } }
;;

let jwks_refresh_mutex = Eio.Mutex.create ()

(* Cloud Run's resolver does not support the service-name form "https"; an
   explicit numeric port is the same TLS endpoint and avoids that lookup. *)
let numeric_https_uri url =
  let uri = Uri.of_string url in
  match Uri.scheme uri, Uri.port uri with
  | Some "https", None -> Uri.to_string (Uri.with_port uri (Some 443))
  | _ -> url
;;

let fetch_jwks_over_https ~env url =
  let url = numeric_https_uri url in
  match
    Https_eio.request
      ~net:env#net
      ~clock:env#clock
      ~timeout:10.0
      ~meth:`GET
      ~url
      ~headers:[ "Accept", "application/json" ]
      ()
  with
  | Error e -> Error (Https_eio.request_error_to_string e)
  | Ok (status, _) when status <> 200 ->
    Error (Printf.sprintf "JWKS fetch failed: HTTP %d" status)
  | Ok (_, body) ->
    (try Ok (Jose.Jwks.of_string body) with
     | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error ("JWKS parse failed: " ^ Printexc.to_string exn))
;;

let jwks_uri_of_discovery ~issuer body =
  let https_origin uri =
    match
      Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.query uri, Uri.fragment uri
    with
    | Some "https", Some host, None, [], None when host <> "" ->
      Some (String.lowercase_ascii host, Option.value ~default:443 (Uri.port uri))
    | _ -> None
  in
  let* fields =
    match Yojson.Safe.from_string body with
    | `Assoc fields -> Ok fields
    | _ -> Error "OIDC discovery response is not a JSON object"
    | exception Yojson.Json_error message ->
      Error ("OIDC discovery returned invalid JSON: " ^ message)
  in
  let returned_issuer =
    match List.assoc_opt "issuer" fields with
    | Some (`String value) -> Some value
    | _ -> None
  in
  if returned_issuer <> Some issuer
  then Error "OIDC discovery issuer does not match the trusted target issuer"
  else (
    match List.assoc_opt "jwks_uri" fields with
    | Some (`String url) ->
      let jwks_uri = Uri.of_string url
      and issuer_uri = Uri.of_string issuer in
      (match https_origin issuer_uri, https_origin jwks_uri with
       | Some issuer_origin, Some jwks_origin when issuer_origin = jwks_origin -> Ok url
       | Some _, Some _ ->
         Error "OIDC discovery jwks_uri must use the trusted issuer's HTTPS origin"
       | _ -> Error "OIDC discovery jwks_uri is not an absolute same-origin https:// URL")
    | _ -> Error "OIDC discovery response has no string jwks_uri")
;;

let fetch_workload_jwks_over_https ~env issuer =
  let issuer_uri = Uri.of_string issuer in
  let issuer_uri_is_https =
    match Uri.scheme issuer_uri, Uri.host issuer_uri, Uri.userinfo issuer_uri with
    | Some "https", Some host, None when host <> "" -> true
    | _ -> false
  in
  if not issuer_uri_is_https
  then Error "trusted workload issuer is not an absolute https:// URL"
  else (
    let issuer_base =
      if String.ends_with ~suffix:"/" issuer
      then String.sub issuer 0 (String.length issuer - 1)
      else issuer
    in
    let discovery_url = issuer_base ^ "/.well-known/openid-configuration" in
    let discovery_url = numeric_https_uri discovery_url in
    let* status, body =
      Https_eio.request
        ~net:env#net
        ~clock:env#clock
        ~timeout:10.0
        ~meth:`GET
        ~url:discovery_url
        ~headers:[ "Accept", "application/json" ]
        ()
      |> Result.map_error Https_eio.request_error_to_string
    in
    if status <> 200
    then Error (Printf.sprintf "OIDC discovery failed: HTTP %d" status)
    else
      let* jwks_url = jwks_uri_of_discovery ~issuer body in
      fetch_jwks_over_https ~env jwks_url)
;;

let get_jwks ?(max_age_s = Auth_cache.ttl_s) ~fetch_jwks url =
  let usable entry =
    entry.Auth_cache.url = url
    && Unix.gettimeofday () -. entry.Auth_cache.fetched_at < max_age_s
  in
  match Auth_cache.peek () with
  | Some entry when usable entry -> Ok entry.Auth_cache.jwks
  | _ ->
    Eio.Mutex.use_ro jwks_refresh_mutex (fun () ->
      match Auth_cache.peek (), Auth_cache.last_failure () with
      | Some entry, _ when usable entry -> Ok entry.Auth_cache.jwks
      | _, Some (u, at, msg)
        when u = url && Unix.gettimeofday () -. at < Auth_cache.failure_backoff_s ->
        Error msg
      | _ ->
        (match fetch_jwks url with
         | Ok jwks ->
           Auth_cache.replace { Auth_cache.url; fetched_at = Unix.gettimeofday (); jwks };
           Auth_cache.set_last_failure None;
           Ok jwks
         | Error msg as e ->
           Auth_cache.set_last_failure (Some (url, Unix.gettimeofday (), msg));
           e))
;;

let verify_with_key_source ?fetch_jwks ~kid parsed key_source =
  let with_jwk jwk =
    match Jose.Jwt.validate_signature ~jwk parsed with
    | Ok t -> Ok t
    | Error `Invalid_signature -> Error (`Unauthorized "JWT signature invalid")
    | Error (`Msg m) -> Error (`Unauthorized ("JWT invalid: " ^ m))
    | exception ((Out_of_memory | Stack_overflow | Sys.Break) as exn) -> raise exn
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Error (`Unauthorized ("JWT invalid: " ^ Printexc.to_string exn))
  in
  let jwks_lookup ?refetch jwks =
    match kid with
    | None -> Error (`Unauthorized "JWT missing kid")
    | Some kid ->
      (match Jose.Jwks.find_key jwks kid with
       | Some jwk -> with_jwk jwk
       | None ->
         let not_found = Error (`Unauthorized "JWT key id not found in JWKS") in
         (match refetch with
          | None -> not_found
          | Some refetch ->
            (match refetch () with
             | Error _ -> not_found
             | Ok jwks ->
               (match Jose.Jwks.find_key jwks kid with
                | Some jwk -> with_jwk jwk
                | None -> not_found))))
  in
  match key_source with
  | Hs256_secret secret -> with_jwk (Jose.Jwk.make_oct secret)
  | Jwks_static doc ->
    (try jwks_lookup (Jose.Jwks.of_string doc) with
     | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (`Server_error ("JWKS parse failed: " ^ Printexc.to_string exn)))
  | Jwks_url url ->
    (match fetch_jwks with
     | None ->
       Error (`Server_error "Jwks_url configured but no JWKS fetcher was provided")
     | Some fetch_jwks ->
       (match get_jwks ~fetch_jwks url with
        | Error msg -> Error (`Server_error ("JWKS fetch failed: " ^ msg))
        | Ok jwks ->
          jwks_lookup
            ~refetch:(fun () ->
              get_jwks
                ~max_age_s:Auth_cache.unknown_kid_refetch_interval_s
                ~fetch_jwks
                url)
            jwks))
;;

let jwt_alg_allowed algorithms (alg : Jose.Jwa.alg) =
  List.exists
    (fun a ->
       match (a : jwt_algorithm), alg with
       | `HS256, `HS256 -> true
       | `RS256, `RS256 -> true
       | `ES256, `ES256 -> true
       | `ES384, `ES384 -> true
       | `ES512, `ES512 -> true
       | _ -> false)
    algorithms
;;

let claim_strings json name =
  match Yojson.Safe.Util.member name json with
  | `String s -> [ s ]
  | `List lst ->
    List.filter_map
      (function
        | `String s -> Some s
        | _ -> None)
      lst
  | _ -> []
;;

let check_issuer ~issuer json =
  match claim_strings json "iss" with
  | [ iss ] when iss = issuer -> Ok ()
  | _ -> Error (`Unauthorized "JWT issuer mismatch")
;;

let check_audience ~audience json =
  if List.mem audience (claim_strings json "aud")
  then Ok ()
  else Error (`Unauthorized "JWT audience mismatch")
;;

let validate_verified_jwt ?fetch_jwks vconfig ~scopes headers =
  let* token = bearer_token headers in
  let* parsed =
    match Jose.Jwt.unsafe_of_string token with
    | Ok t -> Ok t
    | Error _ -> Error (`Unauthorized "Malformed JWT")
  in
  let alg = parsed.Jose.Jwt.header.Jose.Header.alg in
  let* () =
    if jwt_alg_allowed vconfig.algorithms alg
    then Ok ()
    else Error (`Unauthorized "JWT alg not permitted")
  in
  let kid = parsed.Jose.Jwt.header.Jose.Header.kid in
  let* verified = verify_with_key_source ?fetch_jwks ~kid parsed vconfig.key_source in
  let* json = require_claims_object verified.Jose.Jwt.payload in
  let* () = check_temporal_claims ~now:(Unix.gettimeofday ()) json in
  let* () = check_issuer ~issuer:vconfig.issuer json in
  let* () = check_audience ~audience:vconfig.audience json in
  let token_scopes = token_scopes json in
  let* () = validate_required_scopes ~required:scopes ~actual:token_scopes in
  Ok { principal = User { sub = token_sub json; scopes = token_scopes; claims = json } }
;;

let workload_identity_algorithms : jwt_algorithm list = [ `RS256; `ES256; `ES384; `ES512 ]

let service_account_of_subject sub =
  let prefix = "system:serviceaccount:" in
  let plen = String.length prefix in
  if String.length sub <= plen || String.sub sub 0 plen <> prefix
  then
    Error
      (`Forbidden
          (Printf.sprintf "authenticated subject %S is not a workload identity" sub))
  else Ok (String.sub sub plen (String.length sub - plen))
;;

(* The shared auth core selects a trusted issuer and verifies identity policy.
   This adapter supplies network fetch/cache behavior. *)
let validate_workload_identity ?fetch_workload_jwks config headers =
  let authorization = Http.Header.get headers "authorization" in
  let* key_request, pending = Auth.begin_workload_auth config ~authorization in
  let* fetch_workload_jwks =
    match fetch_workload_jwks with
    | Some fetch -> Ok fetch
    | None -> Error (`Server_error "no trusted-issuer key resolver was provided")
  in
  let cache_key = "sol-workload-issuer:" ^ key_request.issuer in
  let resolve_workload_jwks _ = fetch_workload_jwks key_request.issuer in
  let* jwks =
    match get_jwks ~fetch_jwks:resolve_workload_jwks cache_key with
    | Ok jwks -> Ok jwks
    | Error msg -> Error (`Server_error ("JWKS fetch failed: " ^ msg))
  in
  match Auth.finish_workload_auth pending ~jwks ~now:(Unix.gettimeofday ()) with
  | Error (`Unauthorized "JWT key id not found in JWKS") ->
    let* jwks =
      match
        get_jwks
          ~max_age_s:Auth_cache.unknown_kid_refetch_interval_s
          ~fetch_jwks:resolve_workload_jwks
          cache_key
      with
      | Ok jwks -> Ok jwks
      | Error msg -> Error (`Server_error ("JWKS fetch failed: " ^ msg))
    in
    Auth.finish_workload_auth pending ~jwks ~now:(Unix.gettimeofday ())
  | result -> result
;;

let validate_jwt ?fetch_jwks config headers =
  match config.verification with
  | Verified_signature_required vconfig ->
    validate_verified_jwt ?fetch_jwks vconfig ~scopes:config.scopes headers
  | Unverified_dev_only -> validate_unverified_jwt config headers
;;

let validate
      ?(read_api_key = Fun.const None)
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      level
      headers
  =
  match level with
  | `Public -> Ok { principal = Public }
  | `Api_key -> validate_api_key ~read_api_key headers
  | `Jwt cfg -> validate_jwt ?fetch_jwks cfg headers
  | `Workload_identity ->
    (match workload_identity with
     | Some config -> validate_workload_identity ?fetch_workload_jwks config headers
     | None ->
       Error
         (`Server_error
             "a route requires Sol workload authentication but no target-trusted issuer \
              is configured"))
;;
