open Result.Syntax

let monitoring_namespace = Sol_cli_manifest.monitoring_namespace

type component =
  | Redpanda
  | Postgresql
  | Loki
  | Grafana
  | Tempo
  | Prometheus

let name = function
  | Redpanda -> "redpanda"
  | Postgresql -> "postgresql"
  | Loki -> "loki"
  | Grafana -> "grafana"
  | Tempo -> "tempo"
  | Prometheus -> "prometheus"
;;

type component_values =
  { redpanda : string
  ; postgresql : string
  ; loki : string
  ; grafana : string
  ; tempo : string
  ; prometheus : string
  }

let value (values : component_values) = function
  | Redpanda -> values.redpanda
  | Postgresql -> values.postgresql
  | Loki -> values.loki
  | Grafana -> values.grafana
  | Tempo -> values.tempo
  | Prometheus -> values.prometheus
;;

type component_versions =
  { redpanda : string
  ; postgresql : string
  ; loki : string
  ; grafana : string
  ; alloy : string
  ; tempo : string
  ; prometheus : string
  ; ingress_nginx : string
  }

type assets =
  { component_values : component_values
  ; versions : component_versions
  ; alloy_values : string
  ; dashboards : string
  }

let read_component ~platform_assets component =
  Sol_cli_platform_component.merged_values_yaml
    ~assets:platform_assets
    ~component:(name component)
    ~profile:"local"
;;

let require_version ~versions name =
  match List.assoc_opt name versions with
  | Some version -> Ok version
  | None ->
    Error
      (Printf.sprintf
         "the shared platform component versions do not declare versions.%s"
         name)
;;

let read_assets () =
  let* assets =
    Sol_cli_platform_assets.resolve ()
    |> Result.map_error Sol_cli_platform_assets.error_to_string
  in
  let* redpanda = read_component ~platform_assets:assets Redpanda in
  let* postgresql = read_component ~platform_assets:assets Postgresql in
  let* loki = read_component ~platform_assets:assets Loki in
  let* grafana = read_component ~platform_assets:assets Grafana in
  let* tempo = read_component ~platform_assets:assets Tempo in
  let* prometheus = read_component ~platform_assets:assets Prometheus in
  let* alloy_values = Sol_cli_dev_observability.alloy_values_yaml ~assets in
  let* dashboards =
    Sol_cli_dev_observability.dashboard_configmap_yaml
      ~assets
      ~namespace:monitoring_namespace
  in
  let* declared_versions = Sol_cli_platform_component.versions ~assets in
  let* redpanda_version = require_version ~versions:declared_versions "redpanda" in
  let* postgresql_version = require_version ~versions:declared_versions "postgresql" in
  let* loki_version = require_version ~versions:declared_versions "loki" in
  let* grafana_version = require_version ~versions:declared_versions "grafana" in
  let* alloy_version = require_version ~versions:declared_versions "alloy" in
  let* tempo_version = require_version ~versions:declared_versions "tempo" in
  let* prometheus_version = require_version ~versions:declared_versions "prometheus" in
  let* ingress_nginx_version =
    require_version ~versions:declared_versions "ingress-nginx"
  in
  Ok
    { component_values = { redpanda; postgresql; loki; grafana; tempo; prometheus }
    ; versions =
        { redpanda = redpanda_version
        ; postgresql = postgresql_version
        ; loki = loki_version
        ; grafana = grafana_version
        ; alloy = alloy_version
        ; tempo = tempo_version
        ; prometheus = prometheus_version
        ; ingress_nginx = ingress_nginx_version
        }
    ; alloy_values
    ; dashboards
    }
;;

let values_of assets component = value assets.component_values component

let needs_grafana (req : Sol_cli_workspace.infra_requirements) =
  req.loki || req.prometheus || req.tempo
;;

let needs_any_chart (req : Sol_cli_workspace.infra_requirements) =
  req.kafka || req.postgres || needs_grafana req
;;

