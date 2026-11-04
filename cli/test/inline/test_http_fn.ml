let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_temp_file content f =
  let path = Filename.temp_file "sol-http-fn-" ".toml" in
  write path content;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let parse content = with_temp_file content (fun path -> Sol_cli_toml.load_result path)
let contains needle haystack = Sol_cli_string.contains ~needle haystack

let k8s_name name =
  match Sol_cli_kubernetes_name.k8s_name_of_source name with
  | Ok name -> name
  | Error message -> Windtrap.fail message
;;

let namespace ~workspace ~domain =
  match Sol_cli_kubernetes_name.namespace_of_parts ~workspace ~domain with
  | Ok namespace -> namespace
  | Error message -> Windtrap.fail message
;;

let cpu value =
  match Sol_cli_toml.cpu_quantity_of_string value with
  | Ok value -> value
  | Error message -> Windtrap.fail message
;;

let hostname value =
  match Sol_cli_toml.hostname_of_string value with
  | Ok value -> value
  | Error message -> Windtrap.fail message
;;

let memory value =
  match Sol_cli_toml.memory_quantity_of_string value with
  | Ok value -> value
  | Error message -> Windtrap.fail message
;;

let http_fn_spec (http : Sol_cli_toml.http_trigger) : Sol_cli_deployment_plan.service_spec
  =
  { domain = "orders"
  ; source_name = "quote_fn"
  ; k8s_name = k8s_name "quote_fn"
  ; namespace = namespace ~workspace:"myapp" ~domain:"orders"
  ; primitive = Sol_cli_deployment_plan.Fn
  ; source_dir = "app/orders/quote_fn"
  ; image = "registry.example/myapp/quote-fn:abc123"
  ; config = [ "SOL_HTTP_PATH", http.path ]
  ; secrets = []
  ; secret_sources = []
  ; build_secret_keys = []
  ; volumes = []
  ; schedule = None
  ; schedule_timezone = None
  ; scheduled_concurrency = Sol_cli_toml.Allow
  ; backoff_limit = 3
  ; http = Some http
  ; replicas = 1
  ; availability = Sol_cli_availability.Single
  ; consumes_kafka = false
  ; language = Some Sol_cli_compat.Ocaml
  ; cpu = cpu "100m"
  ; memory = memory "128Mi"
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  ; called_by = []
  ; extra_labels = []
  ; progressive_delivery = None
  ; uses = []
  ; database = Sol_cli_resource_binding.No_postgres_use
  }
;;

let render http =
  let spec = http_fn_spec http in
  match
    Sol_cli_deployment_render.render_spec
      ~workspace:"myapp"
      ~release_id:
        (Sol_cli_release_id.of_content
           { workspace = "myapp"; environment = None; workloads = []; contract = [] })
      spec
  with
  | Ok bundle -> bundle
  | Error message -> Windtrap.fail message
;;

let%test "http trigger: public route parses with an explicit exposure" =
  match parse "[service]\nhttp_path = \"/quote\"\nhttp_exposure = \"public\"\n" with
  | Error error -> Windtrap.fail (Sol_cli_toml.parse_error_to_string error)
  | Ok parsed ->
    (match parsed.http with
     | None -> Windtrap.fail "expected an HTTP trigger"
     | Some http ->
       Windtrap.equal Windtrap.string ~msg:"path" "/quote" http.path;
       check_bool "exposure" true (http.exposure = Sol_cli_toml.Http_public))
;;

let%test "http trigger: path without exposure is refused" =
  match parse "[service]\nhttp_path = \"/quote\"\n" with
  | Ok _ -> Windtrap.fail "accepted an HTTP path without an exposure"
  | Error error ->
    check_bool
      "names exposure"
      true
      (contains "http_exposure" (Sol_cli_toml.parse_error_to_string error))
;;

let%test "http trigger: exposure without path is refused" =
  match parse "[service]\nhttp_exposure = \"internal\"\n" with
  | Ok _ -> Windtrap.fail "accepted an exposure without a path"
  | Error error ->
    check_bool
      "names path"
      true
      (contains "http_path" (Sol_cli_toml.parse_error_to_string error))
;;

let%test "http trigger: schedule and HTTP path are mutually exclusive" =
  match
    parse
      "[service]\n\
       schedule = \"0 * * * *\"\n\
       http_path = \"/quote\"\n\
       http_exposure = \"public\"\n"
  with
  | Ok _ -> Windtrap.fail "accepted both a schedule and an HTTP trigger"
  | Error error ->
    check_bool
      "names the trigger overlap"
      true
      (contains "exactly one trigger" (Sol_cli_toml.parse_error_to_string error))
;;

let%test "http trigger: route must be an exact absolute path" =
  let refused content =
    match parse content with
    | Ok _ -> false
    | Error _ -> true
  in
  check_bool
    "no leading slash"
    true
    (refused "[service]\nhttp_path = \"quote\"\nhttp_exposure = \"public\"\n");
  check_bool
    "trailing slash"
    true
    (refused "[service]\nhttp_path = \"/quote/\"\nhttp_exposure = \"public\"\n");
  check_bool
    "query string"
    true
    (refused "[service]\nhttp_path = \"/quote?x=1\"\nhttp_exposure = \"public\"\n");
  check_bool
    "route parameter"
    true
    (refused "[service]\nhttp_path = \"/quote/{id}\"\nhttp_exposure = \"public\"\n")
