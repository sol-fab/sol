open Result.Syntax

type provider =
  | Aws
  | Gcp

type kind =
  | Application
  | Database

type scope =
  { provider : provider
  ; environment : string
  ; target : string
  ; project : string option
  ; region : string option
  }

type t =
  { provider : provider
  ; environment : string
  ; target : string
  ; name : string
  ; project : string option
  ; region : string option
  ; identity : string
  ; kind : kind
  ; resource_name : string
  }

let provider_to_string = function
  | Aws -> Sol_cli_provider.to_string Sol_cli_provider.Aws
  | Gcp -> Sol_cli_provider.to_string Sol_cli_provider.Gcp
;;

(** The Secrets Store CSI provider name. It is not the Sol provider identity: GKE's
    Secret Manager add-on registers itself as [gke], not [gcp]. *)
let spc_provider_name = function
  | Aws -> provider_to_string Aws
  | Gcp -> "gke"
;;

let kind_to_string = function
  | Application -> "application"
  | Database -> "database"
;;

let is_lower_component_char = function
  | 'a' .. 'z' | '0' .. '9' | '-' -> true
  | _ -> false
;;

let is_path_component value =
  value <> ""
  && String.for_all is_lower_component_char value
  && value.[0] <> '-'
  && value.[String.length value - 1] <> '-'
;;

(* The key grammar belongs to the declaration validator ([Sol_cli_secret.validate_key]);
   this is the narrower question a provider name and an IAM resource ask: can this value
   be a path segment without becoming a wildcard or a second segment? *)
let is_key_segment value =
  value <> ""
  && String.for_all
       (function
         | 'A' .. 'Z' | '0' .. '9' | '_' -> true
         | _ -> false)
       value
;;

let validate_component ~what value =
  if is_path_component value
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s %S is not a lowercase provider-safe name; use letters, digits and hyphens"
         what
         value)
;;

let validate_key value =
  if is_key_segment value
  then Ok ()
  else
    Error
      (Printf.sprintf
         "secret key %S is not a provider-safe path segment; use uppercase letters, \
          digits and underscores"
         value)
;;

let scope ~provider ~environment ~target ~project ~region =
  let* () = validate_component ~what:"environment" environment in
  let* () = validate_component ~what:"target" target in
  let* () =
    match provider, project, region with
    | Gcp, None, _ -> Error "a GCP secret authority requires the target's project_id"
    | Aws, _, None -> Error "an AWS secret authority requires the target's region"
    | _ -> Ok ()
  in
  Ok { provider; environment; target; project; region }
;;

let aws_name ~environment ~target ~identity =
  Printf.sprintf "sol/%s/%s/%s" environment target identity
;;

let gcp_name ~environment ~target ~identity =
  Printf.sprintf
    "sol-%s-%s-%s"
    environment
    target
    (String.map (fun c -> if c = '/' then '-' else c) identity)
;;

let make ~(scope : scope) ~identity ~kind =
  let name =
    match scope.provider with
    | Aws -> aws_name ~environment:scope.environment ~target:scope.target ~identity
    | Gcp -> gcp_name ~environment:scope.environment ~target:scope.target ~identity
  in
  if String.length name > 255
  then
    Error
      (Printf.sprintf
         "provider secret name %S exceeds 255 characters; shorten the unit or key"
         name)
  else (
    let resource_name =
      match scope.provider, scope.project with
      | Gcp, Some project ->
        Printf.sprintf "projects/%s/secrets/%s/versions/latest" project name
      | Gcp, None ->
        (* [scope] refuses a GCP store without a project, so this is unreachable. *)
        name
      | Aws, _ -> name
    in
    Ok
      { provider = scope.provider
      ; environment = scope.environment
      ; target = scope.target
      ; name
      ; project = scope.project
      ; region = scope.region
      ; identity
      ; kind
      ; resource_name
      })
;;

let application ~scope ~domain ~unit ~key =
  let* () = validate_component ~what:"domain" domain in
  let* () = validate_component ~what:"unit" unit in
  let* () = validate_key key in
  make
    ~scope
    ~identity:(Printf.sprintf "units/%s/%s/%s" domain unit key)
    ~kind:Application
;;

let database ~scope ~part =
  let* () = validate_component ~what:"database secret part" part in
  make ~scope ~identity:(Printf.sprintf "databases/%s" part) ~kind:Database
;;

let reference t = t.name
let spc_reference t = t.resource_name

let ownership_labels t =
  [ "sol-managed-by", "sol"
  ; "sol-authority", kind_to_string t.kind
  ; "sol-environment", t.environment
  ; "sol-target", t.target
  ]
;;

let normalized_key key = key