let repositories =
  [ "redpanda", "https://charts.redpanda.com"
  ; "ingress-nginx", "https://kubernetes.github.io/ingress-nginx"
  ; "grafana", "https://grafana.github.io/helm-charts"
  ; "grafana-community", "https://grafana-community.github.io/helm-charts"
  ; "bitnami", "https://charts.bitnami.com/bitnami"
  ; "prometheus-community", "https://prometheus-community.github.io/helm-charts"
  ]
;;

type release =
  { label : string
  ; name : string
  ; chart : string
  ; namespace : string
  ; version : string option
  ; values : (string * Sol_cli_helm.set_val) list
  ; values_yaml : string option
  }

let releases ~(req : Sol_cli_workspace.infra_requirements) ~assets =
  let open Sol_cli_helm in
  let need_grafana = needs_grafana in
  let release ~label name chart ~namespace ?version ?(values = []) ?values_yaml () =
    { label; name; chart; namespace; version; values; values_yaml }
  in
  let kafka_releases =
    if req.kafka
    then
      [ release
          ~label:"Redpanda"
          "redpanda"
          "redpanda/redpanda"
          ~namespace:"redpanda"
          ~version:assets.versions.redpanda
          ~values:
            [ "storage.persistentVolume.size", Str "1Gi"
            ; "external.enabled", Bool true
            ; "external.service.enabled", Bool false
            ; "external.addresses[0]", Str "localhost"
            ; "listeners.kafka.external.default.advertisedPorts[0]", Float 9092.
            ]
          ~values_yaml:(values_of assets Redpanda)
          ()
      ]
    else []
  in
  let postgres_releases =
    if req.postgres
    then
      [ release
          ~label:"PostgreSQL"
          "postgresql"
          "bitnami/postgresql"
          ~namespace:"postgresql"
          ~version:assets.versions.postgresql
          ~values_yaml:(values_of assets Postgresql)
          ()
      ]
    else []
  in
  let observability_releases =
    if need_grafana req
    then
      [ release
          ~label:"Loki"
          "loki"
          "grafana-community/loki"
          ~namespace:monitoring_namespace
          ~version:assets.versions.loki
          ~values_yaml:(values_of assets Loki)
          ()
      ; release
          ~label:"Grafana"
          "grafana"
          "grafana-community/grafana"
          ~namespace:monitoring_namespace
          ~version:assets.versions.grafana
          ~values:[ "adminPassword", Str "dev" ]
          ~values_yaml:(values_of assets Grafana)
          ()
      ; release
          ~label:"Alloy"
          "alloy"
          "grafana/alloy"
          ~namespace:monitoring_namespace
          ~version:assets.versions.alloy
          ~values_yaml:assets.alloy_values
          ()
      ]
    else []
  in
  let tempo_releases =
    if req.tempo
    then
      [ release
          ~label:"Tempo"
          "tempo"
          "grafana-community/tempo"
          ~namespace:monitoring_namespace
          ~version:assets.versions.tempo
          ~values_yaml:(values_of assets Tempo)
          ()
      ]
    else []
  in
  let prometheus_releases =
    if req.prometheus
    then
      [ release
          ~label:"Prometheus"
          "prometheus"
          "prometheus-community/prometheus"
          ~namespace:monitoring_namespace
          ~version:assets.versions.prometheus
          ~values:[ "prometheus-node-exporter.enabled", Bool false ]
          ~values_yaml:(values_of assets Prometheus)
          ()
      ]
    else []
  in
  let ingress_releases =
    [ release
        ~label:"ingress-nginx"
        "ingress-nginx"
        "ingress-nginx/ingress-nginx"
        ~namespace:"ingress-nginx"
        ~version:assets.versions.ingress_nginx
        ~values:[ "controller.service.type", Str "NodePort" ]
        ()
    ]
  in
  List.concat
    [ kafka_releases
    ; postgres_releases
    ; observability_releases
    ; tempo_releases
    ; prometheus_releases
    ; ingress_releases
    ]
;;

type endpoint =
  { forward : Sol_cli_port_forward.spec
  ; required : bool
  ; summary : string
  }

let ingress_local_port = 8088

(* One local PostgreSQL identity, reached through cluster DNS by workloads and a
   process-owned loopback forward by host migration commands. *)
