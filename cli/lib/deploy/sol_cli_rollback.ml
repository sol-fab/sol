open Result.Syntax

let reconstruct_error ~release_id ~workload ~fact =
  Printf.sprintf "cannot reconstruct release %s: workload %s %s" release_id workload fact
;;

let decode_call
      ~release_id
      ~workload_name
      (env_var, target_domain, target_name_s, target_namespace_s)
  =
  let fail fact = Error (reconstruct_error ~release_id ~workload:workload_name ~fact) in
  match Sol_cli_kubernetes_name.make_k8s_name target_name_s with
  | Error msg ->
    fail (Printf.sprintf "has an invalid call target name %S: %s" target_name_s msg)
  | Ok target_name ->
    (match Sol_cli_kubernetes_name.make_namespace target_namespace_s with
     | Error msg ->
       fail
         (Printf.sprintf
            "has an invalid call target namespace %S: %s"
            target_namespace_s
            msg)
     | Ok target_namespace ->
       Ok
         { Sol_cli_deployment_plan.env_var
         ; unit_id = target_domain ^ "/" ^ target_name_s
         ; url =
             Sol_cli_kubernetes_name.service_url
               ~namespace:target_namespace
               ~k8s_name:target_name
         ; target_domain
         ; target_name
         ; target_namespace
         })
;;

let decode_calls ~release_id ~workload_name rows =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      let* call = decode_call ~release_id ~workload_name row in
      go (call :: acc) rest
  in
  go [] rows
;;

let decode_volume ~release_id ~workload_name (name, mount_path, size, access_mode_s) =
  match Sol_cli_toml.volume_access_mode_of_string access_mode_s with
  | Error msg ->
    Error
      (reconstruct_error
         ~release_id
         ~workload:workload_name
         ~fact:
           (Printf.sprintf "has an invalid volume access mode %S: %s" access_mode_s msg))
  | Ok access_mode -> Ok { Sol_cli_toml.name; mount_path; size; access_mode }
;;

let decode_volumes ~release_id ~workload_name rows =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      let* v = decode_volume ~release_id ~workload_name row in
      go (v :: acc) rest
  in
  go [] rows
;;

let decode_optional ~release_id ~workload_name ~fact_of decode = function
  | None -> Ok None
  | Some raw ->
    (match decode raw with
     | Ok v -> Ok (Some v)
     | Error msg ->
       Error
         (reconstruct_error ~release_id ~workload:workload_name ~fact:(fact_of raw msg)))
;;

let decode_workload ~release_id ~workspace (w : Sol_cli_release.workload) =
  let* primitive =
    Sol_cli_deployment_plan.primitive_of_string w.primitive
    |> Result.map_error (fun msg ->
      reconstruct_error ~release_id ~workload:w.name ~fact:msg)
  in
  let* k8s_name =
    Sol_cli_deployment_plan.k8s_name_result w.name
    |> Result.map_error (fun err ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Sol_cli_deployment_plan.plan_error_to_string err))
  in
  let* namespace =
    Sol_cli_deployment_plan.namespace_result ~workspace ~domain:w.domain
    |> Result.map_error (fun err ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Sol_cli_deployment_plan.plan_error_to_string err))
  in
  let* cpu =
    Sol_cli_toml.cpu_quantity_of_string w.cpu
    |> Result.map_error (fun msg -> Printf.sprintf "has an invalid cpu %S: %s" w.cpu msg)
    |> Result.map_error (fun fact -> reconstruct_error ~release_id ~workload:w.name ~fact)
  in
  let* memory =
    Sol_cli_toml.memory_quantity_of_string w.memory
    |> Result.map_error (fun msg ->
      Printf.sprintf "has an invalid memory %S: %s" w.memory msg)
    |> Result.map_error (fun fact -> reconstruct_error ~release_id ~workload:w.name ~fact)
  in
  let* rollout_strategy, progressive_delivery =
    Sol_cli_toml.effective_rollout_of_string w.rollout
    |> Result.map_error (fun msg ->
      Printf.sprintf "has an invalid progressive delivery %S: %s" w.rollout msg)
    |> Result.map_error (fun fact -> reconstruct_error ~release_id ~workload:w.name ~fact)
  in
  let* volumes = decode_volumes ~release_id ~workload_name:w.name w.volumes in
  let* scheduled_concurrency =
    Sol_cli_toml.scheduled_concurrency_of_string w.scheduled_concurrency
    |> Result.map_error (fun msg ->
      Printf.sprintf
        "has an invalid scheduled_concurrency %S: %s"
        w.scheduled_concurrency
        msg)
    |> Result.map_error (fun fact -> reconstruct_error ~release_id ~workload:w.name ~fact)
  in
  let* () =
    if w.backoff_limit < 0
    then
      Error
        (reconstruct_error
           ~release_id
           ~workload:w.name
           ~fact:(Printf.sprintf "has an invalid backoff_limit %d" w.backoff_limit))
    else Ok ()
  in
  let* ingress_host =
    decode_optional
      ~release_id
      ~workload_name:w.name
      ~fact_of:(fun raw msg ->
        Printf.sprintf "has an invalid ingress host %S: %s" raw msg)
      Sol_cli_toml.hostname_of_string
      w.ingress_host
  in
  let* ingress_path =
    decode_optional
      ~release_id
      ~workload_name:w.name
      ~fact_of:(fun raw msg ->
        Printf.sprintf "has an invalid ingress path %S: %s" raw msg)
      Sol_cli_toml.ingress_path_of_string
      w.ingress_path
  in
  let* calls = decode_calls ~release_id ~workload_name:w.name w.calls in
  let* availability =
    Sol_cli_availability.of_string w.availability
    |> Result.map_error (fun msg ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Printf.sprintf "has an invalid availability %S: %s" w.availability msg))
  in
  let spec =
    { Sol_cli_deployment_plan.domain = w.domain
    ; source_name = w.name
    ; k8s_name
    ; namespace
    ; primitive
    ; source_dir = ""
    ; image = w.image
    ; config = w.config
    ; secrets = w.secrets
    ; uses = w.uses
    ; secret_sources =
        w.external_secret_refs
        |> List.map (fun (key, store, remote_key) ->
          key, Sol_cli_manifest.External { store; key = remote_key })
    ; build_secret_keys = []
    ; volumes
    ; schedule = w.schedule
    ; scheduled_concurrency
    ; backoff_limit = w.backoff_limit
    ; replicas = w.replicas
    ; language = None
    ; availability
    ; consumes_kafka = w.consumes_kafka
    ; cpu
    ; memory
    ; rollout_strategy
    ; ingress_host
    ; ingress_path
    ; cluster_issuer = w.cluster_issuer
    ; calls
    ; called_by = []
    ; extra_labels = w.extra_labels
    ; progressive_delivery
    ; (* Historical requirements are decoded here. Current database ownership and
         trust are resolved once by [service_specs_of_release] below. *)
      database = Sol_cli_resource_binding.No_postgres_use
    }
  in
  let* () =
    Sol_cli_deployment_plan.validate_persistence spec
    |> Result.map_error (fun err ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Sol_cli_deployment_plan.plan_error_to_string err))
  in
  let* () =
    Sol_cli_deployment_plan.validate_availability spec
    |> Result.map_error (fun err ->
      reconstruct_error
        ~release_id
        ~workload:w.name
        ~fact:(Sol_cli_deployment_plan.plan_error_to_string err))
  in
  Ok spec
