type execution =
  { plan : Sol_cli_deployment_plan.t
  ; results : Sol_cli_executor.result list
  }

let plan_of_services
      ~workspace
      ~env
      ~facts
      ?requested_scope
      ?declared
      ~platform_shape
      ?image_refs
      ?inventory
      ?target
      ?target_database
      ?provisioned_database
      services
  =
  Sol_cli_deployment_plan.of_services_result
    ~workspace
    ~env
    ~facts
    ?requested_scope
    ?declared
    ~platform_shape
    ?image_refs
    ?inventory
    ?target
    ?target_database
    ?provisioned_database
    services
  |> Result.map_error Sol_cli_deployment_plan.plan_error_to_string
;;

let execute execution ~mode ?before_apply plan =
  Sol_cli_executor.run_plan execution ~mode ?before_apply plan
;;

type request =
  { env : Sol_cli_deployment_plan.env_config
  ; requested_scope : string option
  ; declared : Sol_cli_config.declared option
  ; platform_shape : Sol_cli_profile.platform_shape
  ; (* 2d: see {!Sol_cli_deployment_plan.of_services_result}; [target] is the sanitized
       target a CA mount would be named for, [provisioned_database] the resource Sol owns.
       2b: [target_database] is the target's postgres resource whatever its ownership, so
       the reader routes `POSTGRES_URL` to `<target>-dml-creds` for both. *)
    target : string option
  ; target_database : string option
  ; provisioned_database : string option
  }

let run execution ~(request : request) ~mode ~facts services =
  let open Result.Syntax in
  let* plan =
    plan_of_services
      ~workspace:execution.Sol_cli_execution.workspace
      ~env:request.env
      ~facts
      ?requested_scope:request.requested_scope
      ?declared:request.declared
      ~platform_shape:request.platform_shape
      ?target:request.target
      ?target_database:request.target_database
      ?provisioned_database:request.provisioned_database
      services
  in
  let* results = execute execution ~mode plan in
  Ok { plan; results }
;;

let affected_services ~plan ~results =
  if List.length plan.Sol_cli_deployment_plan.services <> List.length results
  then invalid_arg "Sol_cli_factory.affected_services: plan/results length mismatch";
  List.map2
    (fun spec (result : Sol_cli_executor.result) ->
       Sol_cli_release_inspection.affected_service ~image:result.image spec)
    plan.services
    results
;;