let postgres_service = "postgresql"
let postgres_namespace = "postgresql"
let postgres_remote_port = 5432

let postgres_url ~host ~port =
  Printf.sprintf "postgresql://postgres:dev@%s:%d/dev" host port
;;

let postgres_workload_url =
  postgres_url
    ~host:(postgres_service ^ "." ^ postgres_namespace ^ ".svc.cluster.local")
    ~port:postgres_remote_port
;;

let postgres_cluster_url ~ctx () =
  let local_port = 15432 in
  Sol_cli_report.app "Forwarding postgresql (cluster) → localhost:%d ..." local_port;
  match
    Sol_cli_kubectl.temporary_port_forward
      ~ctx
      ~service:postgres_service
      ~namespace:postgres_namespace
      ~local_port
      ~remote_port:postgres_remote_port
  with
  | Ok () -> Ok (postgres_url ~host:"localhost" ~port:local_port)
  | Error (Not_started error) ->
    Error
      ("could not start kubectl port-forward: " ^ Sol_cli_process.error_to_string error)
  | Error Not_ready ->
    Error "the port-forward to the cluster's PostgreSQL did not become ready"
  | Error (Readiness_check_failed message) -> Error message
;;

let schema_registry_service = "redpanda"
let schema_registry_remote_port = 8081

let schema_registry_forward =
  { Sol_cli_port_forward.name = "schema-registry"
  ; namespace = schema_registry_service
  ; target = "svc/" ^ schema_registry_service
  ; local_port = 8081
  ; remote_port = schema_registry_remote_port
  }
;;

let schema_registry_summary =
  Printf.sprintf
    "  schema-reg   ✓  http://localhost:%d"
    schema_registry_forward.local_port
;;

let free_local_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
       match Unix.getsockname socket with
       | Unix.ADDR_INET (_, port) -> port
       | Unix.ADDR_UNIX _ -> 0)
;;

let with_schema_registry_endpoint f =
  let local_port = free_local_port () in
  match
    Sol_cli_kubectl.temporary_port_forward
      ~ctx:Sol_cli_kube_destination.local_context
      ~service:schema_registry_service
      ~namespace:schema_registry_forward.namespace
      ~local_port
      ~remote_port:schema_registry_forward.remote_port
  with
  | Ok () -> f ~url:(Printf.sprintf "http://localhost:%d" local_port)
  | Error (Not_started e) ->
    Error
      ("could not reach the cluster's schema registry ("
       ^ schema_registry_service
       ^ "/"
       ^ schema_registry_service
       ^ ":"
       ^ string_of_int schema_registry_forward.remote_port
       ^ "): "
       ^ Sol_cli_process.error_to_string e)
  | Error Not_ready ->
    Error
      (Printf.sprintf
         "the port-forward to the cluster's schema registry did not become ready on \
          localhost:%d"
         local_port)
  | Error (Readiness_check_failed message) ->
    Error
      ("the schema registry this deploy would register against is not the cluster's: "
       ^ message)
;;

