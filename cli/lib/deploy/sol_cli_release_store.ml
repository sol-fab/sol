let with_temp_json json f =
  Sol_cli_fs.with_temp_file ~prefix:"sol-release-" ~suffix:".json" json f |> Result.join
;;

let metadata_string json key =
  Sol_cli_json.field [ "metadata"; key ] json |> Sol_cli_json.string
;;

let data_of_json json = Sol_cli_json.field [ "data" ] json

let fetch_live ~ctx ~name ~namespace =
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:[ "get"; "configmap"; name; "-n"; namespace; "-o"; "json" ]
  with
  | Ok None -> Ok None
  | Ok (Some body) ->
    Sol_cli_json.decode
      ~what:(Printf.sprintf "the live ConfigMap %s/%s" namespace name)
      body
    |> Result.map (fun json ->
      Some (data_of_json json, metadata_string json "resourceVersion"))
  | Error e ->
    Error
      (Printf.sprintf
         "kubectl get configmap %s failed: %s"
         name
         (Sol_cli_process.error_to_string e))
;;

let with_resource_version json (resource_version : string option) =
  match resource_version, json with
  | Some rv, `Assoc fields ->
    let meta =
      Sol_cli_json.field [ "metadata" ] json
      |> Sol_cli_json.assoc
      |> Option.value ~default:[]
    in
    let meta =
      ("resourceVersion", `String rv) :: List.remove_assoc "resourceVersion" meta
    in
    `Assoc (("metadata", `Assoc meta) :: List.remove_assoc "metadata" fields)
  | _ -> json
;;

let write_one ~ctx ~verb ~name json =
  with_temp_json (Yojson.Safe.to_string json) (fun path ->
    let result =
      match verb with
      | `Create -> Sol_cli_kubectl.create ~ctx ~file:path
      | `Replace -> Sol_cli_kubectl.replace ~ctx ~file:path
    in
    match result with
    | Ok _ -> Ok ()
    | Error (Sol_cli_process.Non_zero r) ->
      Error
        (Printf.sprintf
           "kubectl %s configmap %s failed: %s"
           (match verb with
            | `Create -> "create"
            | `Replace -> "replace")
           name
           (Sol_cli_process.failure_message r))
    | Error e -> Error (Sol_cli_process.error_to_string e))
;;

