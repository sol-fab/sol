open Result.Syntax

let is_key_char = function
  | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false
;;

let validate_key_format key =
  let len = String.length key in
  if len = 0
  then Error "secret key must not be empty"
  else if len > 253
  then Error "secret key must be 253 characters or fewer"
  else if not (key.[0] >= 'A' && key.[0] <= 'Z')
  then Error "secret key must start with an uppercase letter"
  else if not (String.for_all is_key_char key)
  then Error "secret key may contain only uppercase letters, digits, and underscores"
  else Ok ()
;;

let validate_key key =
  let* () = validate_key_format key in
  if String.equal key "SOL_ALLOW_UNVERIFIED_JWT"
  then
    Error
      "SOL_ALLOW_UNVERIFIED_JWT is reserved: it allows JWT auth without signature \
       checks, and `sol local deploy` sets it on the local cluster only"
  else if String.equal key "SOL_ALLOW_PLAINTEXT_PEER_AUTH"
  then
    Error
      "SOL_ALLOW_PLAINTEXT_PEER_AUTH is reserved: it lets a caller fall back to the \
       shared API key when no projected identity was declared, and only local tooling \
       sets it"
  else if List.mem key [ "SOL_UNIT"; "SOL_CALLED_BY"; "SOL_TRUSTED_WORKLOAD_ISSUER" ]
  then
    Error
      (key
       ^ " is reserved: it is projected from the Sol workload contract and must not be \
          spoofed")
  else Ok ()
;;

type object_metadata =
  { name : string
  ; namespace : string
  ; labels : (string * string) list
  }

type kubernetes_secret =
  { api_version : string
  ; kind : string
  ; metadata : object_metadata
  ; secret_type : string
  ; data : (string * string) list
  ; string_data : (string * string) list
  }

let render_secret_manifest secret =
  let quoted_map pairs =
    Sol_cli_yaml.map (List.map (fun (k, v) -> k, Sol_cli_yaml.quoted v) pairs)
  in
  let data =
    match secret.data with
    | [] -> []
    | pairs -> [ "data", quoted_map pairs ]
  in
  Sol_cli_yaml.(
    render
      [ document
          (map
             ([ "apiVersion", string secret.api_version
              ; "kind", string secret.kind
              ; ( "metadata"
                , map
                    ([ "name", string secret.metadata.name
                     ; "namespace", string secret.metadata.namespace
                     ]
                     @
                     if secret.metadata.labels = []
                     then []
                     else [ "labels", quoted_map secret.metadata.labels ]) )
              ; "type", string secret.secret_type
              ]
              @ data
              @ [ "stringData", quoted_map secret.string_data ]))
      ])
;;

let named_secret_manifest ~labels ~secret_name ~existing_data ~namespace ~key ~value =
  let data = List.filter (fun (k, _) -> k <> key) existing_data in
  render_secret_manifest
    { api_version = "v1"
    ; kind = "Secret"
    ; metadata = { name = secret_name; namespace; labels }
    ; secret_type = "Opaque"
    ; data
    ; string_data = [ key, value ]
    }
;;

let apply_manifest ~ctx ?(redact = []) yaml =
  Sol_cli_fs.with_temp_file ~prefix:"sol-secret-" ~suffix:".yaml" yaml (fun path ->
    Sol_cli_kubectl.apply ~ctx ~file:path
    |> Result.map_error (fun error ->
      Sol_cli_process.error_to_string error |> Sol_cli_process.apply_redactions redact))
  |> Result.join
;;

let ensure_namespace ~ctx namespace =
  Sol_cli_fs.with_temp_file
    ~prefix:"sol-secret-ns-"
    ~suffix:".yaml"
    (Sol_cli_yaml.render [ Sol_cli_manifest.namespace_doc ~ns:namespace ])
    (fun path ->
       Sol_cli_manifest.create_idempotent ~ctx ~file:path
       |> Result.map_error (fun e ->
         Printf.sprintf
           "could not ensure namespace %s: %s"
           namespace
           (Sol_cli_process.error_to_string e)))
  |> Result.join
;;