let endpoints ~(req : Sol_cli_workspace.infra_requirements) =
  let endpoint ~required name ~namespace ~target ~local_port ~remote_port summary =
    { forward = { Sol_cli_port_forward.name; namespace; target; local_port; remote_port }
    ; required
    ; summary
    }
  in
  let grafana = needs_grafana req in
  let service name = "svc/" ^ name in
  let kafka_endpoints =
    if req.kafka
    then
      [ endpoint
          ~required:req.kafka
          "kafka"
          ~namespace:"redpanda"
          ~target:"pod/redpanda-0"
          ~local_port:9092
          ~remote_port:9094
          "  kafka        ✓  localhost:9092  (port-forwarded)"
      ; { forward = schema_registry_forward
        ; required = req.kafka
        ; summary = schema_registry_summary
        }
      ]
    else []
  in
  let postgres_endpoints =
    if req.postgres
    then
      [ endpoint
          ~required:req.postgres
          "postgres"
          ~namespace:postgres_namespace
          ~target:(service postgres_service)
          ~local_port:postgres_remote_port
          ~remote_port:postgres_remote_port
          (Printf.sprintf
             "  postgres     ✓  %s  (port-forwarded)"
             (postgres_url ~host:"localhost" ~port:postgres_remote_port))
      ]
    else []
  in
  let observability_endpoints =
    if grafana
    then
      [ endpoint
          ~required:req.loki
          "loki"
          ~namespace:monitoring_namespace
          ~target:(service Sol_cli_manifest.loki_service)
          ~local_port:Sol_cli_manifest.loki_host_port
          ~remote_port:Sol_cli_manifest.loki_service_port
          (Printf.sprintf
             "  loki         ✓  %s  (port-forwarded)"
             (Sol_cli_manifest.local_url Sol_cli_manifest.loki_host_port))
      ; endpoint
          ~required:grafana
          "grafana"
          ~namespace:monitoring_namespace
          ~target:(service Sol_cli_manifest.grafana_service)
          ~local_port:Sol_cli_manifest.grafana_host_port
          ~remote_port:Sol_cli_manifest.grafana_service_port
          (Printf.sprintf
             "  grafana      ✓  %s  (port-forwarded)"
             (Sol_cli_manifest.local_url Sol_cli_manifest.grafana_host_port))
      ]
    else []
  in
  let prometheus_endpoints =
    if req.prometheus
    then
      [ endpoint
          ~required:req.prometheus
          "prometheus"
          ~namespace:monitoring_namespace
          ~target:(service Sol_cli_manifest.prometheus_service)
          ~local_port:Sol_cli_manifest.prometheus_host_port
          ~remote_port:Sol_cli_manifest.prometheus_service_port
          (Printf.sprintf
             "  prometheus   ✓  %s  (port-forwarded)"
             (Sol_cli_manifest.local_url Sol_cli_manifest.prometheus_host_port))
      ; endpoint
          ~required:req.prometheus
          "pushgateway"
          ~namespace:monitoring_namespace
          ~target:(service Sol_cli_manifest.pushgateway_service)
          ~local_port:Sol_cli_manifest.pushgateway_host_port
          ~remote_port:Sol_cli_manifest.pushgateway_service_port
          (Printf.sprintf
             "  pushgateway  ✓  %s  (port-forwarded)"
             (Sol_cli_manifest.local_url Sol_cli_manifest.pushgateway_host_port))
      ]
    else []
  in
  let tempo_endpoints =
    if req.tempo
    then
      [ endpoint
          ~required:req.tempo
          "tempo"
          ~namespace:monitoring_namespace
          ~target:(service Sol_cli_manifest.tempo_service)
          ~local_port:Sol_cli_manifest.tempo_otlp_host_port
          ~remote_port:Sol_cli_manifest.tempo_otlp_port
          (Printf.sprintf
             "  tempo        ✓  %s  (OTLP, port-forwarded)"
             (Sol_cli_manifest.local_url Sol_cli_manifest.tempo_otlp_host_port))
      ; endpoint
          ~required:req.tempo
          "tempo-query"
          ~namespace:monitoring_namespace
          ~target:(service Sol_cli_manifest.tempo_service)
          ~local_port:Sol_cli_manifest.tempo_query_host_port
          ~remote_port:Sol_cli_manifest.tempo_query_port
          (Printf.sprintf
             "  tempo-query  ✓  %s  (port-forwarded)"
             (Sol_cli_manifest.local_url Sol_cli_manifest.tempo_query_host_port))
      ]
    else []
  in
  let ingress_endpoints =
    [ endpoint
        ~required:true
        "ingress"
        ~namespace:"ingress-nginx"
        ~target:"svc/ingress-nginx-controller"
        ~local_port:ingress_local_port
        ~remote_port:80
        (Printf.sprintf
           "  ingress      ✓  http://localhost:%d  (ingress-nginx, port-forwarded)"
           ingress_local_port)
    ]
  in
  List.concat
    [ kafka_endpoints
    ; postgres_endpoints
    ; observability_endpoints
    ; prometheus_endpoints
    ; tempo_endpoints
    ; ingress_endpoints
    ]
;;
