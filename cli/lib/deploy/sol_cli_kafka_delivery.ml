let consumer_namespaces (services : Sol_cli_deployment_plan.service_spec list) =
  services
  |> List.filter (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    spec.Sol_cli_deployment_plan.consumes_kafka)
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Sol_cli_deployment_plan.namespace_to_string spec.Sol_cli_deployment_plan.namespace)
  |> List.sort_uniq String.compare
;;

let cluster_name (target : Sol_cli_config.target) =
  match target.cluster_name with
  | Some name when not (Sol_cli_string.is_blank name) -> Ok name
  | _ ->
    Error
      "managed Kafka requires the declared target cluster identity to read its \
       credential authority"
;;

let run ~ctx ~(target : Sol_cli_config.target) ~kafka ~services =
  let open Result.Syntax in
  match kafka with
  | Sol_cli_resource_binding.No_kafka
  | Sol_cli_resource_binding.External_kafka _
  | Sol_cli_resource_binding.Local_kafka _ -> Ok ()
  | Sol_cli_resource_binding.Managed_kafka _ ->
    let namespaces = consumer_namespaces services in
    if namespaces = []
    then Ok ()
    else
      let* cluster_name = cluster_name target in
      let* password =
        Sol_cli_provider_registry.kafka_credential target.provider target ~cluster_name
      in
      (* The chart owns the broker CA; the deploy only projects it. A missing CA is a
         failure to state, not a reason to deliver a consumer that cannot verify. *)
      let* ca =
        Sol_cli_secret.read_secret_key
          ~ctx
          ~namespace:Sol_cli_manifest.kafka_namespace
          ~secret_name:Sol_cli_manifest.kafka_ca_secret_name
          ~key:Sol_cli_manifest.kafka_ca_cert_file
      in
      let secret_name =
        Sol_cli_manifest.kafka_creds_name
          ~target:(Sol_cli_kubernetes_name.sanitize_name target.name)
      in
      let* _ =
        Sol_cli_secret.set_target_keys
          ~ctx
          ~namespaces
          ~secret_name
          ~values:
            [ Sol_cli_manifest.kafka_sasl_password_key, password
            ; Sol_cli_manifest.kafka_ca_secret_key, ca
            ]
      in
      Sol_cli_report.app
        "Kafka: delivered the managed credential to %s in %s."
        secret_name
        (String.concat ", " namespaces);
      Ok ()
;;