let unit_secret_manifest ~namespace ~secret_name values =
  Sol_cli_yaml.render
    [ Sol_cli_manifest.secret_doc
        ~base_secrets:[]
        ~extra_secrets:values
        ~ns:namespace
        ~name:secret_name
        ~labels:[ "app.kubernetes.io/managed-by", "sol" ]
        ()
    ]
;;

let get_named_secret_json ~ctx ~name namespace =
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:[ "get"; "secret"; name; "-n"; namespace; "-o"; "json" ]
  with
  | Ok None -> Ok None
  | Ok (Some json) ->
    Sol_cli_json.decode ~what:(Printf.sprintf "Secret %s/%s" namespace name) json
    |> Result.map Option.some
  | Error e ->
    Error
      (Printf.sprintf
         "could not read Secret %s/%s: %s"
         namespace
         name
         (Sol_cli_process.error_to_string e))
;;

let secret_resource_version = function
  | `Assoc fields ->
    (match List.assoc_opt "metadata" fields with
     | Some (`Assoc metadata) ->
       (match List.assoc_opt "resourceVersion" metadata with
        | Some (`String version) -> Ok (Some version)
        | _ -> Error "Secret metadata has no resourceVersion")
     | _ -> Error "Secret has no metadata")
  | _ -> Error "Secret response is not an object"
;;

let verify_sol_managed_secret = function
  | None -> Ok ()
  | Some (`Assoc fields) ->
    (match List.assoc_opt "metadata" fields with
     | Some (`Assoc metadata) ->
       (match List.assoc_opt "labels" metadata with
        | Some (`Assoc labels) ->
          (match List.assoc_opt "app.kubernetes.io/managed-by" labels with
           | Some (`String "sol") -> Ok ()
           | Some (`String owner) -> Error ("Secret is marked as managed by " ^ owner)
           | _ -> Error "Secret ownership is unknown (missing Sol managed-by label)")
        | _ -> Error "Secret ownership is unknown (missing metadata labels)")
     | _ -> Error "Secret response has no metadata")
  | Some _ -> Error "Secret response is not an object"
;;

