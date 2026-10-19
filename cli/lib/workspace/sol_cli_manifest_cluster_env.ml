type kafka_transport =
  | Plaintext
  | Sasl_ssl

let kafka_transport = function
  | Sol_cli_profile.Local -> Plaintext
  | Sol_cli_profile.Durable -> Sasl_ssl
;;

let kafka_tls = function
  | Plaintext -> false
  | Sasl_ssl -> true
;;

let kafka_protocol_key = "KAFKA_SECURITY_PROTOCOL"

let kafka_transport_of_config config =
  match List.assoc_opt kafka_protocol_key config with
  | Some "sasl_ssl" -> Sasl_ssl
  | _ -> Plaintext
;;

let kafka_ca_mount_path = "/etc/sol/kafka"
let kafka_ca_file = kafka_ca_mount_path ^ "/ca.crt"
let kafka_ca_volume = "kafka-ca"

(* 2d: the managed database's CA. Declared once because three things must name the same
   path — the ConfigMap key the deploy writes, the mount every consumer pod gets, and the
   `sslrootcert` its connection URL carries. The DB CA is Kafka's counterpart: a trust
   anchor the deploy distributes to the cluster, not a per-secret value. *)
let db_ca_mount_path = "/etc/sol/db-ca"
let db_ca_file_name = "ca.pem"
let db_ca_file = db_ca_mount_path ^ "/" ^ db_ca_file_name

(* Container identities belong to the writer, including its declaration projection. *)
let workload_container_name name = name
let migration_container_name = "migrate"

(* The volume name links two fields inside a pod template; delivery is the source,
   consuming container and file location. It is not an application-facing identifier. *)
let db_ca_volume = "db-ca"
let kafka_ca_secret_key = "KAFKA_SSL_CA_CERT"
let kafka_sasl_password_key = "KAFKA_SASL_PASSWORD"
let kafka_sasl_username = "sol-workloads"
let kafka_sasl_mechanism = "SCRAM-SHA-256"
let kafka_brokers = "redpanda.redpanda.svc.cluster.local:9093"
let schema_registry_host = "redpanda.redpanda.svc.cluster.local:8081"
let redpanda_admin_host = "redpanda.redpanda.svc.cluster.local:9644"

(* The platform's observability endpoints. The monitoring namespace, the chart
   service names and their ports are one durable contract: the workload cluster
   env, the local platform's port-forwards, the Grafana datasources, the status
   guidance and the deploy-event join all describe the same services. Declare
   them once here. `*_host_port` is the CLI's local port-forward convention, not
   a cluster fact. *)
let monitoring_namespace = "monitoring"

(* The managed broker's namespace and the chart-created TLS projection the deploy reads
   its CA from. The chart owns the certificate; Sol owns only the consumer projection. *)
let kafka_namespace = "redpanda"
let kafka_ca_secret_name = "redpanda-default-cert"
let kafka_ca_cert_file = "ca.crt"
let loki_service = "loki"
let loki_service_port = 3100
let loki_host_port = 3100
let grafana_service = "grafana"
let grafana_service_port = 80
let grafana_host_port = 3000
let prometheus_service = "prometheus-server"
let prometheus_service_port = 80
let prometheus_host_port = 9090
let pushgateway_service = "prometheus-prometheus-pushgateway"
let pushgateway_service_port = 9091
let pushgateway_host_port = 9091
let tempo_service = "tempo"
let tempo_query_port = 3200
let tempo_query_host_port = 3200
let tempo_otlp_port = 4318
let tempo_otlp_host_port = 4318

let service_host ~namespace ~name =
  Printf.sprintf "%s.%s.svc.cluster.local" name namespace
;;

let service_url ~scheme ~namespace ~name ~port =
  Printf.sprintf "%s://%s:%d" scheme (service_host ~namespace ~name) port
;;

let local_url port = Printf.sprintf "http://localhost:%d" port

(* The durable posture's trust anchor, expressed for the runtimes Sol ships. The OCaml
   Kafka client reads [KAFKA_SSL_CA_LOCATION]; a Node process (the TypeScript units and the
   contract Job) verifies HTTPS with Node's own trust store and reads [NODE_EXTRA_CA_CERTS],
   the standard way to add a CA without disabling verification. Both name the same mounted
   file: the platform CA the deploy delivers as [KAFKA_SSL_CA_CERT], mounted at
   [kafka_ca_file]. This widens the Node process's trust store, but these are Sol-managed
   processes whose only TLS peers are the platform's own endpoints, and the published
   TypeScript client exposes no per-request agent setting to scope it more narrowly. *)
let node_extra_ca_certs_key = "NODE_EXTRA_CA_CERTS"

let kafka_posture_env = function
  | Plaintext -> [ "KAFKA_SECURITY_PROTOCOL", "plaintext" ]
  | Sasl_ssl ->
    [ "KAFKA_SECURITY_PROTOCOL", "sasl_ssl"
    ; "KAFKA_SASL_MECHANISM", kafka_sasl_mechanism
    ; "KAFKA_SASL_USERNAME", kafka_sasl_username
    ; "KAFKA_SSL_CA_LOCATION", kafka_ca_file
    ; node_extra_ca_certs_key, kafka_ca_file
    ]
;;

let kafka_connection_env transport =
  let scheme =
    match transport with
    | Plaintext -> "http"
    | Sasl_ssl -> "https"
  in
  kafka_posture_env transport
  @ [ "KAFKA_BROKERS", kafka_brokers
    ; "SCHEMA_REGISTRY_URL", Printf.sprintf "%s://%s" scheme schema_registry_host
    ; "REDPANDA_ADMIN_URL", Printf.sprintf "%s://%s" scheme redpanda_admin_host
    ]
;;

let telemetry_env =
  [ ( "LOKI_URL"
    , service_url
        ~scheme:"http"
        ~namespace:monitoring_namespace
        ~name:loki_service
        ~port:loki_service_port )
  ; ( "PUSHGATEWAY_URL"
    , service_url
        ~scheme:"http"
        ~namespace:monitoring_namespace
        ~name:pushgateway_service
        ~port:pushgateway_service_port )
  ; ( "TEMPO_URL"
    , service_url
        ~scheme:"http"
        ~namespace:monitoring_namespace
        ~name:tempo_service
        ~port:tempo_otlp_port )
  ]
;;

let cluster_env transport = kafka_connection_env transport @ telemetry_env
let default_cluster_env = cluster_env Plaintext

(* The durable unit's config: the same posture env the contract Job gets (one declaration of
   the trust anchor, so a durable Node consumer cannot receive the CA path in one projection
   and not the other) plus the two TLS endpoints it reaches over the platform CA. *)
let production_kafka_config = kafka_connection_env Sasl_ssl

let kafka_required_secret_keys = function
  | Plaintext -> []
  | Sasl_ssl -> [ kafka_sasl_password_key; kafka_ca_secret_key ]
;;
