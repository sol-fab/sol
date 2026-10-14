type result =
  { namespace : string
  ; name : string
  ; image : string
  }

type mode =
  | Dry_run
  | Emit_to of string
  | Apply

let make_result (spec : Sol_cli_deployment_plan.service_spec) =
  { namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace
  ; name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name
  ; image = spec.image
  }
;;

(* Apply a rendered workload in the order its dependencies require: refuse to take
   over a destination Sol does not own, refuse when the Sol-managed unit keys are
   missing, create the namespace and prerequisites, wait until every declared
   external Secret has actually materialized, and only then apply the objects that
   start pods. Applying the Deployment and its ExternalSecret in one [kubectl apply]
   is what allowed a Deployment to reference a not-yet-synced external Secret. *)
let apply_workload_phased
      ?eso_timeout_s
      ~ctx
      ~(spec : Sol_cli_deployment_plan.service_spec)
      ~bundle
      ()
  =
  let open Result.Syntax in
  let* () = Sol_cli_secret.verify_external_secret_destination ~ctx spec in
  (* Reads the unit's Sol-managed Secret. On a first deploy the user has already
     created it — and the namespace it lives in — with `sol secret set`. *)
  let* () = Sol_cli_secret.verify_workload_secret ~ctx spec in
  let* () = Sol_cli_manifest.apply_bundle_namespace ~ctx bundle in
  let* () = Sol_cli_manifest.apply_bundle_prerequisites ~ctx bundle in
  let* () =
    Sol_cli_secret.verify_external_secret_ready ?timeout_s:eso_timeout_s ~ctx spec
  in
  Sol_cli_manifest.apply_bundle_workload ~ctx bundle
;;

(* A CronJob has no rollout to wait on: it is created and runs on its schedule, so
   applying it is the observable outcome. A Deployment or Argo Rollout must report a
   completed rollout, so a deploy never reports success for a workload that never came
   up. The wait is bounded below the boundary-lease TTL (300s) so the caller can
   heartbeat immediately before it and the lease cannot lapse mid-rollout. *)
let rollout_wait_s = 240

let pod_expectation (spec : Sol_cli_deployment_plan.service_spec) =
  match spec.primitive with
  | Sol_cli_deployment_plan.Fn -> Sol_cli_rollout_diagnosis.Ephemeral
  | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
    Sol_cli_rollout_diagnosis.Continuous
;;

let workload_kind (spec : Sol_cli_deployment_plan.service_spec) =
  let name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
  match spec.progressive_delivery with
  | Some _ -> "rollout/" ^ name
  | None -> "deployment/" ^ name
;;

let wait_for_workload_ready ~ctx ~(spec : Sol_cli_deployment_plan.service_spec) =
  match spec.primitive with
  | Sol_cli_deployment_plan.Fn -> Ok ()
  | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
    let namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace in
    let k8s_name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
    (match
       Sol_cli_kubectl.rollout_status_with_timeout
         ~ctx
         ~kind_name:(workload_kind spec)
         ~namespace
         ~timeout_s:rollout_wait_s
     with
     | Ok _ -> Ok ()
     | Error primary ->
       let diagnosis =
         match
           Sol_cli_rollout_diagnosis.diagnose_service_live
             ~ctx
             ~pod_expectation:(pod_expectation spec)
             ~ns:namespace
             ~service_name:spec.source_name
             ~k8s_name
             ()
         with
         | Sol_cli_rollout_diagnosis.Unhealthy d -> d
         | Sol_cli_rollout_diagnosis.Undetermined why ->
           Printf.sprintf
             "could not determine whether the rollout of %s/%s succeeded: %s"
             namespace
             k8s_name
             why
         | Sol_cli_rollout_diagnosis.Healthy ->
           Printf.sprintf
             "%s/%s did not report a successful rollout, but its current pods look \
              healthy"
             namespace
             k8s_name
       in
       Error
         (Printf.sprintf
            "rollout of %s/%s did not succeed: %s\n%s"
            namespace
            k8s_name
            (Sol_cli_process.error_to_string primary)
            diagnosis))
;;

let dispatch_rendered ~ctx ~mode spec bundle =
  let dispatched =
    match mode with
    | Dry_run ->
      Sol_cli_manifest.print_bundle bundle;
      Ok ()
    | Apply -> apply_workload_phased ~ctx ~spec ~bundle ()
    | Emit_to dir ->
      let ns =
        Sol_cli_deployment_plan.namespace_to_string spec.Sol_cli_deployment_plan.namespace
      in
      let name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
      Sol_cli_manifest.emit_to_dir dir bundle ~ns ~name |> Result.map ignore
  in
  Result.map (fun () -> make_result spec) dispatched
;;

