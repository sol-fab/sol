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

(** Read one delivered value. The caller must already know the Secret is the authority's
    projection; this only decodes what Kubernetes carries. *)
let read_secret_key ~ctx ~namespace ~secret_name ~key =
  let open Result.Syntax in
  let* json = get_named_secret_json ~ctx ~name:secret_name namespace in
  match json with
  | None -> Error (Printf.sprintf "Secret %s/%s does not exist" namespace secret_name)
  | Some json ->
    (match List.assoc_opt key (data_keys json) with
     | Some (`String encoded) ->
       (try Ok (Base64.decode_exn encoded) with
        | _ ->
          Error
            (Printf.sprintf
               "Secret %s/%s key %s is not valid base64"
               namespace
               secret_name
               key))
     | _ -> Error (Printf.sprintf "Secret %s/%s has no key %s" namespace secret_name key))
;;

let has_data_field = function
  | `Assoc fields -> List.mem_assoc "data" fields
  | _ -> false
;;

(** Did a `kubectl` failure carry this server reason? The reason is the diagnostic Kubernetes
    emitted, not a Sol guess — Sol only branches on it to decide the next call. *)
let failure_says failure needle =
  match failure with
  | Sol_cli_process.Non_zero { stderr; stdout; _ } ->
    Sol_cli_string.contains ~needle stderr || Sol_cli_string.contains ~needle stdout
  | Sol_cli_process.Spawn_failed _ | Sol_cli_process.Timeout _ -> false
;;

(** A key-scoped write: one JSON patch atomically adds the selected keys to the live object's `data` (or
    creates `data` when the object has none), so a concurrent writer of a *different* key is
    merged, not overwritten.

    The old write re-applied a whole-object manifest built from a snapshot read before the
    other writer ran, so whichever applied last restored the other's old value (#1426). The
    patch cannot do that: it names only the selected paths.

    `data` is the field, matching the delete path (`/data/<key>`), so the module has one
    encoding — standard base64, the Secret's stored form — rather than mixing `data` and the
    plaintext `stringData` convenience field. The value is base64-encoded here because a patch
    addresses stored fields directly; this is the one place Sol must encode.

    The identity precondition rides in the same request: a `test` op on the Sol managed-by
    label, so under the strict rule there is no window between "this Secret is Sol's" and the
    write. *)
let secret_keys_patch ~json ~values =
  let encoded =
    List.map (fun (key, value) -> key, `String (Base64.encode_exn value)) values
  in
  (* Every existing destination has passed the strict Sol ownership check. *)
  let test_label =
    [ `Assoc
        [ "op", `String "test"
        ; "path", `String "/metadata/labels/app.kubernetes.io~1managed-by"
        ; "value", `String "sol"
        ]
    ]
  in
  (* Adding an absent /data map would replace keys introduced since the read.
     Refuse that stale snapshot; the next deployment can reconcile the fresh object. *)
  let* test_version =
    if has_data_field json
    then Ok []
    else
      let* version = secret_resource_version json in
      match version with
      | Some version ->
        Ok
          [ `Assoc
              [ "op", `String "test"
              ; "path", `String "/metadata/resourceVersion"
              ; "value", `String version
              ]
          ]
      | None -> Error "Secret metadata has no resourceVersion"
  in
  let add_keys =
    if has_data_field json
    then
      List.map
        (fun (key, value) ->
           `Assoc
             [ "op", `String "add"; "path", `String ("/data/" ^ key); "value", value ])
        encoded
    else
      [ `Assoc [ "op", `String "add"; "path", `String "/data"; "value", `Assoc encoded ] ]
  in
  Ok (Yojson.Safe.to_string (`List (test_label @ test_version @ add_keys)))
;;

let create_named_secret ~ctx ~namespace ~secret_name ~values =
  let manifest = unit_secret_manifest ~secret_name ~namespace values in
  Sol_cli_fs.with_temp_file ~prefix:"sol-secret-" ~suffix:".yaml" manifest (fun path ->
    Sol_cli_kubectl.create ~ctx ~file:path)
;;

(** Patch the selected keys atomically; on a missing object create it; if a concurrent writer created it first
    (the create races to `AlreadyExists`), **re-read** and retry once.

    An absent object is created first, never patched without ownership evidence. If
    another writer wins creation, rebuilding from a fresh read re-runs the ownership
    rule and attaches the normal identity precondition before any patch. *)
let write_named_secret_keys ~ctx ~namespace ~secret_name ~values ~existing =
  let redact message =
    let confidential =
      List.concat_map (fun (_, value) -> [ value; Base64.encode_exn value ]) values
    in
    Sol_cli_process.apply_redactions confidential message
  in
  let patch_once json =
    let* patch = secret_keys_patch ~json ~values in
    Sol_cli_fs.with_temp_file
      ~prefix:"sol-secret-patch-"
      ~suffix:".json"
      patch
      (fun file ->
         Sol_cli_kubectl.patch_file
           ~ctx
           ~resource:"secret"
           ~name:secret_name
           ~namespace
           ~patch_type:"json"
           ~file)
  in
  let failure_message failure =
    Error
      (redact
         (Printf.sprintf
            "could not write Secret %s/%s: %s"
            namespace
            secret_name
            (Sol_cli_process.error_to_string failure)))
  in
  let rec create retries =
    match create_named_secret ~ctx ~namespace ~secret_name ~values with
    | Error message -> Error (redact message)
    | Ok (Ok _) -> Ok ()
    | Ok (Error failure) when failure_says failure "AlreadyExists" && retries > 0 ->
      let* fresh = get_named_secret_json ~ctx ~name:secret_name namespace in
      let* () = verify_sol_managed_secret fresh in
      (match fresh with
       | Some json -> patch (retries - 1) json
       | None ->
         Error
           (Printf.sprintf
              "Secret %s/%s disappeared after concurrent creation; retry the operation"
              namespace
              secret_name))
    | Ok (Error failure) -> failure_message failure
  and patch retries json =
    match patch_once json with
    | Error message -> Error (redact message)
    | Ok (Ok _) -> Ok ()
    | Ok (Error failure) when failure_says failure "NotFound" && retries > 0 ->
      create retries
    | Ok (Error failure) -> failure_message failure
  in
  (* Never patch an object we read as absent: a concurrent creator could own it. *)
  match existing with
  | None -> create 1
  | Some json -> patch 1 json
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

let set_named_keys ~ctx ~namespace ~secret_name ~values () =
  let* () =
    List.fold_left
      (fun result (key, _) ->
         let* () = result in
         validate_key key)
      (Ok ())
      values
  in
  let* () = ensure_namespace ~ctx namespace in
  let* () = refuse_external_secret_target ~ctx ~namespace ~secret_name in
  let* existing = get_named_secret_json ~ctx ~name:secret_name namespace in
  let* () = verify_sol_managed_secret existing in
  (* "Changed" compares only the selected keys against what is about to be written — not a
     before/after of the whole object, which is the read-modify-write shape #1426 removed. A
     value another tool stored with different base64 padding reads as changed here, which only
     costs a redundant patch of the same logical value. *)
  let unchanged =
    match existing with
    | Some json ->
      List.for_all
        (fun (key, value) ->
           List.assoc_opt key (data_keys json) = Some (`String (Base64.encode_exn value)))
        values
    | None -> false
  in
  if unchanged
  then Ok false
  else
    let* () = write_named_secret_keys ~ctx ~namespace ~secret_name ~values ~existing in
    Ok true
;;

let set_unit_key ~ctx ~namespace ~secret_name ~key ~value =
  set_named_keys ~ctx ~namespace ~secret_name ~values:[ key, value ] ()
;;

(** Write a target projection atomically per namespace. A failed namespace leaves
    earlier writes intact; the diagnostic identifies them so retrying is explicit. *)
let set_target_keys ~ctx ~namespaces ~secret_name ~values =
  let* () = require_namespaces namespaces in
  let changed = ref [] in
  let* () =
    iter_namespaces namespaces ~f:(fun namespace ->
      let* is_changed =
        set_named_keys ~ctx ~namespace ~secret_name ~values ()
        |> Result.map_error (fun message ->
          Printf.sprintf
            "Secret projection %s/%s failed: %s"
            namespace
            secret_name
            message)
      in
      if is_changed then changed := namespace :: !changed;
      Ok ())
    |> Result.map_error (fun message ->
      match List.rev !changed with
      | [] -> message
      | namespaces ->
        Printf.sprintf
          "%s\n\
           Secret %s was already updated in namespace(s): %s. These writes were not \
           rolled back. Retry to reconcile the remaining namespaces."
          message
          secret_name
          (String.concat ", " namespaces))
  in
  Ok (List.rev !changed)
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
          "Set application values with `sol secret set <TARGET> <DOMAIN/UNIT/KEY>`. \
           Resource-owned credentials are delivered by the target's resource binding; \
           restore that authority and redeploy instead of writing an application secret."
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
    Option.map
      Sol_cli_database_setup_render.dml_creds_name
      (Sol_cli_resource_binding.postgres_use_target spec.database)
  in
  let unit_secret_name = Sol_cli_manifest.workload_secret_name name in
  let required =
    Sol_cli_manifest.required_secret_keys
      ~transport
      ~db_uses_target:
        (Option.is_some (Sol_cli_resource_binding.postgres_use_target spec.database))
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
   (verified against the upstream v1 API through ESO v2.13.0, 2026-10-17): it publishes no
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
   rather than a documented API guarantee, but "absent" is not "fresh": without a
   generation-bound version there is no evidence that the sync belongs to the spec this
   selection asked for. Both the deploy wait and `sol secret status` decide readiness
   through {!eso_readiness_of_json}, so an absent or lagging version cannot be accepted by
   one and rejected by the other. *)
let synced_version_matches ~generation synced_version =
  match generation, synced_version with
  | Some generation, Some version ->
    Some
      (Option.is_some
         (Sol_cli_string.strip_prefix_opt ~prefix:(generation ^ "-") version))
  | _ -> None
;;

(* **The readiness predicate.** Deploy waits on [Eso_not_ready] and [Eso_generation_lags]
   within its configured bound; [Eso_freshness_unknown] is terminal because waiting cannot
   manufacture a generation-bound version. `sol secret status` evaluates the same value
   once and never waits. *)
type eso_readiness =
  | Eso_ready of { refresh_time : string option }
  | Eso_not_ready_state of string
  | Eso_generation_lags of
      { generation : string option
      ; synced_version : string option
      }
  | Eso_freshness_unknown of string

let eso_readiness_of_json json =
  match eso_state_of_json json with
  | Eso_not_ready reason -> Eso_not_ready_state reason
  | Eso_synced { generation; synced_version; refresh_time } ->
    (match synced_version_matches ~generation synced_version with
     | Some true -> Eso_ready { refresh_time }
     | Some false -> Eso_generation_lags { generation; synced_version }
     | None ->
       Eso_freshness_unknown
         (match generation, synced_version with
          | _, None -> "status.syncedResourceVersion is absent"
          | None, _ -> "metadata.generation is absent"
          | Some _, Some _ -> "the synced version is not a generation prefix"))
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
    match eso_readiness_of_json external_secret with
    | Eso_ready _ -> Ok ()
    | Eso_not_ready_state reason ->
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
    | Eso_generation_lags { generation; synced_version } ->
      (* A *known* mismatch: what ESO published has not reached the spec this selection
         asks for. Proceeding is how a changed binding quietly keeps serving the old
         database — the previous ExternalSecret still reports Ready, its Secret still
         carries the key, and a key check passes. *)
      if expired ()
      then
        Error
          (Printf.sprintf
             "ExternalSecret %s/%s has not synced the spec this selection asks for: \
              syncedResourceVersion %s has not reached generation %s. Refusing to treat \
              the previous sync as evidence for this one."
             namespace
             external_name
             (Option.value synced_version ~default:"unknown")
             (Option.value generation ~default:"unknown"))
      else (
        Unix.sleepf poll_s;
        poll ())
    | Eso_freshness_unknown detail ->
      (* No freshness evidence at all. "Unsupported" is not "fresh": without a
         generation-bound version there is nothing that distinguishes this selection's
         sync from an earlier one's, and the same silent substitution follows. Ready alone
         is not evidence about *which* spec was synced, and no amount of waiting produces
         the missing field, so this is terminal. *)
      Error
        (Printf.sprintf
           "ExternalSecret %s/%s reports Ready but carries no generation-bound synced \
            version (%s), so there is no evidence the sync belongs to this selection. \
            Refusing to proceed on readiness alone."
           namespace
           external_name
           detail)
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
      | External _ -> Some key
      | Target_kafka _ -> None)
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
       (* Evaluate deploy's readiness predicate exactly once, without waiting. Only
          [Eso_ready] may produce "ready": a missing or lagging freshness signal is the
          same observation deploy refuses, so status reports it as not ready too. *)
       (match eso_readiness_of_json json with
        | Eso_not_ready_state reason -> Ok ("not ready (" ^ reason ^ ")")
        | Eso_generation_lags { generation; synced_version } ->
          Ok
            (Printf.sprintf
               "not ready (syncedResourceVersion %s has not reached generation %s)"
               (Option.value synced_version ~default:"unknown")
               (Option.value generation ~default:"unknown"))
        | Eso_freshness_unknown detail ->
          Ok ("not ready (no generation-bound synced version: " ^ detail ^ ")")
        | Eso_ready { refresh_time } ->
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

(** The declared ExternalSecret's uid, or [None] when it does not exist yet. It is the value
    the Secret ESO writes must carry in its [ownerReferences] — see
    {!verify_external_secret_output}. *)
let external_secret_uid ~ctx ~namespace ~external_secret_name =
  let* existing =
    get_named_object_json
      ~ctx
      ~resource:"externalsecret"
      ~namespace
      ~name:external_secret_name
  in
  match existing with
  | None -> Ok None
  | Some json ->
    let root = json_object json in
    let metadata =
      json_object (Option.value (List.assoc_opt "metadata" root) ~default:`Null)
    in
    Ok (json_string "uid" metadata)
;;

(** **The ESO output's ownership**: for a declared ExternalSecret, the Secret it writes must
    be absent or owned by *it* — its [ownerReferences] name [external_uid].

    This is not {!assert_destination_is_sol}'s question. That predicate asks "is this object
    *Sol's* to overwrite?" (the `app.kubernetes.io/managed-by` label) and guards the objects
    **Sol writes**: the ExternalSecret object itself, the class Secrets Sol's setup Job
    writes, platform and runtime Secrets. ESO writes the Secret here, and ESO's output
    carries no Sol label, so the label rule cannot answer for it — it would refuse a
    legitimate re-deploy. [external_uid] is [None] when no ExternalSecret is declared yet,
    and a pre-existing Secret is then refused: nothing declares it.

    Both paths that declare an ExternalSecret — a unit's own and a target's database class —
    go through here, so "who owns this ESO output" is answered once. *)
let verify_external_secret_output ~ctx ~namespace ~external_uid ~secret_name =
  let* materialized = get_named_secret_json ~ctx ~name:secret_name namespace in
  match materialized with
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
           secret_name)
;;

let verify_external_secret_destination ~ctx (spec : Sol_cli_deployment_plan.service_spec) =
  let external_keys =
    spec.secret_sources
    |> List.filter_map (fun (key, source) ->
      match source with
      | Sol_cli_manifest.Sol_managed -> None
      | External _ -> Some key
      | Target_kafka _ -> None)
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
    verify_external_secret_output ~ctx ~namespace ~external_uid ~secret_name:target_name
;;

let unit_secret_keys ~ctx ~namespace ~secret_name =
  let* json = get_named_secret_json ~ctx ~name:secret_name namespace in
  let* () = verify_sol_managed_secret json in
  Ok
    (match json with
     | None -> []
     | Some json -> List.map fst (data_keys json))
;;