let write_json ~ctx json =
  let open Result.Syntax in
  match metadata_string json "name", metadata_string json "namespace" with
  | None, _ | _, None -> Error "release ConfigMap is missing metadata.name/namespace"
  | Some name, Some namespace ->
    let* live = fetch_live ~ctx ~name ~namespace in
    (match live with
     | Some (live_data, _) when live_data = data_of_json json -> Ok ()
     | Some (_, live_rv) ->
       let immutable =
         match Sol_cli_json.bool (Sol_cli_json.field [ "immutable" ] json) with
         | Some true -> true
         | Some false | None -> false
       in
       if immutable
       then
         (* The content-addressed release object is immutable by design. A re-deploy of
            the same release can nevertheless recover UID evidence that was missing or
            changed (a recreated workload, or a failed capture). Kubernetes rejects a
            data change on an immutable ConfigMap, so replace the object rather than
            failing after the workloads were applied. *)
         let* () =
           Sol_cli_kubectl.delete ~ctx ~resource:"configmap" ~name ~namespace
           |> Result.map_error Sol_cli_process.error_to_string
         in
         write_one ~ctx ~verb:`Create ~name json
       else write_one ~ctx ~verb:`Replace ~name (with_resource_version json live_rv)
     | None -> write_one ~ctx ~verb:`Create ~name json)
;;

let parse_configmap json = Sol_cli_json.decode ~what:"release ConfigMap" json

let record ~ctx (t : Sol_cli_release.t) : (unit, string) result =
  let open Result.Syntax in
  let* record = parse_configmap (Sol_cli_release.to_configmap_json t) in
  let* () = write_json ~ctx record in
  let* current = parse_configmap (Sol_cli_release.to_current_configmap_json t) in
  write_json ~ctx current
;;

let record_plan
      ~ctx
      ~(apply_mode : Sol_cli_release.apply_mode)
      ~(retained : Sol_cli_release.recorded_workload list)
      ~(owned : Sol_cli_release_id.owned_object list)
      (plan : Sol_cli_deployment_plan.t)
  : (string, string) result
  =
  let boundary =
    Sol_cli_release.of_plan_with_boundary ~owned ~apply_mode ~retained plan
  in
  let open Result.Syntax in
  let* () = record ~ctx boundary in
  Ok boundary.Sol_cli_release.release_id
;;

let list_with_creation ~ctx ~(workspace : string)
  : ((Sol_cli_release.t * string) list, string) result
  =
  let selector =
    Printf.sprintf
      "sol.dev/type=release,sol.dev/workspace=%s"
      (Sol_cli_release.sanitize_label workspace)
  in
  match
    Sol_cli_kubectl.get_raw
      ~ctx
      ~args:[ "get"; "configmap"; "-n"; "default"; "-l"; selector; "-o"; "json" ]
  with
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = Sol_cli_process.failure_message r in
    Error (Printf.sprintf "kubectl get configmap failed: %s" (String.trim detail))
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok r ->
    Sol_cli_json.decode ~what:"kubectl output" r.stdout
    |> Fun.flip Result.bind Sol_cli_release.parse_kubectl_list_with_creation
;;

let list ~ctx ~(workspace : string) : (Sol_cli_release.t list, string) result =
  list_with_creation ~ctx ~workspace |> Result.map (List.map fst)
;;

let get ~ctx ~(workspace : string) ~(release_id : string)
  : (Sol_cli_release.t, string) result
  =
  let open Result.Syntax in
  let* id = Sol_cli_release_id.of_string release_id in
  let name = Printf.sprintf "sol-release-%s" (Sol_cli_release_id.to_string id) in
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:[ "get"; "configmap"; name; "-n"; "default"; "-o"; "json" ]
  with
  | Ok None ->
    Error (Printf.sprintf "release %s not found" (Sol_cli_release_id.to_string id))
  | Error e ->
    Error
      (Printf.sprintf
         "kubectl get configmap failed: %s"
         (Sol_cli_process.error_to_string e))
  | Ok (Some body) ->
    let* json = Sol_cli_json.decode ~what:"kubectl output" body in
    let* record = Sol_cli_release.of_kubectl_item json in
    if String.equal record.workspace workspace
    then Ok record
    else
      Error
        (Printf.sprintf
           "release %s belongs to workspace %S, not %S"
           (Sol_cli_release_id.to_string id)
           record.workspace
           workspace)
;;

let current ~ctx ~(workspace : string) : (string option, string) result =
  let name = Sol_cli_release.current_configmap_name ~workspace in
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:
        [ "get"; "configmap"; name; "-n"; "default"; "-o"; "jsonpath={.data.release_id}" ]
  with
  | Ok None -> Ok None
  | Ok (Some release_id) ->
    (match Sol_cli_string.non_blank (String.trim release_id) with
     | Some release_id -> Ok (Some release_id)
     | None -> Error "current release ConfigMap has no data.release_id")
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

let current_record ~ctx ~(workspace : string) : (Sol_cli_release.t option, string) result =
  let name = Sol_cli_release.current_configmap_name ~workspace in
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:[ "get"; "configmap"; name; "-n"; "default"; "-o"; "json" ]
  with
  | Error e -> Error (Sol_cli_process.error_to_string e)
  | Ok None -> Ok None
  | Ok (Some body) ->
    let open Result.Syntax in
    let* json = Sol_cli_json.decode ~what:"current release ConfigMap" body in
    (match Sol_cli_json.field [ "data"; "release_id" ] json |> Sol_cli_json.string with
     | None -> Error "current release ConfigMap has no data.release_id"
     | Some release_id ->
       (match Sol_cli_string.non_blank (String.trim release_id) with
        | None -> Error "current release ConfigMap has an empty data.release_id"
        | Some release_id -> get ~ctx ~workspace ~release_id |> Result.map Option.some))
;;

(* The UID evidence the workspace's current release recorded at apply, for deciding which
   live objects a removal path may act on. An absent record is no evidence (a first
   deploy); an unreadable one is reported so the caller retains rather than guesses
   (docs/architecture/ownership.md). *)
let recorded_evidence ~ctx ~(workspace : string)
  : (Sol_cli_release_id.owned_object list, string) result
  =
  current_record ~ctx ~workspace
  |> Result.map (function
    | None -> []
    | Some (release : Sol_cli_release.t) ->
      List.concat_map
        (fun (w : Sol_cli_release.recorded_workload) -> w.Sol_cli_release_id.owned)
        release.workloads)
;;

let deployed_contract ~ctx ~(workspace : string)
  : (Sol_cli_release_id.contract_fact list, string) result
  =
  match current ~ctx ~workspace with
  | Error msg ->
    Error
      (Printf.sprintf
         "the deployed contract could not be observed: reading the current release \
          pointer failed: %s"
         msg)
  | Ok None -> Ok []
  | Ok (Some release_id) ->
    (match get ~ctx ~workspace ~release_id with
     | Ok record -> Ok record.Sol_cli_release.contract
     | Error msg ->
       Error
         (Printf.sprintf
            "the deployed contract could not be observed: the current release %s could \
             not be read: %s"
            release_id
            msg))
;;

let delete ~ctx ~(release_id : string) : (unit, string) result =
  let open Result.Syntax in
  let* id = Sol_cli_release_id.of_string release_id in
  let name = Printf.sprintf "sol-release-%s" (Sol_cli_release_id.to_string id) in
  Sol_cli_kubectl.delete ~ctx ~resource:"configmap" ~name ~namespace:"default"
  |> Result.map_error Sol_cli_process.error_to_string
;;

let move_pointer ~ctx (t : Sol_cli_release.t) : (unit, string) result =
  Result.bind
    (parse_configmap (Sol_cli_release.to_current_configmap_json t))
    (write_json ~ctx)
;;

let retained_for_plan ~ctx ~workspace ~whole
  : (Sol_cli_release.recorded_workload list, string) result
  =
  if whole
  then Ok []
  else (
    (* An unreadable current record is not an empty one. Retaining nothing would drop the
     inherited workloads' recorded UIDs from the next release, so destroy could no longer
     release them. A whole-workspace plan does not inherit, but it can only know that
     after this read succeeds; a first deploy has an absent pointer, which is [Ok None]. *)
    match current ~ctx ~workspace with
    | Error message -> Error message
    | Ok None -> Ok []
    | Ok (Some release_id) ->
      (match get ~ctx ~workspace ~release_id with
       | Ok record -> Ok record.Sol_cli_release.workloads
       | Error message -> Error message))
;;