;;

let with_called_by (specs : Sol_cli_deployment_plan.service_spec list) =
  specs
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    let called_by =
      specs
      |> List.filter_map (fun (caller : Sol_cli_deployment_plan.service_spec) ->
        if
          List.exists
            (fun (c : Sol_cli_deployment_plan.service_call) ->
               Sol_cli_kubernetes_name.namespace_to_string c.target_namespace
               = Sol_cli_kubernetes_name.namespace_to_string spec.namespace
               && Sol_cli_kubernetes_name.k8s_name_to_string c.target_name
                  = Sol_cli_kubernetes_name.k8s_name_to_string spec.k8s_name)
            caller.calls
        then
          Some
            { Sol_cli_deployment_plan.env_var =
                Sol_cli_kubernetes_name.call_env_var caller.source_name
            ; unit_id =
                caller.domain
                ^ "/"
                ^ Sol_cli_kubernetes_name.k8s_name_to_string caller.k8s_name
            ; url =
                Sol_cli_kubernetes_name.service_url
                  ~namespace:caller.namespace
                  ~k8s_name:caller.k8s_name
            ; target_domain = caller.domain
            ; target_name = caller.k8s_name
            ; target_namespace = caller.namespace
            }
        else None)
    in
    { spec with called_by })
;;

(* Historical dependency names must still have current authorities. This checks
   availability, not today's service declarations: the release owns the uses edges. *)
let validate_resource_requirements
      ~(config : Sol_cli_config.t)
      (release : Sol_cli_release.t)
  =
  let available =
    Sol_cli_config.resources config
    |> List.map (fun (r : Sol_cli_config.resource) -> r.name)
  in
  let* required =
    release.workloads
    |> List.concat_map (fun (w : Sol_cli_release.recorded_workload) -> w.spec.uses)
    |> Sol_cli_result.map_list (fun reference ->
      match Sol_cli_resource_binding.resource_name_of_ref reference with
      | Some resource -> Ok resource
      | None ->
        Error
          (Printf.sprintf
             "cannot restore release %s: invalid resource requirement %S"
             release.release_id
             reference))
  in
  let missing =
    required
    |> List.filter (fun resource -> not (List.mem resource available))
    |> List.sort_uniq String.compare
  in
  match missing with
  | [] -> Ok ()
  | _ ->
    Error
      (Printf.sprintf
         "cannot restore release %s: target %s no longer provides its required resources \
          (%s)"
         release.release_id
         config.target.name
         (String.concat ", " missing))
;;

let service_specs_of_release ?database ?kafka (release : Sol_cli_release.t) =
  (* A rollback restores the release's **recorded** requirements against the **current** target's
     authorities and bindings. The release answers "what did this version require?"; the target
     answers "where does that credential come from today?". Neither is asked the other's question,
     which is the conflation this prevents (#1422).

     The caller resolves the selection before acquiring mutation authority. This
     projection accepts that selection, so migration reads, class delivery and
     restored workloads never re-interpret the current configuration. *)
  let database_targets =
    match database with
    | None -> fun _ -> Sol_cli_resource_binding.No_postgres_use
    | Some (target, database) ->
      Sol_cli_deployment_plan.database_for_uses ~target:(Some target) ~database
  in
  (* The recorded workload says whether it required Kafka and what it required it
     for. The current target says which connection/authority supplies that today.
     A recorded consumer whose target no longer resolves Kafka fails closed rather
     than silently restoring stale endpoint metadata. *)
  let kafka_env_keys =
    Sol_cli_manifest.kafka_connection_env Sol_cli_manifest.Sasl_ssl |> List.map fst
  in
  let restore_kafka (w : Sol_cli_release.recorded_workload) spec =
    match kafka with
    | None -> Ok spec
    | Some (target, kafka) ->
      if
        spec.Sol_cli_deployment_plan.consumes_kafka
        && kafka = Sol_cli_resource_binding.No_kafka
      then
        Error
          (Printf.sprintf
             "cannot restore release %s: workload %s/%s required Kafka, but the current \
              target has no resolved Kafka binding"
             release.release_id
             w.spec.domain
             w.spec.name)
      else (
        let config =
          List.filter
            (fun (key, _) -> not (List.mem key kafka_env_keys))
            spec.Sol_cli_deployment_plan.config
          @
          if spec.Sol_cli_deployment_plan.consumes_kafka
          then Sol_cli_resource_binding.kafka_config kafka
          else []
        in
        let kafka_keys =
          Sol_cli_manifest.kafka_required_secret_keys Sol_cli_manifest.Sasl_ssl
        in
        let kafka_sources =
          if spec.Sol_cli_deployment_plan.consumes_kafka
          then Sol_cli_resource_binding.kafka_secret_sources ~target kafka
          else []
        in
        let secret_sources =
          List.filter
            (fun (key, _) -> not (List.mem key kafka_keys))
            spec.Sol_cli_deployment_plan.secret_sources
          @ kafka_sources
        in
        Ok { spec with Sol_cli_deployment_plan.config; secret_sources })
  in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | (w : Sol_cli_release.recorded_workload) :: rest ->
      let* spec =
        decode_workload
          ~release_id:w.Sol_cli_release_id.applied_by
          ~workspace:release.workspace
          w.spec
      in
      (* The requirement is the *record's*; the resolution is the current target's. *)
      let database = database_targets w.spec.uses in
      let* spec = restore_kafka w { spec with database } in
      go (spec :: acc) rest
  in
  let* specs = go [] release.workloads in
  let specs = with_called_by specs in
  (* The identity each workload's objects carry is derived from its own effective spec
     (see [Sol_cli_deployment_plan.workload_release_id]), not from the recorded deploy
     id, so a restored workload's [release] label matches what the deploy that applied
     this boundary rendered, while a deploy that only changed an unrelated workload did
     not re-label it. *)
  let identity spec =
    Sol_cli_release_id.to_string
      (Sol_cli_deployment_plan.workload_release_id
         ~workspace:release.workspace
         ~environment:release.environment
         spec)
  in
  Ok (List.map (fun spec -> spec, identity spec) specs)
;;

type migration_check_error =
  | Contracting_migration of
      { release_id : string
      ; migration : string
      }
  | Undeclared_disposition of
      { release_id : string
      ; migration : string
      ; reason : string
      }
  | Applied_migration_absent of
      { release_id : string
      ; version : int
      }
  | Applied_state_unavailable of
      { release_id : string
      ; reason : string
      }

let migration_check_error_to_string = function
  | Contracting_migration { release_id; migration } ->
    Printf.sprintf
      "cannot roll back to release %s: %s is a contracting migration applied since that \
       release -- restoring %s could run its old application code against a schema it no \
       longer supports. No override: resolve the incompatibility forward instead."
      release_id
      migration
      release_id
  | Undeclared_disposition { release_id; migration; reason } ->
    Printf.sprintf
      "cannot roll back to release %s: migration %s %s -- declare a sol:disposition \
       before rolling back across it."
      release_id
      migration
      reason
  | Applied_migration_absent { release_id; version } ->
    Printf.sprintf
      "cannot roll back to release %s: the target has migration version %d applied, and \
       this checkout has no file for it, so its disposition cannot be checked. An absent \
       file is not evidence that the schema did not change -- run the rollback from the \
       checkout that contains it, or resolve the incompatibility forward."
      release_id
      version
  | Applied_state_unavailable { release_id; reason } ->
    Printf.sprintf
      "cannot roll back to release %s: the target's applied migration state could not be \
       compared (%s). Failing closed rather than assuming the schema is unchanged."
      release_id
      reason
;;

let release_migration_versions ~release =
  let open Result.Syntax in
  List.fold_left
    (fun acc migration ->
       let* versions = acc in
       match Sol_cli_migration.parse_version migration with
       | Some (version, _) -> Ok (version :: versions)
       | None ->
         Error
           (Applied_state_unavailable
              { release_id = release.Sol_cli_release.release_id
              ; reason =
                  Printf.sprintf
                    "its recorded migration %S cannot be interpreted, so the boundary \
                     between its schema and the target's cannot be established"
                    migration
              }))
    (Ok [])
    release.Sol_cli_release.migrations
;;

let check_migration_boundary
      ~(release : Sol_cli_release.t)
      ~(migrations_dir : string)
      ~(current_migrations : string list)
      ~(applied : unit -> (int list, string) result)
  : (unit, migration_check_error) result
  =
  let open Result.Syntax in
  let* release_versions = release_migration_versions ~release in
  let local =
    List.filter_map
      (fun file ->
         Option.map
           (fun (version, _) -> version, file)
           (Sol_cli_migration.parse_version file))
      current_migrations
  in
  let local_beyond =
    List.filter (fun (version, _) -> not (List.mem version release_versions)) local
  in
  let rec go = function
    | [] -> Ok ()
    | migration :: rest ->
      (match
         Sol_cli_migration_disposition.read_file
           ~path:(Filename.concat migrations_dir migration)
       with
       | Error reason ->
         Error
           (Undeclared_disposition { release_id = release.release_id; migration; reason })
       | Ok Sol_cli_migration_disposition.Contract ->
         Error (Contracting_migration { release_id = release.release_id; migration })
       | Ok Sol_cli_migration_disposition.Expand -> go rest)
  in
  let* () = go (local_beyond |> List.map snd |> List.sort String.compare) in
  let* applied =
    applied ()
    |> Result.map_error (fun reason ->
      Applied_state_unavailable { release_id = release.release_id; reason })
  in
  let applied_beyond =
    applied
    |> List.filter (fun version -> not (List.mem version release_versions))
    |> List.sort_uniq compare
  in
  match
    List.filter
      (fun version ->
         not
           (List.exists (fun (local_version, _) -> local_version = version) local_beyond))
      applied_beyond
  with
  | [] -> Ok ()
  | version :: _ ->
    Error (Applied_migration_absent { release_id = release.release_id; version })
;;

type apply_mode_check_error = Gitops_owned of { release_id : string }

let apply_mode_check_error_to_string = function
  | Gitops_owned { release_id } ->
    Printf.sprintf
      "cannot roll back to release %s: it was applied as a GitOps/controller-owned \
       release, so Sol does not own the target resources. A direct apply + immediate \
       readback would not establish a stable transition. Roll it back through the GitOps \
       pipeline instead."
      release_id
;;

let check_apply_mode ~(release : Sol_cli_release.t)
  : (unit, apply_mode_check_error) result
  =
  match release.apply_mode with
  | Sol_cli_release.Direct -> Ok ()
  | Sol_cli_release.Gitops -> Error (Gitops_owned { release_id = release.release_id })
;;

type live_kind =
  | Live_deployment
  | Live_rollout
  | Live_cronjob

let live_kind_path = function
  | Live_deployment -> "deployment", [ "spec"; "template"; "metadata"; "labels" ]
  | Live_rollout -> "rollout", [ "spec"; "template"; "metadata"; "labels" ]
  | Live_cronjob ->
    "cronjob", [ "spec"; "jobTemplate"; "spec"; "template"; "metadata"; "labels" ]
;;

let live_resource_and_jsonpath kind =
  let resource, path = live_kind_path kind in
  resource, "{." ^ String.concat "." path ^ ".release}"
;;

let live_kind_of_service (s : Sol_cli_deployment_plan.service_spec) =
  match s.primitive with
  | Sol_cli_deployment_plan.Fn -> Live_cronjob
  | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
    (match s.progressive_delivery with
     | Some _ -> Live_rollout
     | None -> Live_deployment)
;;

let read_jsonpath ~ctx ~resource ~name ~namespace ~jsonpath =
  match
    Sol_cli_kubectl.get ~ctx ~resource ~name ~namespace ~output:("jsonpath=" ^ jsonpath)
  with
  | Ok r -> Ok (String.trim r.stdout)
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

type workload_identity =
  { kind : live_kind
  ; namespace : string
  ; name : string
  }

let same_identity a b =
  a.kind = b.kind && String.equal a.namespace b.namespace && String.equal a.name b.name
;;

let identity_of_spec (spec : Sol_cli_deployment_plan.service_spec) : workload_identity =
  { kind = live_kind_of_service spec
  ; namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace
  ; name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name
  }
;;

let string_at path json =
  Sol_cli_json.field path json |> Sol_cli_json.string |> Option.value ~default:""
;;

let pod_template_labels kind item =
  match Sol_cli_json.field (snd (live_kind_path kind)) item with
  | `Assoc kvs ->
    kvs
    |> List.filter_map (fun (k, v) ->
      match v with
      | `String s -> Some (k, s)
      | _ -> None)
  | _ -> []
;;

let workload_rows_of_payload ~kind ~workspace (payload : Yojson.Safe.t) =
  let wanted = Sol_cli_kubernetes_name.sanitize_label_value workspace in
  Sol_cli_json.require ~what:"kubectl get output" [ "items" ] Sol_cli_json.list payload
  |> Result.map
     @@ List.filter_map (fun item ->
       let labels = pod_template_labels kind item in
       match List.assoc_opt "workspace" labels with
       | Some w when String.equal w wanted ->
         let identity =
           { kind
           ; namespace = string_at [ "metadata"; "namespace" ] item
           ; name = string_at [ "metadata"; "name" ] item
           }
         in
         Some (identity, Option.value (List.assoc_opt "release" labels) ~default:"")
       | _ -> None)
;;

(** The namespaces a plan deploys into — part of what a live-workload observation is scoped
    to. *)
let namespaces_of_plan (plan : Sol_cli_deployment_plan.t) =
  plan.Sol_cli_deployment_plan.services
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Sol_cli_deployment_plan.namespace_to_string spec.namespace)
  |> List.sort_uniq String.compare
