type service_execution =
  { k8s_name : Sol_cli_deployment_plan.k8s_name
  ; namespace : Sol_cli_deployment_plan.namespace
  ; push_image : string
  ; context : string
  ; dockerfile : string
  ; source_dir : string
  }

type post_deploy_summary =
  { deployed_count : int
  ; pending_migrations : int
  }

let push_registry = "localhost:5000"

let local_plan
      ~requested_scope
      ~workspace
      ~sha
      ~facts
      ~(declared : Sol_cli_config.declared)
      services
  =
  let env_target = Sol_cli_env_target.local_defaults ~image_tag:sha in
  let env = Sol_cli_env_target.to_env_config ~name:workspace env_target in
  (* 2b: local development is a target like any other, so a unit that consumes the workspace's
     postgres resource routes through the *same* signal the cloud path uses
     ([db_dml_creds_name]) and reads the *same* class Secret name, produced by the same
     function from the same target string. `sol local deploy` writes that Secret; there is no
     second "is this unit a consumer" decision anywhere. The stand-in target is the workspace
     name, so a workspace that later gains a real target path changes nothing here. *)
  let open Result.Syntax in
  let* bindings =
    Sol_cli_resource_binding.resolve_resources
      (List.filter
         (fun (resource : Sol_cli_config.resource) -> not resource.omit)
         declared.resources)
    |> Result.map_error (fun message ->
      Sol_cli_deployment_plan.Invalid_resource_binding message)
  in
  let* selection =
    Sol_cli_resource_binding.postgres bindings
    |> Result.map_error (fun message ->
      Sol_cli_deployment_plan.Invalid_resource_binding message)
  in
  let database =
    match Sol_cli_resource_binding.postgres_resource selection with
    | Some resource -> Sol_cli_resource_binding.Local_postgres resource
    | None -> Sol_cli_resource_binding.No_postgres
  in
  Sol_cli_deployment_plan.of_services_result
    ~requested_scope
    ~workspace
    ~env
    ~facts
    ~declared
    ~platform_shape:Sol_cli_profile.Local
    ~target:(Sol_cli_kubernetes_name.sanitize_name workspace)
    ~database
    services
;;

let manifest_primitive = function
  | Sol_cli_deployment_plan.Svc -> Sol_cli_manifest.Svc
  | Sol_cli_deployment_plan.Worker -> Sol_cli_manifest.Worker
  | Sol_cli_deployment_plan.Fn -> Sol_cli_manifest.Fn
;;

let pod_expectation_of_primitive primitive =
  match manifest_primitive primitive with
  | Fn -> Sol_cli_rollout_diagnosis.Ephemeral
  | Svc | Worker -> Sol_cli_rollout_diagnosis.Continuous
;;

let push_image_ref ~workspace ~sha spec =
  Sol_cli_deployment_plan.image_ref
    ~registry:push_registry
    ~workspace
    ~k8s_name:spec.Sol_cli_deployment_plan.k8s_name
    ~tag:sha
;;

let service_execution
      ~workspace
      ~ctx_dir
      ~sha
      (spec : Sol_cli_deployment_plan.service_spec)
  =
  { k8s_name = spec.k8s_name
  ; namespace = spec.namespace
  ; push_image = push_image_ref ~workspace ~sha spec
  ; context = ctx_dir
  ; dockerfile = Printf.sprintf "%s/%s/Dockerfile" ctx_dir spec.source_dir
  ; source_dir = spec.source_dir
  }
;;

let dry_run_spec ~workspace ~sha spec =
  { spec with Sol_cli_deployment_plan.image = push_image_ref ~workspace ~sha spec }
;;

let build_image exec =
  match
    Sol_cli_docker.build
      ~tag:exec.push_image
      ~dockerfile:exec.dockerfile
      ~context:exec.context
  with
  | Error e ->
    Error
      (Printf.sprintf
         "docker build failed: %s\n%s"
         exec.source_dir
         (Sol_cli_process.error_to_string e))
  | Ok () -> Ok ()
;;

let push_image exec =
  match Sol_cli_docker.push ~image_ref:exec.push_image with
  | Error e ->
    Error
      (Printf.sprintf
         "docker push failed: %s\n%s"
         exec.push_image
         (Sol_cli_process.error_to_string e))
  | Ok () -> Ok ()
;;

let apply_service_manifest ~ctx ~workspace ~release_id ~dry_run spec =
  Sol_cli_executor.local ~ctx ~workspace ~release_id ~dry_run spec
;;

let wait_for_service_rollout ~ctx spec exec =
  let k8s_name = Sol_cli_deployment_plan.k8s_name_to_string exec.k8s_name in
  let namespace = Sol_cli_deployment_plan.namespace_to_string exec.namespace in
  match spec.Sol_cli_deployment_plan.primitive with
  | Sol_cli_deployment_plan.Fn -> Ok ()
  | Sol_cli_deployment_plan.Svc | Sol_cli_deployment_plan.Worker ->
    (match
       Sol_cli_kubectl.rollout_status
         ~ctx
         ~kind_name:("deployment/" ^ k8s_name)
         ~namespace
     with
     | Ok _ -> Ok ()
     | Error primary ->
       (* The rollout's own error is the operator's evidence for why the deploy
          failed. Keep it as the primary cause and attach the live diagnosis as
          context: a later healthy probe must never replace or obscure the first
          failure. *)
       let pod_expectation = pod_expectation_of_primitive spec.primitive in
       let diagnosis =
         match
           Sol_cli_rollout_diagnosis.diagnose_service_live
             ~ctx
             ~pod_expectation
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

let post_deploy_summary ~facts plan =
  { deployed_count = List.length plan.Sol_cli_deployment_plan.services
  ; pending_migrations = Sol_cli_workspace_model.count_unapplied_migrations facts
  }
;;