let verify_runtime_secret_owner = function
  | None -> Ok ()
  | Some (`Assoc fields) ->
    (match List.assoc_opt "metadata" fields with
     | Some (`Assoc metadata) ->
       (match List.assoc_opt "labels" metadata with
        | None -> Ok ()
        | Some (`Assoc labels) ->
          (match List.assoc_opt "app.kubernetes.io/managed-by" labels with
           | None -> Ok ()
           | Some (`String "sol") -> Ok ()
           | Some (`String owner) -> Error ("Secret is marked as managed by " ^ owner)
           | _ -> Error "Secret ownership is unknown (invalid Sol managed-by label)")
        | _ -> Error "Secret ownership is unknown (invalid metadata labels)")
     | _ -> Error "Secret has no metadata")
  | Some _ -> Error "Secret response is not an object"
;;

let apply_unit_values ~ctx ~namespace ~secret_name values =
  match values with
  | [] -> Ok false
  | _ ->
    let* () = ensure_namespace ~ctx namespace in
    let* before = get_named_secret_json ~ctx ~name:secret_name namespace in
    let* () = verify_sol_managed_secret before in
    let* before_version =
      match before with
      | None -> Ok None
      | Some json -> secret_resource_version json
    in
    let* () =
      apply_manifest
        ~ctx
        ~redact:(List.map snd values)
        (unit_secret_manifest ~namespace ~secret_name values)
    in
    let* after = get_named_secret_json ~ctx ~name:secret_name namespace in
    let* after_version =
      match after with
      | None ->
        Error (Printf.sprintf "Secret %s/%s is absent after apply" namespace secret_name)
      | Some json -> secret_resource_version json
    in
    Ok (before_version <> after_version)
;;

let data_keys = function
  | `Assoc fields ->
    (match List.assoc_opt "data" fields with
     | Some (`Assoc data) -> data
     | _ -> [])
  | _ -> []
;;

let existing_data = function
  | None -> []
  | Some json ->
    List.filter_map
      (function
        | k, `String v -> Some (k, v)
        | _ -> None)
      (data_keys json)
;;

let require_namespaces namespaces =
  match namespaces with
  | [] -> Error "no target namespaces found for this workspace"
  | _ -> Ok ()
;;

let iter_namespaces namespaces ~f =
  List.fold_left (fun acc ns -> Result.bind acc (fun () -> f ns)) (Ok ()) namespaces
;;

let external_secret_targets ~ctx namespace =
  let outcome =
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:
        [ "get"
        ; "externalsecrets"
        ; "-n"
        ; namespace
        ; "-o"
        ; "jsonpath={range \
           .items[*]}{.metadata.name}{\\t}{.spec.target.name}{\"\\n\"}{end}"
        ]
  in
  match outcome with
  | Ok output ->
    let output = output.Sol_cli_process.stdout in
    Ok
      (output
       |> String.split_on_char '\n'
       |> List.map String.trim
       |> List.filter (fun line -> line <> "")
       |> List.map (fun line ->
         match String.split_on_char '\t' line with
         | [ _name; target ] when String.trim target <> "" -> String.trim target
         | [ name ] -> String.trim name
         | name :: _ -> String.trim name
         | [] -> line))
  | Error error ->
    let message = Sol_cli_process.error_to_string error in
    if
      Sol_cli_string.contains ~needle:"doesn't have a resource type" message
      || Sol_cli_string.contains ~needle:"no matches for kind" message
    then Ok []
    else
      Error
        (Printf.sprintf
           "could not determine whether namespace %s rotates secrets through External \
            Secrets Operator: %s"
           namespace
           message)
;;

let refuse_external_secret_target ~ctx ~namespace ~secret_name =
  let* targets = external_secret_targets ~ctx namespace in
  if List.mem secret_name targets
  then
    Error
      (Printf.sprintf
         "refusing to write Secret %s/%s: an ExternalSecret already targets this object"
         namespace
         secret_name)
  else Ok ()
;;

(** Read any object of a kind, for an ownership check. [Ok None] is "not there". *)
let get_named_object_json ~ctx ~resource ~namespace ~name =
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:[ "get"; resource; name; "-n"; namespace; "-o"; "json" ]
  with
  | Ok None -> Ok None
  | Ok (Some json) ->
    Sol_cli_json.decode ~what:(Printf.sprintf "%s %s/%s" resource namespace name) json
    |> Result.map Option.some
  | Error e ->
    Error
      (Printf.sprintf
         "could not read %s %s/%s: %s"
         resource
         namespace
         name
         (Sol_cli_process.error_to_string e))
;;

(** The guard every delivered object goes through before Sol writes it.

    What is already at the destination decides whether Sol may write there: nothing, or
    something Sol owns. Anything else is refused — another manager's object, or one whose
    ownership cannot be established — because overwriting it takes a credential out from
    under whoever put it there, and the write would look like it succeeded.

    A **Secret** is additionally refused where an ExternalSecret already targets it: two
    writers for one object is a race ESO wins silently, and the loser is whichever writer
    ran first. The external owner's own objects are checked the same way — the ExternalSecret
    an external target publishes must be Sol's or absent, so a target cannot quietly take
    over a projection another target still reads. *)
let assert_destination_is_sol ~ctx ~resource ~namespace ~name =
  let open Result.Syntax in
  let* () =
    if String.equal resource "secret"
    then refuse_external_secret_target ~ctx ~namespace ~secret_name:name
    else Ok ()
  in
  let* existing = get_named_object_json ~ctx ~resource ~namespace ~name in
  verify_sol_managed_secret existing
;;

let verify_platform_secret_destinations ~ctx ~namespaces =
  let* () = require_namespaces namespaces in
  iter_namespaces namespaces ~f:(fun namespace ->
    let secret_name = Sol_cli_manifest.runtime_secret_name in
    let* () = ensure_namespace ~ctx namespace in
    let* () = refuse_external_secret_target ~ctx ~namespace ~secret_name in
    let* existing = get_named_secret_json ~ctx ~name:secret_name namespace in
    verify_runtime_secret_owner existing)
;;

let set_named_key
      ?(allow_unlabeled_runtime = false)
      ~ctx
      ~namespace
      ~secret_name
      ~key
      ~value
      ()
  =
  let* () = validate_key key in
  let* () = ensure_namespace ~ctx namespace in
  let* () = refuse_external_secret_target ~ctx ~namespace ~secret_name in
  let* existing = get_named_secret_json ~ctx ~name:secret_name namespace in
  let* () =
    if allow_unlabeled_runtime
    then verify_runtime_secret_owner existing
    else verify_sol_managed_secret existing
  in
  let* before_version =
    match existing with
    | None -> Ok None
    | Some json -> secret_resource_version json
  in
  let existing_data = existing_data existing in
  let* () =
    apply_manifest
      ~ctx
      ~redact:(List.map snd existing_data @ [ value ])
      (named_secret_manifest
         ~labels:[ "app.kubernetes.io/managed-by", "sol" ]
         ~secret_name
         ~existing_data
         ~namespace
         ~key
         ~value)
  in
  let* after = get_named_secret_json ~ctx ~name:secret_name namespace in
  let* after_version =
    match after with
    | None ->
      Error (Printf.sprintf "Secret %s/%s is absent after apply" namespace secret_name)
    | Some json -> secret_resource_version json
  in
  Ok (before_version <> after_version)
;;

let set_unit_key ~ctx ~namespace ~secret_name ~key ~value =
  set_named_key ~ctx ~namespace ~secret_name ~key ~value ()
;;

(* 2b: the Kafka credentials are the only platform Job inputs left; a database
   connection is delivered by the deploy as `<target>-dml-creds` / `<target>-ddl-creds`. *)
let platform_secret_keys = [ "KAFKA_SASL_PASSWORD"; "KAFKA_SSL_CA_CERT" ]

let set_platform_key ~ctx ~namespaces ~key ~value =
  let* () = validate_key key in
  if not (List.mem key platform_secret_keys)
  then Error (Printf.sprintf "%s is not a supported Sol platform Job secret" key)
  else
    let* () = require_namespaces namespaces in
    let* () = verify_platform_secret_destinations ~ctx ~namespaces in
    let changed = ref [] in
    let* () =
      iter_namespaces namespaces ~f:(fun namespace ->
        let* is_changed =
          set_named_key
            ~allow_unlabeled_runtime:true
            ~ctx
            ~namespace
            ~secret_name:Sol_cli_manifest.runtime_secret_name
            ~key
            ~value
            ()
        in
        if is_changed then changed := namespace :: !changed;
        Ok ())
    in
    Ok (List.rev !changed)
;;

let delete_platform_key ~ctx ~namespaces ~key =
  let* () = validate_key_format key in
  if not (List.mem key platform_secret_keys)
  then Error (Printf.sprintf "%s is not a supported Sol platform Job secret" key)
  else
    let* () = require_namespaces namespaces in
    let deleted = ref [] in
    let* () =
      iter_namespaces namespaces ~f:(fun namespace ->
        let secret_name = Sol_cli_manifest.runtime_secret_name in
        let* () = refuse_external_secret_target ~ctx ~namespace ~secret_name in
        let* existing = get_named_secret_json ~ctx ~name:secret_name namespace in
        let* () = verify_runtime_secret_owner existing in
        match existing with
        | None -> Ok ()
        | Some json when not (List.mem_assoc key (data_keys json)) -> Ok ()
        | Some _ ->
          let patch = Printf.sprintf "[{\"op\":\"remove\",\"path\":\"/data/%s\"}]" key in
          let* _ =
            Sol_cli_kubectl.patch
              ~ctx
              ~resource:"secret"
              ~name:secret_name
              ~namespace
              ~patch_type:"json"
              ~patch
            |> Result.map_error Sol_cli_process.error_to_string
          in
          deleted := namespace :: !deleted;
          Ok ())
    in
    Ok (List.rev !deleted)
;;

let delete_unit_key ~ctx ~namespace ~secret_name ~key =
  let* () = validate_key_format key in
  let* () = refuse_external_secret_target ~ctx ~namespace ~secret_name in
  let* existing = get_named_secret_json ~ctx ~name:secret_name namespace in
  let* () = verify_sol_managed_secret existing in
  match existing with
  | None -> Ok false
  | Some json ->
    if not (List.mem_assoc key (data_keys json))
    then Ok false
    else (
      let patch = Printf.sprintf "[{\"op\":\"remove\",\"path\":\"/data/%s\"}]" key in
      Sol_cli_kubectl.patch
        ~ctx
        ~resource:"secret"
        ~name:secret_name
        ~namespace
        ~patch_type:"json"
        ~patch
      |> Result.map (fun _ -> true)
      |> Result.map_error (fun error ->
        Printf.sprintf
          "could not delete key %s from Secret %s/%s: %s"
          key
          namespace
          secret_name
          (Sol_cli_process.error_to_string error)))
;;

(** The keys a delivered Secret must hold. [hint] overrides the guidance appended to the
    failure, so a caller whose Secret is written by something other than the operator does
    not tell the reader to write it by hand. *)
let verify_required_keys ?hint ~ctx ~namespace ~secret_name ~required_keys () =
  let* json = get_named_secret_json ~ctx ~name:secret_name namespace in
  let data = existing_data json in
  let missing =
    required_keys
    |> List.filter (fun key ->
      match List.assoc_opt key data with
      | Some value -> String.trim value = ""
      | None -> true)
  in
  match missing with
  | [] -> Ok ()
  | _ ->
    let hint =
      Option.value
        hint
        ~default:
          "Sol's ordinary deploy and rollback deliver secret references only and never \
           write values; set application values with `sol secret set <TARGET> \
           <DOMAIN/UNIT/KEY>` or platform Job inputs with `sol secret set <TARGET> \
           @platform/<KEY>`, then try again."
    in
    Error
      (Printf.sprintf
         "%s/%s does not hold the required non-empty secret key(s): %s. %s"
         namespace
         secret_name
         (String.concat ", " missing)
         hint)
;;

let verify_workload_secret ~ctx (spec : Sol_cli_deployment_plan.service_spec) =
  let transport = Sol_cli_manifest.kafka_transport_of_config spec.config in
  let name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
  (* Which keys this unit's own Secret must hold is the routing decision itself: a key the
     target's database binding supplies or an external authority owns is delivered
     elsewhere. Asking the one routing function keeps this from re-deriving the capability
     filter the plan already applies. *)
  let db_dml_creds_name =
    Option.map Sol_cli_database_setup_render.dml_creds_name spec.db_uses_target
  in
  let unit_secret_name = Sol_cli_manifest.workload_secret_name name in
  let required =
    Sol_cli_manifest.required_secret_keys
      ~transport
      ~db_uses_target:(Option.is_some spec.db_uses_target)
      (List.map fst spec.secrets)
    |> List.filter (fun key ->
      String.equal
        (Sol_cli_manifest_yaml.secret_name_for_key
           ~name
           ~secret_sources:spec.secret_sources
           ~db_dml_creds_name
           key)
        unit_secret_name)
  in
  verify_required_keys
    ~ctx
    ~namespace:(Sol_cli_deployment_plan.namespace_to_string spec.namespace)
    ~secret_name:unit_secret_name
    ~required_keys:required
    ()
;;

let json_object = function
  | `Assoc fields -> fields
  | _ -> []
;;

let json_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | Some (`Int value) -> Some (string_of_int value)
  | Some (`Intlit value) -> Some value
  | _ -> None
;;

(* One interpreter for the ESO condition, shared by the deploy gate and `sol secret
   status`, so the two can never disagree. External Secrets Operator's
   ExternalSecretStatusCondition carries only type/status/reason/message/lastTransitionTime
   (verified against the upstream API through v0.20 and the current v1 spec): it publishes no
   observedGeneration, so freshness is established from status.syncedResourceVersion instead
   (see [synced_version_matches]). *)
type eso_state =
  | Eso_synced of
      { generation : string option
      ; synced_version : string option
      ; refresh_time : string option
      }
  | Eso_not_ready of string

let eso_state_of_json json =
  let root = json_object json in
  let metadata =
    json_object (Option.value (List.assoc_opt "metadata" root) ~default:`Null)
  in
  let generation = json_string "generation" metadata in
  let status = json_object (Option.value (List.assoc_opt "status" root) ~default:`Null) in
  let conditions =
    match List.assoc_opt "conditions" status with
    | Some (`List rows) -> rows
    | _ -> []
  in
  match
    conditions
    |> List.map json_object
    |> List.find_opt (fun fields -> json_string "type" fields = Some "Ready")
  with
  | None -> Eso_not_ready "Ready condition absent"
  | Some condition ->
    let state = json_string "status" condition in
    let reason = json_string "reason" condition in
    if state <> Some "True" || reason <> Some "SecretSynced"
    then Eso_not_ready (Option.value reason ~default:"not ready")
    else
      Eso_synced
        { generation
        ; synced_version = json_string "syncedResourceVersion" status
        ; refresh_time = json_string "refreshTime" status
        }
;;

let eso_sync_timeout_s = 150.
let eso_sync_poll_s = 2.

(* ESO sets status.syncedResourceVersion to "<metadata.generation>-<hash>" on each
   successful sync, and only writes it when the object changed (its own shouldRefresh
   compares the two), so a matching generation means ESO processed the spec we applied and
   a periodic refresh cannot produce that value. The format is an implementation detail
   rather than a documented API guarantee, so it is a best-effort signal: absent,
   unrecognized, or not advanced within the bound, we proceed on Ready=True/SecretSynced
   and warn. This never fails closed on the format. *)
let synced_version_matches ~generation synced_version =
  match generation, synced_version with
  | Some generation, Some version ->
    Some
      (Option.is_some
         (Sol_cli_string.strip_prefix_opt ~prefix:(generation ^ "-") version))
  | _ -> None
;;

let wait_for_external_secret_sync ~timeout_s ~poll_s ~ctx ~namespace ~external_name =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec poll () =
    let* output =
      Sol_cli_kubectl.get_raw
        ~ctx
        ~args:[ "get"; "externalsecret"; external_name; "-n"; namespace; "-o"; "json" ]
      |> Result.map_error (fun error ->
        Printf.sprintf
          "could not read ExternalSecret %s/%s: %s"
          namespace
          external_name
          (Sol_cli_process.error_to_string error))
    in
    let* external_secret =
      Sol_cli_json.decode
        ~what:(Printf.sprintf "ExternalSecret %s/%s" namespace external_name)
        output.Sol_cli_process.stdout
    in
    let expired () = Unix.gettimeofday () >= deadline in
    match eso_state_of_json external_secret with
    | Eso_not_ready reason ->
      if expired ()
      then
        Error
          (Printf.sprintf
             "ExternalSecret %s/%s is not SecretSynced (%s)"
             namespace
             external_name
             reason)
      else (
        Unix.sleepf poll_s;
        poll ())
    | Eso_synced { generation; synced_version; refresh_time = _ } ->
      (match synced_version_matches ~generation synced_version with
       | Some true -> Ok ()
       | Some false ->
         (* A *known* mismatch: what ESO published has not reached the spec this selection
            asks for. Proceeding is how a changed binding quietly keeps serving the old
            database — the previous ExternalSecret still reports Ready, its Secret still
            carries the key, and a key check passes. *)
         if expired ()
         then
           Error
             (Printf.sprintf
                "ExternalSecret %s/%s has not synced the spec this selection asks for: \
                 syncedResourceVersion %s has not reached generation %s. Refusing to \
                 treat the previous sync as evidence for this one."
                namespace
                external_name
                (Option.value synced_version ~default:"unknown")
                (Option.value generation ~default:"unknown"))
         else (
           Unix.sleepf poll_s;
           poll ())
       | None ->
         (* No freshness evidence at all. "Unsupported" is not "fresh": without a
            generation-bound version there is nothing that distinguishes this selection's
            sync from an earlier one's, and the same silent substitution follows. Ready
            alone is not evidence about *which* spec was synced. *)
         Error
           (Printf.sprintf
              "ExternalSecret %s/%s reports Ready but carries no generation-bound synced \
               version (%s), so there is no evidence the sync belongs to this selection. \
               Refusing to proceed on readiness alone."
              namespace
              external_name
              (match generation, synced_version with
               | _, None -> "status.syncedResourceVersion is absent"
               | None, _ -> "metadata.generation is absent"
               | Some _, Some _ -> "the synced version is not a generation prefix")))
  in
  poll ()
;;

let verify_external_secret_ready
      ?(timeout_s = eso_sync_timeout_s)
      ?(poll_s = eso_sync_poll_s)
      ~ctx
      (spec : Sol_cli_deployment_plan.service_spec)
  =
  let external_keys =
    spec.secret_sources
    |> List.filter_map (fun (key, source) ->
      match source with
      | Sol_cli_manifest.Sol_managed -> None
      | External _ -> Some key)
  in
  match external_keys with
  | [] -> Ok ()
  | _ ->
    let namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace in
    let unit_name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
    let external_name = Sol_cli_manifest.external_secret_name unit_name in
    let* () =
      wait_for_external_secret_sync ~timeout_s ~poll_s ~ctx ~namespace ~external_name
    in
    let* materialized =
      get_named_secret_json
        ~ctx
        ~name:(Sol_cli_manifest.external_secret_name unit_name)
        namespace
    in
    let found =
      materialized
      |> Option.to_list
      |> List.concat_map data_keys
      |> List.map fst
      |> List.sort_uniq String.compare
    in
    let expected = List.sort_uniq String.compare external_keys in
    if found = expected
    then Ok ()
    else
      Error
        (Printf.sprintf
           "ESO Secret %s/%s has keys [%s], expected exactly [%s]"
           namespace
           (Sol_cli_manifest.external_secret_name unit_name)
           (String.concat ", " found)
           (String.concat ", " expected))
;;

(** Wait for an ExternalSecret to report Ready/SecretSynced, then check the Secret it wrote
    holds the keys the reader needs. This is {!verify_external_secret_ready}'s two checks for
    a delivered object named for the target rather than a unit (the class Secrets): the
    ExternalSecret and the Secret it targets share [external_name]. [hint] overrides the
    key-check guidance so a class Secret is not reported with `sol secret set`'s instruction
    — ESO, not the operator, is its writer. *)
let verify_external_secret_materialized
      ?(timeout_s = eso_sync_timeout_s)
      ?(poll_s = eso_sync_poll_s)
      ?hint
      ~ctx
      ~namespace
      ~external_name
      ~required_keys
      ()
  =
  let* () =
    wait_for_external_secret_sync ~timeout_s ~poll_s ~ctx ~namespace ~external_name
  in
  verify_required_keys ?hint ~ctx ~namespace ~secret_name:external_name ~required_keys ()
;;

let external_secret_status ~ctx ~namespace ~unit_name ~expected_keys =
  let external_keys = List.sort_uniq String.compare expected_keys in
  match external_keys with
  | [] -> Ok "not applicable"
  | _ ->
    let name = Sol_cli_manifest.external_secret_name unit_name in
    let* raw =
      Sol_cli_kubectl.get_if_present
        ~ctx
        ~args:[ "get"; "externalsecret"; name; "-n"; namespace; "-o"; "json" ]
      |> Result.map_error (fun error ->
        Printf.sprintf
          "could not observe ExternalSecret %s/%s: %s"
          namespace
          name
          (Sol_cli_process.error_to_string error))
    in
    (match raw with
     | None -> Ok "missing"
     | Some raw ->
       let* json =
         Sol_cli_json.decode
           ~what:(Printf.sprintf "ExternalSecret %s/%s" namespace name)
           raw
       in
       (match eso_state_of_json json with
        | Eso_not_ready reason -> Ok ("not ready (" ^ reason ^ ")")
        | Eso_synced { refresh_time; _ } ->
          let* materialized = get_named_secret_json ~ctx ~name namespace in
          let found =
            materialized
            |> Option.to_list
            |> List.concat_map data_keys
            |> List.map fst
            |> List.sort_uniq String.compare
          in
          let expected = List.sort_uniq String.compare external_keys in
          if found <> expected
          then Ok "materialized keys differ from declaration"
          else
            Ok
              ("ready (SecretSynced"
               ^ Option.fold
                   ~none:""
                   ~some:(fun time -> "; refreshed " ^ time)
                   refresh_time
               ^ ")")))
;;

let verify_external_secret_destination ~ctx (spec : Sol_cli_deployment_plan.service_spec) =
  let external_keys =
    spec.secret_sources
    |> List.filter_map (fun (key, source) ->
      match source with
      | Sol_cli_manifest.Sol_managed -> None
      | External _ -> Some key)
  in
  match external_keys with
  | [] -> Ok ()
  | _ ->
    let namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace in
    let unit_name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
    let es_name = Sol_cli_manifest.external_secret_name unit_name in
    let target_name = es_name in
    let* es_raw =
      Sol_cli_kubectl.get_if_present
        ~ctx
        ~args:[ "get"; "externalsecret"; es_name; "-n"; namespace; "-o"; "json" ]
      |> Result.map_error (fun error ->
        Printf.sprintf
          "could not inspect ExternalSecret destination %s/%s: %s"
          namespace
          es_name
          (Sol_cli_process.error_to_string error))
    in
    let* es_json =
      match es_raw with
      | None -> Ok None
      | Some raw ->
        Sol_cli_json.decode
          ~what:(Printf.sprintf "ExternalSecret %s/%s" namespace es_name)
          raw
        |> Result.map Option.some
    in
    let external_uid, already_owned =
      match es_json with
      | None -> None, false
      | Some json ->
        let root = json_object json in
        let metadata =
          json_object (Option.value (List.assoc_opt "metadata" root) ~default:`Null)
        in
        let labels =
          json_object (Option.value (List.assoc_opt "labels" metadata) ~default:`Null)
        in
        let uid = json_string "uid" metadata in
        let target =
          json_object (Option.value (List.assoc_opt "spec" root) ~default:`Null)
          |> fun fields ->
          json_object (Option.value (List.assoc_opt "target" fields) ~default:`Null)
        in
        let name_matches = json_string "name" target = Some target_name in
        let owned = json_string "app.kubernetes.io/managed-by" labels = Some "sol" in
        uid, owned && name_matches
    in
    let* () =
      match es_json with
      | None -> Ok ()
      | Some _ when already_owned -> Ok ()
      | Some _ ->
        Error
          (Printf.sprintf
             "refusing to replace ExternalSecret %s/%s: it is not a Sol-owned \
              ExternalSecret targeting %s"
             namespace
             es_name
             target_name)
    in
    let* materialized = get_named_secret_json ~ctx ~name:target_name namespace in
    (match materialized with
     | None -> Ok ()
     | Some json ->
       let root = json_object json in
       let metadata =
         json_object (Option.value (List.assoc_opt "metadata" root) ~default:`Null)
       in
       let owner_refs =
         match List.assoc_opt "ownerReferences" metadata with
         | Some (`List rows) -> rows
         | _ -> []
       in
       let owned_by_external_secret =
         Option.fold
           ~none:false
           ~some:(fun uid ->
             List.exists
               (fun row -> json_string "uid" (json_object row) = Some uid)
               owner_refs)
           external_uid
       in
       if owned_by_external_secret
       then Ok ()
       else
         Error
           (Printf.sprintf
              "refusing to use existing Secret %s/%s as ESO output: its owner is not the \
               declared ExternalSecret"
              namespace
              target_name))
;;

let verify_runtime_secret_keys ~ctx ~namespace ~required_keys =
  verify_required_keys
    ~ctx
    ~namespace
    ~secret_name:Sol_cli_manifest.runtime_secret_name
    ~required_keys
    ()
;;

let unit_secret_keys ~ctx ~namespace ~secret_name =
  let* json = get_named_secret_json ~ctx ~name:secret_name namespace in
  let* () = verify_sol_managed_secret json in
  Ok
    (match json with
     | None -> []
     | Some json -> List.map fst (data_keys json))
;;

let runtime_secret_keys ~ctx ~namespace =
  let* json =
    get_named_secret_json ~ctx ~name:Sol_cli_manifest.runtime_secret_name namespace
  in
  let* () = verify_runtime_secret_owner json in
  Ok
    (match json with
     | None -> []
     | Some json -> List.map fst (data_keys json))
;;
