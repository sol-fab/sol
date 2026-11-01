type backends =
  { serverless : Sol_cli_manifest.service list
  ; kubernetes : Sol_cli_manifest.service list
  }

let split (target : Sol_cli_config.target) services =
  match Sol_cli_config.execution_of_target target with
  | Sol_cli_config.Serverless -> { serverless = services; kubernetes = [] }
  | Sol_cli_config.Kubernetes -> { serverless = []; kubernetes = services }
  | Sol_cli_config.Mixed ->
    { serverless =
        List.filter
          (fun (service : Sol_cli_manifest.service) ->
             match service.primitive with
             | Sol_cli_manifest.Fn -> true
             | Svc | Worker -> false)
          services
    ; kubernetes =
        List.filter
          (fun (service : Sol_cli_manifest.service) ->
             match service.primitive with
             | Sol_cli_manifest.Fn -> false
             | Svc | Worker -> true)
          services
    }
;;

let run ~target ~services ~authorize ~serverless ~kubernetes =
  let open Result.Syntax in
  let { serverless = serverless_units; kubernetes = kubernetes_units } =
    split target services
  in
  (* Authorization is reconciled exactly once, before either backend, from the
     complete target model supplied by the caller. *)
  let* () = authorize () in
  let* () = if serverless_units = [] then Ok () else serverless serverless_units in
  if kubernetes_units = [] then Ok () else kubernetes kubernetes_units
;;