;;

let%test "http function: public exposure renders a Deployment, Service, and Ingress" =
  let bundle =
    render { Sol_cli_toml.path = "/quote"; exposure = Sol_cli_toml.Http_public }
  in
  check_bool "Deployment" true (contains "kind: Deployment" bundle.workload_yaml);
  check_bool "Service" true (contains "kind: Service" bundle.workload_yaml);
  check_bool "Ingress" true (contains "kind: Ingress" bundle.workload_yaml);
  check_bool "no CronJob" false (contains "kind: CronJob" bundle.workload_yaml);
  check_bool "route path" true (contains "/quote" bundle.workload_yaml)
;;

let%test "http function: internal exposure renders no Ingress" =
  let bundle =
    render { Sol_cli_toml.path = "/quote"; exposure = Sol_cli_toml.Http_internal }
  in
  check_bool "Deployment" true (contains "kind: Deployment" bundle.workload_yaml);
  check_bool "Service" true (contains "kind: Service" bundle.workload_yaml);
  check_bool "no Ingress" false (contains "kind: Ingress" bundle.workload_yaml)
;;

let%test "public HTTP functions share one Kubernetes ingress host" =
  let host = hostname "api.example" in
  let quote =
    { (http_fn_spec { Sol_cli_toml.path = "/quote"; exposure = Sol_cli_toml.Http_public }) with
      Sol_cli_deployment_plan.ingress_host = Some host
    }
  in
  let orders =
    { quote with
      Sol_cli_deployment_plan.source_name = "orders_fn"
    ; k8s_name = k8s_name "orders_fn"
    ; http = Some { Sol_cli_toml.path = "/orders"; exposure = Sol_cli_toml.Http_public }
    }
  in
  let render spec =
    match
      Sol_cli_deployment_render.render_spec
        ~workspace:"myapp"
        ~release_id:
          (Sol_cli_release_id.of_content
             { workspace = "myapp"; environment = None; workloads = []; contract = [] })
        spec
    with
    | Ok bundle -> bundle.workload_yaml
    | Error message -> Windtrap.fail message
  in
  let quote_yaml = render quote in
  let orders_yaml = render orders in
  check_bool "quote host" true (contains "host: api.example" quote_yaml);
  check_bool "quote path" true (contains "/quote" quote_yaml);
  check_bool "orders host" true (contains "host: api.example" orders_yaml);
  check_bool "orders path" true (contains "/orders" orders_yaml)
;;

let%test "Kubernetes public routes must share one host" =
  let host value = Some (hostname value) in
  let quote =
    { (http_fn_spec { Sol_cli_toml.path = "/quote"; exposure = Sol_cli_toml.Http_public }) with
      Sol_cli_deployment_plan.ingress_host = host "api.example"
    }
  in
  let orders =
    { quote with
      Sol_cli_deployment_plan.source_name = "orders_fn"
    ; k8s_name = k8s_name "orders_fn"
    ; http = Some { Sol_cli_toml.path = "/orders"; exposure = Sol_cli_toml.Http_public }
    }
  in
  let other_host =
    { orders with Sol_cli_deployment_plan.ingress_host = host "other.example" }
  in
  (match Sol_cli_deployment_plan.validate_public_http_routes [ quote; orders ] with
   | Ok () -> ()
   | Error error -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string error));
  (match Sol_cli_deployment_plan.validate_public_http_routes [ quote; other_host ] with
   | Ok () -> Windtrap.fail "accepted two ingress hosts"
   | Error error ->
     check_bool
       "names the host"
       true
       (contains "ingress_host" (Sol_cli_deployment_plan.plan_error_to_string error)));
  match
    Sol_cli_deployment_plan.validate_public_http_routes
      [ quote
      ; { orders with
          http =
            Some { Sol_cli_toml.path = "/quote"; exposure = Sol_cli_toml.Http_public }
        }
      ]
  with
  | Ok () -> Windtrap.fail "accepted duplicate routes"
  | Error error ->
    check_bool
      "names the route"
      true
      (contains "same route" (Sol_cli_deployment_plan.plan_error_to_string error))
;;

let%test "http function: is_http_function distinguishes it from a scheduled function" =
  let http =
    http_fn_spec { Sol_cli_toml.path = "/quote"; exposure = Sol_cli_toml.Http_public }
  in
  check_bool "http" true (Sol_cli_deployment_plan.is_http_function http);
  let scheduled =
    { http with Sol_cli_deployment_plan.http = None; schedule = Some "0 * * * *" }
  in
  check_bool "scheduled" false (Sol_cli_deployment_plan.is_http_function scheduled);
  Windtrap.equal
    Windtrap.string
    ~msg:"scheduled resource"
    "cronjob"
    (Sol_cli_deployment_plan.resource_of_spec scheduled);
  Windtrap.equal
    Windtrap.string
    ~msg:"http resource"
    "deployment"
    (Sol_cli_deployment_plan.resource_of_spec http)
;;
