open Result.Syntax

type route = Sol_cli_http_route.t

type endpoint =
  { name : string
  ; url : string
  }

let runner = Sol_cli_serverless_runner.run

let reconcile_public ~(target : Sol_cli_config.target) ~target_name ~routes =
  let name = Sol_cli_http_route.gateway_name ~target_name in
  match target.provider with
  | Sol_cli_provider.Aws ->
    if routes = []
    then Ok None
    else
      Sol_cli_aws_http_gateway.reconcile
        runner
        ~profile:(Sol_cli_config.provider_field target "profile")
        ~region:target.region
        ~target
        ~name
        routes
      |> Result.map
           (Option.map (fun (endpoint : Sol_cli_aws_http_gateway.endpoint) ->
              { name = endpoint.name; url = endpoint.url }))
  | Sol_cli_provider.Gcp ->
    let* project = Sol_cli_gcp_http_gateway.project target in
    Sol_cli_gcp_http_gateway.reconcile
      runner
      ~project
      ~region:target.region
      ~target
      ~name
      routes
    |> Result.map
         (Option.map (fun (endpoint : Sol_cli_gcp_http_gateway.endpoint) ->
            { name = endpoint.name; url = endpoint.url }))
  | Sol_cli_provider.Byo -> Error "shared HTTP APIs support AWS and GCP targets only"
;;

let restore_public_route ~(target : Sol_cli_config.target) ~target_name (route : route) =
  let name = Sol_cli_http_route.gateway_name ~target_name in
  match target.provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_http_gateway.restore_route
      runner
      ~profile:(Sol_cli_config.provider_field target "profile")
      ~region:target.region
      ~target
      ~name
      route
    |> Result.map
         (Option.map (fun (endpoint : Sol_cli_aws_http_gateway.endpoint) ->
            { name = endpoint.name; url = endpoint.url }))
  | Sol_cli_provider.Gcp ->
    let* project = Sol_cli_gcp_http_gateway.project target in
    Sol_cli_gcp_http_gateway.restore_route
      runner
      ~project
      ~region:target.region
      ~target
      ~name
      route
    |> Result.map
         (Option.map (fun (endpoint : Sol_cli_gcp_http_gateway.endpoint) ->
            { name = endpoint.name; url = endpoint.url }))
  | Sol_cli_provider.Byo -> Error "shared HTTP APIs support AWS and GCP targets only"
;;

let remove_public_route ~(target : Sol_cli_config.target) ~target_name ~path =
  let name = Sol_cli_http_route.gateway_name ~target_name in
  match target.provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_http_gateway.remove_route
      runner
      ~profile:(Sol_cli_config.provider_field target "profile")
      ~region:target.region
      ~target
      ~name
      ~path
    |> Result.map (fun _ -> ())
  | Sol_cli_provider.Gcp ->
    let* project = Sol_cli_gcp_http_gateway.project target in
    Sol_cli_gcp_http_gateway.remove_route
      runner
      ~project
      ~region:target.region
      ~target
      ~name
      ~path
    |> Result.map (fun _ -> ())
  | Sol_cli_provider.Byo -> Error "shared HTTP APIs support AWS and GCP targets only"
;;
