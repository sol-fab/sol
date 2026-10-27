type jwt_algorithm =
  [ `HS256
  | `RS256
  | `ES256
  | `ES384
  | `ES512
  ]

type jwt_key_source =
  | Hs256_secret of string
  | Jwks_static of string
  | Jwks_url of string

type jwt_verified_config =
  { issuer : string
  ; audience : string
  ; algorithms : jwt_algorithm list
  ; key_source : jwt_key_source
  }

type jwt_verification =
  | Verified_signature_required of jwt_verified_config
  | Unverified_dev_only

type jwt_config =
  { scopes : string list
  ; verification : jwt_verification
  }

type subject_scheme =
  | Kubernetes_service_account
  | Google_oidc_service_account

let subject_scheme_to_string = function
  | Kubernetes_service_account -> "kubernetes_service_account"
  | Google_oidc_service_account -> "google_oidc_service_account"
;;

let subject_scheme_of_string = function
  | "kubernetes_service_account" -> Ok Kubernetes_service_account
  | "google_oidc_service_account" -> Ok Google_oidc_service_account
  | value ->
    Error
      (Printf.sprintf
         "unknown workload identity subject scheme %S (expected           \
          kubernetes_service_account or google_oidc_service_account)"
         value)
;;

(* DEC-063: a Sol-to-Sol call authenticates with the caller's projected
   identity token. The callee checks the token against a trusted issuer, maps
   the subject according to an explicit scheme, and requires that subject in
   [callers]. The scheme is part of the target capability, never inferred from
   a subject string. *)
type workload_identity_config =
  { audience : string
  ; callers : (string * string) list
    (* K8s: "<namespace>:<serviceaccount>" -> caller unit.
       Google: the token's stable subject -> caller unit. *)
  ; trusted_issuer : string
  ; subject_scheme : subject_scheme
  }

type level =
  [ `Public
  | `Api_key
  | `Jwt of jwt_config
  | `Workload_identity
  ]

type principal =
  | Public
  | Service of { key_id : string }
  | User of
      { sub : string
      ; scopes : string list
      ; claims : Yojson.Safe.t
      }
  | Unit of
      { unit : string
      ; service_account : string
      }

type context = { principal : principal }

type error =
  [ `Unauthorized of string
  | `Forbidden of string
  | `Server_error of string
  ]

let constant_time_equal s1 s2 =
  let len1 = String.length s1
  and len2 = String.length s2 in
  if len1 <> len2
  then false
  else (
    let res = ref 0 in
    for i = 0 to len1 - 1 do
      res := !res lor (Char.code s1.[i] lxor Char.code s2.[i])
    done;
    !res = 0)
;;

open Result.Syntax

type key_request =
  { issuer : string
  ; key_id : string option
  }

type pending_workload_auth =
  { token : string
  ; issuer : string
  ; config : workload_identity_config
  ; key_id : string option
  }

let has_prefix value prefix =
  let plen = String.length prefix in
  String.length value >= plen && String.sub value 0 plen = prefix
;;

(* Google emits both spellings of its issuer. They are the same authority; the
   adapter supplies the canonical value and the token may carry either. This
   normalization is scoped to the Google scheme and does not affect Kubernetes. *)
let canonical_issuer = function
  | "accounts.google.com" -> "https://accounts.google.com"
  | issuer -> issuer
;;

let issuer_matches scheme ~trusted actual =
  match scheme with
  | Kubernetes_service_account -> String.equal trusted actual
  | Google_oidc_service_account ->
    String.equal (canonical_issuer trusted) (canonical_issuer actual)
;;

let valid_caller_key scheme key =
  match scheme with
  | Kubernetes_service_account ->
    (match String.split_on_char ':' key with
     | [ namespace; service_account ] -> namespace <> "" && service_account <> ""
     | _ -> false)
  | Google_oidc_service_account ->
    key <> ""
    && (not (has_prefix key "system:serviceaccount:"))
    && not (String.contains key ':')
;;

let validate_callers scheme callers =
  let seen = Hashtbl.create (List.length callers) in
  let rec loop = function
    | [] -> Ok ()
    | (subject, unit) :: rest ->
      if subject = "" || unit = ""
      then Error "workload identity callers must have a non-empty subject and unit"
      else if not (valid_caller_key scheme subject)
      then
        Error
          (Printf.sprintf
             "workload identity caller %S is not valid for subject scheme %s"
             subject
             (subject_scheme_to_string scheme))
      else if Hashtbl.mem seen subject
      then Error (Printf.sprintf "duplicate workload identity caller subject %S" subject)
      else (
        Hashtbl.add seen subject ();
        loop rest)
  in
  loop callers
;;

let callers_of_projection raw =
  raw
  |> String.split_on_char ','
  |> List.filter_map (fun entry ->
    match String.index_opt entry '=' with
    | None -> None
    | Some i ->
      let unit = String.sub entry 0 i |> String.trim in
      let service_account =
        String.sub entry (i + 1) (String.length entry - i - 1) |> String.trim
      in
      if unit = "" || service_account = "" then None else Some (service_account, unit))
;;

let bearer_token = function
  | None -> Error (`Unauthorized "Missing Authorization header")
  | Some auth ->
    let prefix = "Bearer " in
    let prefix_len = String.length prefix in
    if String.length auth < prefix_len || String.sub auth 0 prefix_len <> prefix
    then Error (`Unauthorized "Authorization header must be 'Bearer <token>'")
    else Ok (String.sub auth prefix_len (String.length auth - prefix_len))
