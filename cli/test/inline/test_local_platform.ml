let assets =
  { Sol_cli_local_platform.component_values =
      { Sol_cli_local_platform.redpanda = "redpanda-values"
      ; postgresql = "postgresql-values"
      ; loki = "loki-values"
      ; grafana = "grafana-values"
      ; tempo = "tempo-values"
      ; prometheus = "prometheus-values"
      }
  ; versions =
      { Sol_cli_local_platform.redpanda = "26.1.11"
      ; postgresql = "18.8.17"
      ; loki = "18.12.1"
      ; grafana = "13.2.1"
      ; alloy = "1.12.1"
      ; tempo = "2.3.0"
      ; prometheus = "25.20.1"
      ; ingress_nginx = "4.10.1"
      }
  ; alloy_values = "alloy-values"
  ; dashboards = "dashboards"
  }
;;

let req ?(kafka = false) ?(postgres = false) ?(observability = false) () =
  { Sol_cli_workspace.kafka
  ; postgres
  ; loki = observability
  ; prometheus = observability
  ; tempo = observability
  }
;;

let labels req =
  Sol_cli_local_platform.releases ~req ~assets
  |> List.map (fun (r : Sol_cli_local_platform.release) -> r.label)
;;

let test_everything () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"each component, in install order"
    [ "Redpanda"
    ; "PostgreSQL"
    ; "Loki"
    ; "Grafana"
    ; "Alloy"
    ; "Tempo"
    ; "Prometheus"
    ; "ingress-nginx"
    ]
    (labels (req ~kafka:true ~postgres:true ~observability:true ()))
;;

let test_ingress_always () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing declared"
    [ "ingress-nginx" ]
    (labels (req ()));
  Windtrap.equal
    Windtrap.bool
    ~msg:"no repositories needed"
    false
    (Sol_cli_local_platform.needs_any_chart (req ()))
;;

let test_declared_postgres () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"postgres and the ingress"
    [ "PostgreSQL"; "ingress-nginx" ]
    (labels (req ~postgres:true ()))
;;

let test_values_come_from_the_assets () =
  let find label =
    Sol_cli_local_platform.releases
      ~req:(req ~kafka:true ~postgres:true ~observability:true ())
      ~assets
    |> List.find (fun (r : Sol_cli_local_platform.release) -> r.label = label)
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a component's merged values"
    (Some "redpanda-values")
    (find "Redpanda").values_yaml;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"Alloy's rendered values"
    (Some "alloy-values")
    (find "Alloy").values_yaml;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"pinned, matching the platform module"
    (Some "26.1.11")
    (find "Redpanda").version
;;

(* The versions are declared once in platform/shared/components.json; reading the
   real assets proves every release projects its version from that declaration. *)
let test_versions_come_from_components_json () =
  let real =
    match Sol_cli_local_platform.read_assets () with
    | Ok a -> a
    | Error e -> Windtrap.fail e
  in
  let released =
    Sol_cli_local_platform.releases
      ~req:(req ~kafka:true ~postgres:true ~observability:true ())
      ~assets:real
    |> List.filter_map (fun (r : Sol_cli_local_platform.release) -> r.version)
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"every local chart version is the one components.json declares"
    [ real.versions.redpanda
    ; real.versions.postgresql
    ; real.versions.loki
    ; real.versions.grafana
    ; real.versions.alloy
    ; real.versions.tempo
    ; real.versions.prometheus
    ; real.versions.ingress_nginx
    ]
    released
;;

let forwards req =
  Sol_cli_local_platform.endpoints ~req
  |> List.map (fun (e : Sol_cli_local_platform.endpoint) -> e.forward.name)
;;

let test_endpoints_nothing_declared () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"ingress only"
    [ "ingress" ]
    (forwards (req ()))
;;

