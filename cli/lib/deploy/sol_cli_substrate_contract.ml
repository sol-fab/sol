type verdict = Sol_cli_installation.verdict =
  | Established
  | Unmet of string
  | Unknown of string

type input =
  | Cluster
  | Registry
  | Kafka
  | Postgres
  | Observability
  | Domain

let all = [ Cluster; Registry; Kafka; Postgres; Observability; Domain ]

let name = function
  | Cluster -> "kubernetes cluster"
  | Registry -> "container registry"
  | Kafka -> "kafka and schema registry"
  | Postgres -> "postgres connection"
  | Observability -> "observability endpoints"
  | Domain -> "base domain and tls"
;;

let statement = function
  | Cluster -> "a reachable cluster and a kubeconfig context that reaches it"
  | Registry -> "a registry prefix the cluster's nodes can pull from"
  | Kafka ->
    "broker addresses and a schema-registry URL the workloads reach, with \
     KAFKA_SECURITY_PROTOCOL set (SEC-007)"
  | Postgres ->
    "a database connection the deploy delivers to its consumers from the target's binding"
  | Observability -> "Loki and Pushgateway endpoints the workloads reach"
  | Domain ->
    "a certificate Issuer and a DNS entry when a service declares an ingress host"
;;

type cluster =
  [ `Reachable
  | `Unmet of string
  | `Unknown of string
  ]

type observations =
  { cluster : cluster
  ; registry : string option
  ; base_domain : string option
  }

let evaluate (observations : observations) : (input * verdict) list =
  let cluster =
    match observations.cluster with
    | `Reachable -> Established
    | `Unmet reason -> Unmet reason
    | `Unknown reason -> Unknown reason
  in
  let registry =
    let pullability =
      "Sol cannot make a node pull an image, so whether the cluster can pull from it is \
       unverified"
    in
    match observations.registry with
    | None ->
      Unknown
        (Printf.sprintf
           "the target names no registry prefix, so the provider's default is used; %s"
           pullability)
    | Some prefix -> Unknown (Printf.sprintf "the prefix is %s; %s" prefix pullability)
  in
  let postgres =
    Unknown
      "the database connection is delivered by the deploy from the target's binding; \
       this check reads the target surface, not whether the selected database accepts it"
  in
  let domain =
    match observations.base_domain with
    | None ->
      Unknown
        "no base domain is declared for this target, so a service that declares an \
         ingress host has nothing to be reached under"
    | Some domain ->
      Unknown
        (Printf.sprintf
           "the base domain is %s; the certificate Issuer lives in the cluster and the \
            DNS record in the provider, neither of which this check reads"
           domain)
  in
  [ Cluster, cluster
  ; Registry, registry
  ; ( Kafka
    , Unknown
        "the broker addresses and schema-registry URL are workspace configuration; \
         whether the workloads can reach them, and the broker's security posture, are \
         properties of the cluster's network, and are observed there rather than here" )
  ; Postgres, postgres
  ; ( Observability
    , Unknown
        "the Loki and Pushgateway URLs are workspace configuration; whether the \
         workloads can reach them is a property of the cluster's network, and is \
         observed there rather than here" )
  ; Domain, domain
  ]
;;

let lines observations =
  evaluate observations
  |> List.map (fun (input, verdict) ->
    name input, Sol_cli_installation.verdict_label verdict)
;;

let unmet_or_unknown verdicts =
  List.filter
    (fun (_, verdict) ->
       match verdict with
       | Established -> false
       | Unmet _ | Unknown _ -> true)
    verdicts
;;