(* Local development runs against a k3d cluster with no External Secrets Operator:
   every declared key is delivered from the unit's Sol-managed Secret (populated from
   sol/secrets.local), so force every key to Sol_managed and never wait on ESO. *)
let local_development_spec (spec : Sol_cli_deployment_plan.service_spec) =
  let key = "SOL_ALLOW_UNVERIFIED_JWT" in
  { spec with
    config = (key, "1") :: List.remove_assoc key spec.config
  ; secret_sources = []
  }
;;

let local ~ctx ~workspace ~release_id ~dry_run spec =
  let open Result.Syntax in
  let spec = local_development_spec spec in
  let* bundle = Sol_cli_deployment_render.render_spec ~workspace ~release_id spec in
  dispatch_rendered ~ctx ~mode:(if dry_run then Dry_run else Apply) spec bundle
;;

let gitops ~ctx ~workspace ~release_id ~dir spec =
  let open Result.Syntax in
  let* bundle = Sol_cli_deployment_render.render_spec ~workspace ~release_id spec in
  dispatch_rendered ~ctx ~mode:(Emit_to dir) spec bundle
;;

let write_release_bundle ~dir ~(apply_mode : Sol_cli_release.apply_mode) plan =
  let open Result.Syntax in
  let* () = Sol_cli_fs.mkdir_p dir in
  Sol_cli_release.bundle_files (Sol_cli_release.of_plan ~apply_mode plan)
  |> Sol_cli_result.map_list (fun (name, contents) ->
    Sol_cli_fs.write_atomic (Filename.concat dir name) contents)
  |> Result.map ignore
;;

(** The target's own delivery prerequisites: one class ExternalSecret per class per namespace
    that reads it, rendered from the plan's {!Sol_cli_deployment_plan.resource_delivery}. A
    direct apply delivers these in the database setup step; a GitOps emit writes them to
    their own file — named by the one definition [resource_prerequisites_file_name] — so a
    fresh external-database GitOps deployment carries the object its units read. *)
let emit_resource_prerequisites ~dir (plan : Sol_cli_deployment_plan.t) =
  match plan.Sol_cli_deployment_plan.resource_delivery with
  | None -> Ok ()
  | Some delivery ->
    let open Result.Syntax in
    let* docs = Sol_cli_database_setup_run.external_credential_docs delivery in
    let name =
      Sol_cli_database_setup_render.resource_prerequisites_file_name
        ~target:delivery.target
    in
    Sol_cli_fs.write_atomic (Filename.concat dir name) (Sol_cli_yaml.render docs)
;;

let run_plan (execution : Sol_cli_execution.context) ~mode ?before_apply plan =
  let workspace = execution.workspace in
  let env = execution.env in
  let services = plan.Sol_cli_deployment_plan.services in
  let open Result.Syntax in
  (* Each workload carries its own immutable identity, not the target-wide release
     record id, so a deploy that changes one workload does not re-label and roll out
     the others. See [Sol_cli_deployment_plan.workload_release_id]. *)
  let render spec =
    let release_id =
      Sol_cli_deployment_plan.workload_release_id
        ~workspace:plan.Sol_cli_deployment_plan.workspace
        ~environment:plan.Sol_cli_deployment_plan.environment.env
        spec
    in
    Sol_cli_deployment_render.render_spec ~workspace ?env ~release_id spec
    |> Result.map (fun bundle -> spec, bundle)
  in
  let* pairs =
    services
    |> List.fold_left
         (fun acc spec ->
            let* rendered = acc in
            let* pair = render spec in
            Ok (pair :: rendered))
         (Ok [])
    |> Result.map List.rev
  in
  let before_apply_result (spec : Sol_cli_deployment_plan.service_spec) =
    match mode with
    | Dry_run | Emit_to _ -> Ok ()
    | Apply ->
      (match before_apply with
       | None -> Ok ()
       | Some f -> f spec)
  in
  let rec execute acc = function
    | [] -> Ok (List.rev acc)
    | ((spec : Sol_cli_deployment_plan.service_spec), bundle) :: rest ->
      let* () = before_apply_result spec in
      let* result = dispatch_rendered ~ctx:execution.cluster ~mode spec bundle in
      let* () =
        match mode with
        | Apply ->
          (* Heartbeat immediately before the bounded rollout wait so the boundary
             lease (TTL 300s) cannot lapse while a workload rolls out. *)
          let* () = before_apply_result spec in
          wait_for_workload_ready ~ctx:execution.cluster ~spec
        | Dry_run | Emit_to _ -> Ok ()
      in
      execute (result :: acc) rest
  in
  let* results = execute [] pairs in
  let* () =
    match mode with
    | Emit_to dir ->
      let* () = emit_resource_prerequisites ~dir plan in
      write_release_bundle ~dir ~apply_mode:Sol_cli_release.Gitops plan
    | Dry_run | Apply -> Ok ()
  in
  Ok results
;;