let test_endpoints_everything () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"every forward, in the summary's order"
    [ "kafka"
    ; "schema-registry"
    ; "postgres"
    ; "loki"
    ; "grafana"
    ; "prometheus"
    ; "pushgateway"
    ; "tempo"
    ; "tempo-query"
    ; "ingress"
    ]
    (forwards (req ~kafka:true ~postgres:true ~observability:true ()))
;;

let test_endpoint_ports_are_distinct () =
  let ports =
    Sol_cli_local_platform.endpoints
      ~req:(req ~kafka:true ~postgres:true ~observability:true ())
    |> List.map (fun (e : Sol_cli_local_platform.endpoint) -> e.forward.local_port)
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"no two forwards share a host port"
    (List.length ports)
    (List.length (List.sort_uniq compare ports));
  Windtrap.equal
    Windtrap.bool
    ~msg:"not sol local deploy's 8080"
    false
    (List.mem 8080 ports)
;;

let test_k3d_api_version () =
  let env daemon_min = Sol_cli_local_cluster.api_version_env ~daemon_min in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"Docker 29's floor"
    [ "DOCKER_API_VERSION", "1.44" ]
    (env "1.44\n");
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"an older daemon"
    []
    (env "1.24");
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"the floor itself"
    []
    (env "1.43");
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
    ~msg:"unreadable"
    []
    (env "");
  Windtrap.equal
    Windtrap.bool
    ~msg:"numeric, not lexical"
    true
    (Sol_cli_local_cluster.version_gt "1.100" "1.43")
;;

let%test "REFAC-139 part B: everything" = test_everything ()
let%test "REFAC-139 part B: ingress always" = test_ingress_always ()
let%test "REFAC-139 part B: declared postgres" = test_declared_postgres ()
let%test "REFAC-139 part B: values from the assets" = test_values_come_from_the_assets ()

let%test "chart versions come from components.json" =
  test_versions_come_from_components_json ()
;;

let%test "REFAC-139 part F: no endpoints declared" = test_endpoints_nothing_declared ()
let%test "REFAC-139 part F: every endpoint" = test_endpoints_everything ()
let%test "REFAC-139 part F: distinct host ports" = test_endpoint_ports_are_distinct ()
let%test "REFAC-139 part F: k3d API version" = test_k3d_api_version ()

let required_flags req =
  Sol_cli_local_platform.endpoints ~req
  |> List.map (fun (e : Sol_cli_local_platform.endpoint) -> e.forward.name, e.required)
;;

let test_required_endpoints () =
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.bool))
    ~msg:"declared data-plane forwards and ingress are required"
    [ "kafka", true
    ; "schema-registry", true
    ; "postgres", true
    ; "loki", true
    ; "grafana", true
    ; "prometheus", true
    ; "pushgateway", true
    ; "tempo", true
    ; "tempo-query", true
    ; "ingress", true
    ]
    (required_flags (req ~kafka:true ~postgres:true ~observability:true ()));
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.bool))
    ~msg:"an undeclared observability backend is exposed but optional"
    [ "loki", false
    ; "grafana", true
    ; "prometheus", true
    ; "pushgateway", true
    ; "ingress", true
    ]
    (required_flags
       { Sol_cli_workspace.kafka = false
       ; postgres = false
       ; loki = false
       ; prometheus = true
       ; tempo = false
       })
;;

let%test "REFAC-139 part F: endpoint requiredness follows declarations" =
  test_required_endpoints ()
;;

let%test "local PostgreSQL refuses a forward owned by another listener" =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close listener)
    (fun () ->
       Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 15432));
       Unix.listen listener 1;
       match
         Sol_cli_local_platform.postgres_cluster_url
           ~ctx:Sol_cli_kube_destination.local_context
           ()
       with
       | Ok _ -> Windtrap.fail "a foreign listener was accepted as the cluster database"
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the provider preserves the ownership refusal"
           true
           (Sol_cli_string.contains ~needle:"cannot own it" message))
;;