;;

(** The namespaces the recorded apply wrote into.

    Pruning has to observe these as well as the plan's: a workload the plan *no longer
    declares* is surplus precisely because it is absent from the plan, so its namespace may
    be absent from the plan too. Observing only the plan's namespaces would stop finding it.
    *)
let namespaces_of_evidence (evidence : Sol_cli_release_id.owned_object list) =
  evidence
  |> List.map (fun (owned : Sol_cli_release_id.owned_object) -> owned.namespace)
  |> List.sort_uniq String.compare
;;

(** Observe the workspace's live workloads **in the namespaces this deploy resolved**.

    The observation is deliberately per-namespace. The target's deploy identity is
    namespace-scoped by design (ADR 0002, SEC-011) — the same boundary the deploy asserts —
    so a cluster-scoped list (`-A`) is forbidden for it and fails the whole deploy *after*
    its workloads were applied, which is both a false failure and an unbounded one. *)
let live_workloads
      ~(ctx : Sol_cli_kube_destination.context)
      ~(workspace : string)
      ~(namespaces : string list)
  : ((workload_identity * string) list, string) result
  =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | kind :: rest ->
      let resource, _ = live_kind_path kind in
      let open Result.Syntax in
      let* rows =
        Sol_cli_result.map_list
          (fun namespace ->
             match
               Sol_cli_kubectl.get_raw
                 ~ctx
                 ~args:[ "get"; resource; "-n"; namespace; "-o"; "json" ]
             with
             | Ok r ->
               Sol_cli_json.decode
                 ~what:(Printf.sprintf "kubectl get %s output" resource)
                 r.stdout
               |> Fun.flip Result.bind (workload_rows_of_payload ~kind ~workspace)
             | Error e
               when kind = Live_rollout && Sol_cli_kubectl.classify e = No_resource_type
               -> Ok []
             | Error e ->
               Error
                 (Printf.sprintf
                    "kubectl get %s failed: %s"
                    resource
                    (Sol_cli_process.error_to_string e)))
          namespaces
      in
      go (List.rev_append (List.concat rows) acc) rest
  in
  go [] [ Live_deployment; Live_rollout; Live_cronjob ]