;;

let claims_string claims name =
  match Yojson.Safe.Util.member name claims with
  | `String value -> Some value
  | _ -> None
;;

let claims_strings claims name =
  match Yojson.Safe.Util.member name claims with
  | `String value -> [ value ]
  | `List values ->
    List.filter_map
      (function
        | `String value -> Some value
        | _ -> None)
      values
  | _ -> []
;;

let claims_object = function
  | `Assoc _ as claims -> Ok claims
  | _ -> Error (`Unauthorized "Malformed JWT: payload is not a JSON object")
;;

let decoded_token token =
  match Jose.Jwt.unsafe_of_string token with
  | Ok parsed -> Ok parsed
  | Error _ -> Error (`Unauthorized "Malformed JWT")
;;

let workload_alg_allowed (alg : Jose.Jwa.alg) =
  match alg with
  | `RS256 | `ES256 | `ES384 | `ES512 -> true
  | _ -> false
;;

let begin_workload_auth config ~authorization =
  let* token = bearer_token authorization in
  let* parsed = decoded_token token in
  let* claims = claims_object parsed.Jose.Jwt.payload in
  let* issuer =
    match claims_string claims "iss" with
    | Some issuer -> Ok issuer
    | None -> Error (`Unauthorized "JWT issuer missing")
  in
  let* () =
    if issuer_matches config.subject_scheme ~trusted:config.trusted_issuer issuer
    then Ok ()
    else Error (`Unauthorized ("JWT issuer is not trusted: " ^ issuer))
  in
  let key_id = parsed.Jose.Jwt.header.Jose.Header.kid in
  let issuer =
    match config.subject_scheme with
    | Google_oidc_service_account -> canonical_issuer issuer
    | Kubernetes_service_account -> issuer
  in
  Ok ({ issuer; key_id }, { token; issuer; config; key_id })
;;

let finish_workload_auth pending ~jwks ~now =
  let* parsed = decoded_token pending.token in
  let alg = parsed.Jose.Jwt.header.Jose.Header.alg in
  let* () =
    if workload_alg_allowed alg
    then Ok ()
    else Error (`Unauthorized "JWT alg not permitted")
  in
  let* kid =
    match pending.key_id with
    | Some kid -> Ok kid
    | None -> Error (`Unauthorized "JWT missing kid")
  in
  let* jwk =
    match Jose.Jwks.find_key jwks kid with
    | Some jwk -> Ok jwk
    | None -> Error (`Unauthorized "JWT key id not found in JWKS")
  in
  let* verified =
    match Jose.Jwt.validate_signature ~jwk parsed with
    | Ok token -> Ok token
    | Error `Invalid_signature -> Error (`Unauthorized "JWT signature invalid")
    | Error (`Msg message) -> Error (`Unauthorized ("JWT invalid: " ^ message))
  in
  let* claims = claims_object verified.Jose.Jwt.payload in
  let* () =
    match claims_string claims "iss" with
    | Some issuer
      when issuer_matches pending.config.subject_scheme ~trusted:pending.issuer issuer ->
      Ok ()
    | _ -> Error (`Unauthorized "JWT issuer mismatch")
  in
  let* () =
    let numeric_date name =
      match Yojson.Safe.Util.member name claims with
      | `Null -> Ok None
      | `Int value -> Ok (Some (float_of_int value))
      | `Float value when Float.is_finite value -> Ok (Some value)
      | `Float _ -> Error (`Unauthorized ("JWT " ^ name ^ " claim is invalid"))
      | _ -> Error (`Unauthorized ("JWT " ^ name ^ " claim is not a numeric date"))
    in
    let* not_before = numeric_date "nbf" in
    let* expires = numeric_date "exp" in
    match not_before, expires with
    | Some nbf, _ when now < nbf -> Error (`Unauthorized "JWT not yet valid")
    | _, Some exp when now >= exp -> Error (`Unauthorized "JWT expired")
    | _ -> Ok ()
  in
  let* () =
    if List.mem pending.config.audience (claims_strings claims "aud")
    then Ok ()
    else Error (`Unauthorized "JWT audience mismatch")
  in
  let* subject =
    match claims_string claims "sub" with
    | Some subject -> Ok subject
    | None -> Error (`Forbidden "authenticated subject is not a workload identity")
  in
  let prefix = "system:serviceaccount:" in
  let* service_account =
    match pending.config.subject_scheme with
    | Kubernetes_service_account ->
      let plen = String.length prefix in
      if String.length subject > plen && String.sub subject 0 plen = prefix
      then Ok (String.sub subject plen (String.length subject - plen))
      else
        Error
          (`Forbidden
              (Printf.sprintf
                 "authenticated subject %S is not a workload identity"
                 subject))
    | Google_oidc_service_account ->
      if has_prefix subject prefix
      then
        Error
          (`Forbidden
              "a Kubernetes-style subject cannot authenticate under the Google OIDC \
               scheme")
      else Ok subject
  in
  match List.assoc_opt service_account pending.config.callers with
  | None ->
    Error
      (`Forbidden
          (Printf.sprintf
             "caller %s is authenticated but is not in this unit's callers set"
             service_account))
  | Some unit -> Ok { principal = Unit { unit; service_account } }
;;

module For_testing = struct
  let constant_time_equal = constant_time_equal
end