;;

(* A workspace live workload with the UID needed to decide ownership. The pod-template
   workspace label only selects what to look at; it is never ownership evidence. *)
type live_object =
  { id : Sol_cli_workload_ownership.identity
  ; uid : string
  }

(* The workspace's live workloads, and the resources Sol could not list. An unserved
   kind has no objects of that kind, so it observes nothing rather than failing; any
   other failure is named, so a caller reports it instead of an empty result. *)
type workspace_listing =
  { objects : live_object list
  ; unobservable : (string * string) list
  }

let live_object_of_item ~kind ~resource ~workspace item =
  let wanted = Sol_cli_kubernetes_name.sanitize_label_value workspace in
  let labels = pod_template_labels kind item in
  match List.assoc_opt "workspace" labels with
  | Some w when String.equal w wanted ->
    let uid = string_at [ "metadata"; "uid" ] item in
    if String.equal uid ""
    then None
    else
      Some
        { id =
            { Sol_cli_workload_ownership.resource
            ; namespace = string_at [ "metadata"; "namespace" ] item
            ; name = string_at [ "metadata"; "name" ] item
            }
        ; uid
        }
  | _ -> None
;;

let observe_workspace_workloads
      ~(ctx : Sol_cli_kube_destination.context)
      ~(workspace : string)
  : workspace_listing
  =
  let rec go objects unobservable = function
    | [] -> { objects = List.rev objects; unobservable = List.rev unobservable }
    | kind :: rest ->
      let resource, _ = live_kind_path kind in
      (match
         Sol_cli_kubectl.get_raw ~ctx ~args:[ "get"; resource; "-A"; "-o"; "json" ]
       with
       | Ok r ->
         (match
            Sol_cli_json.decode
              ~what:(Printf.sprintf "kubectl get %s output" resource)
              r.stdout
          with
          | Error reason -> go objects ((resource, reason) :: unobservable) rest
          | Ok payload ->
            let items =
              match Sol_cli_json.field [ "items" ] payload with
              | `List items -> items
              | _ -> []
            in
            let rows =
              List.filter_map (live_object_of_item ~kind ~resource ~workspace) items
            in
            go (List.rev_append rows objects) unobservable rest)
       | Error e ->
         (match Sol_cli_kubectl.classify e with
          | Sol_cli_kubectl.No_resource_type -> go objects unobservable rest
          | _ ->
            go
              objects
              ((resource, Sol_cli_process.error_to_string e) :: unobservable)
              rest))
  in
  go [] [] [ Live_deployment; Live_rollout; Live_cronjob ]
;;

type workload_mismatch =
  { kind : live_kind
  ; namespace : string
  ; name : string
  ; actual : string
  }

type workload_report =
  { mismatched : workload_mismatch list
  ; missing : workload_identity list
  ; unexpected : (workload_identity * string) list
  }

let workload_report_ok (r : workload_report) =
  r.mismatched = [] && r.missing = [] && r.unexpected = []
;;

let unexpected_workloads
      ~(expected : Sol_cli_deployment_plan.service_spec list)
      ~(live : (workload_identity * string) list)
  =
  let expected_ids = List.map identity_of_spec expected in
  List.filter (fun (id, _) -> not (List.exists (same_identity id) expected_ids)) live
;;

let verify_workloads
      ~(expected : (Sol_cli_deployment_plan.service_spec * string) list)
      ~(live : (workload_identity * string) list)
  : workload_report
  =
  let mismatched, missing =
    List.fold_left
      (fun (mismatched, missing) (spec, applied_by) ->
         let id = identity_of_spec spec in
         match List.find_opt (fun (i, _) -> same_identity i id) live with
         | None -> mismatched, id :: missing
         | Some (_, actual) ->
           if String.equal actual applied_by
           then mismatched, missing
           else
             ( { kind = id.kind; namespace = id.namespace; name = id.name; actual }
               :: mismatched
             , missing ))
      ([], [])
      expected
  in
  { mismatched = List.rev mismatched
  ; missing = List.rev missing
  ; unexpected = unexpected_workloads ~expected:(List.map fst expected) ~live
  }
;;

let display_actual actual = if String.equal actual "" then "<none>" else actual
let kind_resource kind = fst (live_kind_path kind)

(* The ExternalSecret Sol renders for a unit that declares at least one external key. Its
   UID is recorded with its workload's, so an orphan can be removed under the same positive
   ownership discipline. *)
let external_secret_of_spec (spec : Sol_cli_deployment_plan.service_spec) =
  Sol_cli_deployment_plan.external_secret_of_spec spec
  |> Option.map (fun (namespace, name) ->
    { Sol_cli_workload_ownership.resource = "externalsecret"; namespace; name })
;;

let declared_external_secrets (plan : Sol_cli_deployment_plan.t) =
  plan.services |> List.filter_map external_secret_of_spec
;;

(* A read that fails records no evidence for that object rather than failing the deploy;
   the absence fails closed at removal, not here. *)
let capture_uid ~ctx ~resource ~namespace ~name =
  match read_jsonpath ~ctx ~resource ~name ~namespace ~jsonpath:"{.metadata.uid}" with
  | Ok uid when not (String.equal uid "") ->
    [ { Sol_cli_release_id.resource; namespace; name; uid } ]
  | Ok _ | Error _ -> []
;;

(* Capture the live `metadata.uid` of each object this apply created, so a later removal
   can require positive ownership evidence: the live object's UID must equal the UID
   recorded here (docs/architecture/ownership.md). A workload's ExternalSecret is captured
   with it (external_secret_of_spec). *)
let capture_owned
      ~(ctx : Sol_cli_kube_destination.context)
      (plan : Sol_cli_deployment_plan.t)
  : Sol_cli_release_id.owned_object list
  =
  plan.services
  |> List.concat_map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    let id = identity_of_spec spec in
    let workload =
      capture_uid
        ~ctx
        ~resource:(kind_resource id.kind)
        ~namespace:id.namespace
        ~name:id.name
    in
    let external_secret =
      match external_secret_of_spec spec with
      | None -> []
      | Some id ->
        capture_uid ~ctx ~resource:id.resource ~namespace:id.namespace ~name:id.name
    in
    workload @ external_secret)
;;

let live_kind_volumes_path = function
  | Live_deployment | Live_rollout -> [ "spec"; "template"; "spec"; "volumes" ]
  | Live_cronjob -> [ "spec"; "jobTemplate"; "spec"; "template"; "spec"; "volumes" ]
;;

type prune_target =
  { resource : string
  ; namespace : string
  ; name : string
  }

(* Why Sol will not remove a surplus workload it looked at. Only [Live_unobservable]
   means Sol does not know whether the recorded object is still live, so a caller
   reconciling removals must not advance past it; the others mean the recorded object is
   gone, absent, or was never Sol's, so nothing is left to authorize. *)
type unowned_reason =
  | No_recorded_uid
  | Live_uid_differs
  | Live_absent
  | Live_unobservable of string

(* A surplus workload Sol will not remove because it cannot prove it owns it. *)
type unowned_workload =
  { identity : workload_identity
  ; reason : unowned_reason
  }

let unowned_reason_to_string = function
  | No_recorded_uid -> "Sol recorded no UID for it"
  | Live_uid_differs -> "its live UID differs from the UID Sol recorded"
  | Live_absent -> "it is no longer present"
  | Live_unobservable reason -> reason
;;

type prune_report =
  { removed : prune_target list
  ; retained : prune_target list (* storage of a removed workload (DEC-033) *)
  ; unowned : unowned_workload list
  }

let named_target (id : workload_identity) resource name =
  { resource; namespace = id.namespace; name }
;;

let ownership_identity (id : workload_identity) : Sol_cli_workload_ownership.identity =
  { Sol_cli_workload_ownership.resource = kind_resource id.kind
  ; namespace = id.namespace
  ; name = id.name
  }
;;

let auxiliary_targets ~live_names (id : workload_identity) =
  let named resource name = named_target id resource name in
  let base =
    [ named "serviceaccount" id.name
    ; named "configmap" (id.name ^ "-env")
    ; named "networkpolicy" id.name
    ; named "service" id.name
    ; named "ingress" id.name
    ; named "poddisruptionbudget" id.name
    ]
  in
  let progressive =
    match id.kind with
    | Live_deployment | Live_cronjob -> []
    | Live_rollout ->
      let occupied suffix = List.exists (String.equal (id.name ^ suffix)) live_names in
      [ "-active", named "service" (id.name ^ "-active")
      ; "-preview", named "service" (id.name ^ "-preview")
      ; "-active", named "ingress" (id.name ^ "-active")
      ]
      |> List.filter_map (fun (suffix, target) ->
        if occupied suffix then None else Some target)
  in
  base @ progressive
;;

(* The objects a removal targets for one surplus workload: the workload itself and the
   auxiliaries it realizes. An auxiliary follows the owning workload's UID match; it has
   no recorded UID of its own (docs/architecture/ownership.md). *)
let prune_targets_of_workload ~live_names (id : workload_identity) =
  named_target id (kind_resource id.kind) id.name :: auxiliary_targets ~live_names id
;;

let plan_prune ~removable ~unowned ~live_names ~claims : prune_report =
  let removed = removable |> List.concat_map (prune_targets_of_workload ~live_names) in
  let retained =
    removable
    |> List.concat_map (fun id ->
      claims id |> List.map (named_target id "persistentvolumeclaim"))
  in
  { removed; retained; unowned }
;;

let claim_names_of_json kind json =
  match Sol_cli_json.field (live_kind_volumes_path kind) json with
  | `List volumes ->
    volumes
    |> List.filter_map (fun volume ->
      Sol_cli_json.field [ "persistentVolumeClaim"; "claimName" ] volume
      |> Sol_cli_json.string)
  | _ -> []
;;

let live_claim_names ~ctx (id : workload_identity) =
  match
    Sol_cli_kubectl.get
      ~ctx
      ~resource:(kind_resource id.kind)
      ~name:id.name
      ~namespace:id.namespace
      ~output:"json"
  with
  | Error e ->
    Sol_cli_report.warn
      "could not read %s %s/%s to enumerate the volumes it owned (%s); any \
       PersistentVolumeClaim it created is retained but cannot be listed."
      (kind_resource id.kind)
      id.namespace
      id.name
      (Sol_cli_process.error_to_string e);
    []
  | Ok output ->
    (match Sol_cli_json.decode ~what:"live workload" output.Sol_cli_process.stdout with
     | Error msg ->
       Sol_cli_report.warn
         "could not read %s %s/%s to enumerate the volumes it owned (%s); any \
          PersistentVolumeClaim it created is retained but cannot be listed."
         (kind_resource id.kind)
         id.namespace
         id.name
         msg;
       []
     | Ok json -> claim_names_of_json id.kind json)
;;

let delete_target ~ctx (t : prune_target) =
  match
    Sol_cli_kubectl.delete ~ctx ~resource:t.resource ~name:t.name ~namespace:t.namespace
  with
  | Ok () -> None
  | Error e ->
    Some
      (Printf.sprintf
         "%s %s/%s: %s"
         t.resource
         t.namespace
         t.name
         (Sol_cli_process.error_to_string e))
;;

(* Remove a surplus workload only while its live UID is exactly the UID recorded when
   Sol applied it; a different UID, no recorded UID, an absent object or an unobservable
   one is retained and reported. Auxiliaries follow the owning workload's match
   (docs/architecture/ownership.md). The UID is read at removal time, not from an earlier
   listing, so a recreate between the listing and the delete is not authorized. *)
let prune_workloads
      ~(ctx : Sol_cli_kube_destination.context)
      ~(evidence : Sol_cli_release_id.owned_object list)
      ~live
      ~surplus
  : (prune_report, string) result
  =
  let live_names = List.map (fun ((id : workload_identity), _) -> id.name) live in
  let classify (id : workload_identity) : (workload_identity, unowned_reason) result =
    let ownership = ownership_identity id in
    let recorded = Sol_cli_workload_ownership.recorded_uid evidence ownership in
    match Sol_cli_workload_ownership.observe ~ctx ownership with
    | Sol_cli_workload_ownership.Live_present uid ->
      if Sol_cli_workload_ownership.owns ~recorded ~live_uid:uid
      then Ok id
      else
        Error
          (match recorded with
           | None -> No_recorded_uid
           | Some _ -> Live_uid_differs)
    | Sol_cli_workload_ownership.Live_absent -> Error Live_absent
    | Sol_cli_workload_ownership.Live_unobservable reason ->
      Error (Live_unobservable reason)
  in
  let removable, unowned =
    List.fold_left
      (fun (removable, unowned) ((id : workload_identity), _) ->
         match classify id with
         | Ok id -> id :: removable, unowned
         | Error reason -> removable, { identity = id; reason } :: unowned)
      ([], [])
      surplus
  in
  let report =
    plan_prune
      ~removable:(List.rev removable)
      ~unowned:(List.rev unowned)
      ~live_names
      ~claims:(live_claim_names ~ctx)
  in
  match List.filter_map (delete_target ~ctx) report.removed with
  | [] -> Ok report
  | errors ->
    Error
      (Printf.sprintf
         "could not prune %d surplus object(s):\n%s"
         (List.length errors)
         (String.concat "\n" errors))
;;

(* Recorded ExternalSecrets the plan no longer declares: the workload may be live (its last
   external key was removed) or gone entirely, and neither is declared, so both are orphans.
   This is the trigger the surplus-workload path cannot express, because a live workload is
   not surplus. *)
let orphaned_external_secret_evidence
      ~(evidence : Sol_cli_release_id.owned_object list)
      ~(declared : Sol_cli_workload_ownership.identity list)
  =
  evidence
  |> List.filter (fun (o : Sol_cli_release_id.owned_object) ->
    String.equal o.resource "externalsecret"
    && not
         (List.exists
            (fun (id : Sol_cli_workload_ownership.identity) ->
               String.equal id.namespace o.namespace && String.equal id.name o.name)
            declared))
;;

type external_secret_prune_report =
  { removed_external_secrets : prune_target list
  ; unowned_external_secrets : (prune_target * unowned_reason) list
  }

(* Remove a recorded ExternalSecret only while its live UID is exactly the UID recorded at
   apply; a different UID, an absent object, or an unobservable one is retained and
   reported. The UID is read at removal time, not from an earlier listing. *)
let prune_external_secrets
      ~(ctx : Sol_cli_kube_destination.context)
      ~(evidence : Sol_cli_release_id.owned_object list)
      ~(declared : Sol_cli_workload_ownership.identity list)
  : (external_secret_prune_report, string) result
  =
  let classify (o : Sol_cli_release_id.owned_object) =
    let ownership =
      { Sol_cli_workload_ownership.resource = o.resource
      ; namespace = o.namespace
      ; name = o.name
      }
    in
    let target = { resource = o.resource; namespace = o.namespace; name = o.name } in
    match Sol_cli_workload_ownership.observe ~ctx ownership with
    | Sol_cli_workload_ownership.Live_present uid ->
      if Sol_cli_workload_ownership.owns ~recorded:(Some o.uid) ~live_uid:uid
      then Ok target
      else Error Live_uid_differs
    | Sol_cli_workload_ownership.Live_absent -> Error Live_absent
    | Sol_cli_workload_ownership.Live_unobservable reason ->
      Error (Live_unobservable reason)
  in
  let removed, unowned =
    List.fold_left
      (fun (removed, unowned) o ->
         match classify o with
         | Ok target -> target :: removed, unowned
         | Error reason ->
           ( removed
           , ({ resource = o.resource; namespace = o.namespace; name = o.name }, reason)
             :: unowned ))
      ([], [])
      (orphaned_external_secret_evidence ~evidence ~declared)
  in
  let report =
    { removed_external_secrets = List.rev removed
    ; unowned_external_secrets = List.rev unowned
    }
  in
  match List.filter_map (delete_target ~ctx) report.removed_external_secrets with
  | [] -> Ok report
  | errors ->
    Error
      (Printf.sprintf
         "could not prune %d orphaned ExternalSecret(s):\n%s"
         (List.length errors)
         (String.concat "\n" errors))
;;

let unowned_message (unowned : unowned_workload list) =
  Printf.sprintf
    "rollback retained %d surplus workload(s) it cannot prove it owns (no recorded UID \
     match):\n\
     %s\n\
     Sol removes a workload only while its live UID equals the UID recorded at apply. \
     Adopt or remove these by hand."
    (List.length unowned)
    (String.concat
       "\n"
       (List.map
          (fun (u : unowned_workload) ->
             Printf.sprintf
               "  %s %s/%s (%s)"
               (kind_resource u.identity.kind)
               u.identity.namespace
               u.identity.name
               (unowned_reason_to_string u.reason))
          unowned))
;;

let retained_message ~(release : Sol_cli_release.t) retained =
  Printf.sprintf
    "rollback retained %d object(s) it does not delete:\n\
     %s\n\
     Storage lifetime is not rollback's decision (DEC-033). The workloads and the \
     pointer name release %s, but these objects were deliberately left in place."
    (List.length retained)
    (String.concat
       "\n"
       (List.map
          (fun (t : prune_target) ->
             Printf.sprintf "  %s %s/%s" t.resource t.namespace t.name)
          retained))
    release.release_id
;;

let workload_report_to_string ~(release : Sol_cli_release.t) (r : workload_report)
  : string
  =
  let mismatch_lines =
    r.mismatched
    |> List.map (fun (m : workload_mismatch) ->
      Printf.sprintf
        "workload state mismatch: %s %s/%s carries release %s, expected %s"
        (kind_resource m.kind)
        m.namespace
        m.name
        (display_actual m.actual)
        release.release_id)
  in
  let missing_lines =
    r.missing
    |> List.map (fun (i : workload_identity) ->
      Printf.sprintf
        "workload missing: %s %s/%s is not present in the cluster"
        (kind_resource i.kind)
        i.namespace
        i.name)
  in
  let unexpected_lines =
    r.unexpected
    |> List.map (fun ((i : workload_identity), actual) ->
      Printf.sprintf
        "unexpected workload: %s %s/%s carries release %s but is not part of release %s"
        (kind_resource i.kind)
        i.namespace
        i.name
        (display_actual actual)
        release.release_id)
  in
  String.concat "\n" (mismatch_lines @ missing_lines @ unexpected_lines)
;;

type pointer_report =
  | Pointer_confirmed
  | Pointer_names of string
  | Pointer_unreadable of string

let verify_pointer
      ~(ctx : Sol_cli_kube_destination.context)
      ~(release : Sol_cli_release.t)
  : pointer_report
  =
  match
    read_jsonpath
      ~ctx
      ~resource:"configmap"
      ~name:(Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      ~namespace:"default"
      ~jsonpath:"{.data.release_id}"
  with
  | Error reason -> Pointer_unreadable reason
  | Ok actual ->
    if String.equal actual release.release_id
    then Pointer_confirmed
    else Pointer_names actual
;;

let pointer_report_ok = function
  | Pointer_confirmed -> true
  | Pointer_names _ | Pointer_unreadable _ -> false
;;

let pointer_report_to_string ~(release : Sol_cli_release.t) = function
  | Pointer_confirmed ->
    Printf.sprintf
      "pointer verified: %s names %s"
      (Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      release.release_id
  | Pointer_names actual ->
    Printf.sprintf
      "pointer mismatch: %s names %s, expected %s"
      (Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      (display_actual actual)
      release.release_id
  | Pointer_unreadable reason ->
    Printf.sprintf
      "pointer unreadable: %s could not be read, so the release it names is unknown \
       (%s); expected %s"
      (Sol_cli_release.current_configmap_name ~workspace:release.workspace)
      reason
      release.release_id
;;

type transaction_deps =
  { ensure_held : unit -> (unit, string) result
  ; applied_migrations : unit -> (int list, string) result
  ; apply : (Sol_cli_deployment_plan.service_spec * string) list -> (unit, string) result
  ; live_workloads : unit -> ((workload_identity * string) list, string) result
  ; prune :
      live:(workload_identity * string) list
      -> surplus:(workload_identity * string) list
      -> (prune_report, string) result
  ; move_pointer : unit -> (unit, string) result
  ; verify_pointer : unit -> pointer_report
  ; record_consumer_groups : string list -> (unit, string) result
  }

let consumer_groups_of_release (release : Sol_cli_release.t) =
  release.workloads
  |> List.filter_map (fun (recorded : Sol_cli_release_id.recorded_workload) ->
    let workload = recorded.spec in
    if String.equal workload.primitive "worker" && workload.consumes_kafka
    then Some (Printf.sprintf "%s.%s.%s" release.workspace workload.domain workload.name)
    else None)
  |> List.sort_uniq String.compare
;;

let execute
      ~(release : Sol_cli_release.t)
      ~specs
      ~migrations_dir
      ~current_migrations
      ~(deps : transaction_deps)
  : (unit, string) result
  =
  let* () =
    match check_apply_mode ~release with
    | Error e -> Error (apply_mode_check_error_to_string e)
    | Ok () -> Ok ()
  in
  let* () =
    match
      check_migration_boundary
        ~release
        ~migrations_dir
        ~current_migrations
        ~applied:deps.applied_migrations
    with
    | Error e -> Error (migration_check_error_to_string e)
    | Ok () -> Ok ()
  in
  let* () = deps.ensure_held () in
  let* () =
    match deps.apply specs with
    | Ok () -> Ok ()
    | Error msg ->
      Error
        (Printf.sprintf
           "%s\n\
            rollback incomplete: not every workload could be applied, so the ones that \
            were may already carry release %s while the current-release pointer still \
            names the previous release. Re-run the rollback (or redeploy) to finish, and \
            verify cluster state before relying on it."
           msg
           release.release_id)
  in
  let* prune_report =
    match deps.live_workloads () with
    | Error msg -> Error (Printf.sprintf "cannot verify rollback: %s" msg)
    | Ok live ->
      let report = verify_workloads ~expected:specs ~live in
      if report.mismatched <> [] || report.missing <> []
      then
        Error
          (Printf.sprintf
             "%s\n\
              rollback incomplete: live workloads do not match release %s; the \
              current-release pointer was left unchanged"
             (workload_report_to_string ~release report)
             release.release_id)
      else (
        match deps.ensure_held () with
        | Error msg -> Error msg
        | Ok () ->
          (match deps.prune ~live ~surplus:report.unexpected with
           | Ok prune_report -> Ok prune_report
           | Error msg ->
             Error
               (Printf.sprintf
                  "%s\n\
                   rollback incomplete: could not prune surplus workloads; the \
                   current-release pointer was left unchanged"
                  msg)))
  in
  let* () = deps.ensure_held () in
  let* () = deps.move_pointer () in
  let pointer = deps.verify_pointer () in
  if not (pointer_report_ok pointer)
  then
    Error
      (Printf.sprintf
         "%s\n\
          rollback incomplete: the pointer was moved but could not be confirmed as the \
          restored release; verify cluster state before relying on this rollback."
         (pointer_report_to_string ~release pointer))
  else (
    let groups = consumer_groups_of_release release in
    match deps.record_consumer_groups groups with
    | Ok () ->
      if prune_report.unowned <> []
      then Sol_cli_report.warn "%s" (unowned_message prune_report.unowned);
      if prune_report.retained <> []
      then Sol_cli_report.warn "%s" (retained_message ~release prune_report.retained);
      Ok ()
    | Error msg ->
      Error
        (Printf.sprintf
           "%s\n\
            rollback incomplete: the workloads and the pointer were restored, but the \
            workspace's consumer-group safety record could not be corrected, so the next \
            deploy's removal check will describe the release that was rolled back. Fix \
            access to the deploy-state ConfigMap and roll back again, or pass \
            --confirm-group-change to the next deploy."
           msg))
;;
