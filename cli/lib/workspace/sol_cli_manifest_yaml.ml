type primitive =
  | Svc
  | Worker
  | Fn

type service =
  { domain : string
  ; name : string
  ; primitive : primitive
  ; dir : string
  }

let primitive_label = function
  | Svc -> "svc"
  | Worker -> "worker"
  | Fn -> "fn"
;;

type workload_shape =
  | Http_service
  | Background_worker

(* Re-exported, not defined: the model owns the credential vocabulary
   ([Sol_cli_secret_source]), and this renderer consumes it like any other consumer. *)
type secret_source = Sol_cli_secret_source.t =
  | Sol_managed
  | External of
      { store : string
      ; key : string
      }

module Workload_spec = struct
  type t =
    { extra_labels : (string * string) list
    ; secret_keys : string list
    ; secret_sources : (string * secret_source) list
    ; volumes : Sol_cli_toml.volume list
    ; projected_identities : Sol_cli_identity_projection.t list
    ; env : string option
    ; config_hash : string
    ; availability : Sol_cli_availability.t
    ; consumes_kafka : bool
    ; kafka_tls : bool
    ; readiness_path : string
    ; shape : workload_shape
    ; replicas : int
    ; cpu : string
    ; memory : string
    ; ns : string
    ; name : string
    ; image : string
    ; workspace : string
    ; domain : string
    ; primitive : string
    ; release_id : Sol_cli_release_id.t
    ; (* 2d: the CA ConfigMap to mount when this unit consumes a Sol-provisioned database,
         so the pod can run the provider's `sslmode`. [None] when it consumes none. 2b's
         reader delivers a class Secret whose URL carries `sslrootcert` at this path, so the
         mount is what makes the consumer's verification work. *)
      db_ca_configmap : string option
    ; (* 2b: the `<target>-dml-creds` Secret this unit reads `POSTGRES_URL` from, when it
         consumes the target's database resource. [None] for a unit that does not, so a unit
         that merely declares `POSTGRES_URL` keeps reading its own Secret. The name is
         computed by the deploy renderer from the plan's [db_uses_target], so the writer
         ({!Sol_cli_database_setup_render}) and this reader share one definition. *)
      db_dml_creds_name : string option
    }
end

open Sol_cli_manifest_cluster_env

(* 2b: no unit receives `POSTGRES_URL` by default any more. It reaches a unit only from the
   target's database binding — the `uses:` capability — as `<target>-dml-creds`, or as an
   application secret the unit declares and the operator writes itself. `SOL_API_KEY` was
   never a workload default either: only a unit that serves or calls `ApiKey` routes
   declares it. *)
let default_secrets = []
let runtime_secret_name = "sol-secrets"

(** The key the database class Secrets carry and a consumer reads. It must equal
    {!Sol_cli_database_setup_render.postgres_url_key}; the deploy renderer that computes the
    class Secret name shares that definition, and a test asserts the two agree. *)
let postgres_url_key = "POSTGRES_URL"

(** The inputs the target's database binding supplies: `POSTGRES_URL`, and only for a unit
    that consumes the target's database. A unit that merely declares `POSTGRES_URL` keeps it
    in its own Secret and is verified there. The signal is the capability, not the key name. *)
let database_secret_keys db_uses_target =
  if db_uses_target then [ postgres_url_key ] else []
;;

(** **Which keys exist**: the declared keys, `POSTGRES_URL` when the unit consumes the
    target's database, and the target's Kafka keys. This is one leg of the input decision;
    the other two are `Sol_cli_deploy_selection.unit_input_owners` (who owns each key) and
    {!secret_name_for_key} (which Secret the reader reads it from). *)
let required_secret_keys ?(transport = Plaintext) ?(db_uses_target = false) declared =
  List.sort_uniq
    String.compare
    (declared @ database_secret_keys db_uses_target @ kafka_required_secret_keys transport)
;;

module Y = Sol_cli_yaml

let config_hash cluster_env extra_env =
  cluster_env @ extra_env
  |> List.map (fun (k, v) -> k ^ "=" ^ v)
  |> String.concat "\n"
  |> Digest.string
  |> Digest.to_hex
;;

let overlay_env base over =
  let replaced =
    List.map (fun (k, v) -> k, Option.value (List.assoc_opt k over) ~default:v) base
  in
  replaced @ List.filter (fun (k, _) -> not (List.mem_assoc k base)) over
;;

let quoted_map pairs = pairs |> List.map (fun (k, v) -> k, Y.quoted v) |> Y.map
let metadata ~ns ~name = Y.map [ "name", Y.string name; "namespace", Y.string ns ]

let metadata_with_labels ~labels ~ns ~name =
  Y.map
    ([ "name", Y.string name; "namespace", Y.string ns ]
     @
     if labels = []
     then []
     else [ "labels", Y.map (List.map (fun (k, v) -> k, Y.string v) labels) ])
;;

let app_selector name = Y.map [ "app", Y.string name ]

let resource ~api_version ~kind fields =
  Y.document
    (Y.map (("apiVersion", Y.string api_version) :: ("kind", Y.string kind) :: fields))
;;

let namespace_doc ~ns =
  resource
    ~api_version:"v1"
    ~kind:"Namespace"
    [ "metadata", Y.map [ "name", Y.string ns ] ]
;;

let role_binding_doc ~ns ~name ~cluster_role ~group =
  resource
    ~api_version:"rbac.authorization.k8s.io/v1"
    ~kind:"RoleBinding"
    [ "metadata", metadata ~ns ~name
    ; ( "roleRef"
      , Y.map
          [ "apiGroup", Y.string "rbac.authorization.k8s.io"
          ; "kind", Y.string "ClusterRole"
          ; "name", Y.string cluster_role
          ] )
    ; ( "subjects"
      , Y.list
          [ Y.map
              [ "kind", Y.string "Group"
              ; "name", Y.string group
              ; "apiGroup", Y.string "rbac.authorization.k8s.io"
              ]
          ] )
    ]
;;

let deploy_role_binding_doc ~ns =
  role_binding_doc
    ~ns
    ~name:"sol-deploy"
    ~cluster_role:"sol-deploy"
    ~group:"sol:deployers"
;;

let operator_role_binding_doc ~ns =
  role_binding_doc
    ~ns
    ~name:"sol-operator"
    ~cluster_role:"sol-operator-diagnostics"
    ~group:"sol:operators"
;;

let service_account_doc ~ns ~name =
  resource
    ~api_version:"v1"
    ~kind:"ServiceAccount"
    [ "automountServiceAccountToken", Y.bool false; "metadata", metadata ~ns ~name ]
;;

let configmap_doc ?(cluster_env = default_cluster_env) ?(extra_env = []) ~ns ~name () =
  resource
    ~api_version:"v1"
    ~kind:"ConfigMap"
    [ "metadata", metadata ~ns ~name:(name ^ "-env")
    ; "data", quoted_map (overlay_env cluster_env extra_env)
    ]
;;

let workload_secret_name name = Printf.sprintf "%s-secrets" name
let external_secret_name name = Printf.sprintf "%s-external-secrets" name

(* The single routing decision: which Secret object holds a declared key. Every
   consumer must use it — the env [secretKeyRef] and the Kafka CA volume — or a key
   declared external can be projected from one object and read from another.

   2b adds one case ahead of it: a unit that consumes the target's database reads
   `POSTGRES_URL` from that target's DML class Secret, whatever the database's ownership.
   The signal is the capability ([db_dml_creds_name] is [Some]), not the key name — a unit
   that merely declares `POSTGRES_URL` falls through to its own Secret.

   This is the reader side of `Sol_cli_deploy_selection.unit_input_owners`; the two agree
   because [db_dml_creds_name] is [Option.map dml_creds_name db_uses_target], the capability
   the ownership decision also reads. {!required_secret_keys} is the third leg (which keys
   exist). *)
let secret_name_for_key ~name ~secret_sources ~db_dml_creds_name key =
  match db_dml_creds_name with
  | Some creds when String.equal key postgres_url_key -> creds
  | _ ->
    (match List.assoc_opt key secret_sources with
     | Some (External _) -> external_secret_name name
     | Some Sol_managed | None -> workload_secret_name name)
;;

let secret_doc
      ?(base_secrets = default_secrets)
      ?(extra_secrets = [])
      ?(labels = [])
      ~ns
      ~name
      ()
  =
  (* Sol writes the unit Secret with `sol secret set`; it is not part of a rendered
     bundle, so there is no redacted/placeholder emission path. A caller supplies exactly
     the values it means to write. *)
  let secrets = base_secrets @ extra_secrets in
  resource
    ~api_version:"v1"
    ~kind:"Secret"
    [ "metadata", metadata_with_labels ~labels ~ns ~name
    ; "type", Y.string "Opaque"
    ; "stringData", quoted_map secrets
    ]
;;

let external_secret_doc ~secret_refs ~ns ~name =
  let remote_ref (secret_key, store_ref, remote_key) =
    Y.map
      [ "secretKey", Y.string secret_key
      ; "remoteRef", Y.map [ "key", Y.string remote_key ]
      ; ( "sourceRef"
        , Y.map
            [ ( "storeRef"
              , Y.map [ "name", Y.string store_ref; "kind", Y.string "SecretStore" ] )
            ] )
      ]
  in
  resource
    ~api_version:"external-secrets.io/v1"
    ~kind:"ExternalSecret"
    [ ( "metadata"
      , metadata_with_labels
          ~labels:[ "app.kubernetes.io/managed-by", "sol" ]
          ~ns
          ~name:(external_secret_name name) )
    ; ( "spec"
      , Y.map
          [ "refreshInterval", Y.string "1h"
          ; ( "target"
            , Y.map
                [ "name", Y.string (external_secret_name name)
                ; "creationPolicy", Y.string "Owner"
                ] )
          ; "data", Y.list (List.map remote_ref secret_refs)
          ] )
    ]
;;

let secret_key_refs ~name ~secret_sources ~db_dml_creds_name secret_keys =
  secret_keys
  |> List.map (fun key ->
    let secret_name = secret_name_for_key ~name ~secret_sources ~db_dml_creds_name key in
    Y.map
      [ "name", Y.string key
      ; ( "valueFrom"
        , Y.map
            [ "secretKeyRef", Y.map [ "name", Y.string secret_name; "key", Y.string key ]
            ] )
      ])
;;

let sanitize_label_value = Sol_cli_kubernetes_name.sanitize_label_value

let observability_identity =
  [ "workspace", "SOL_WORKSPACE"
  ; "env", "SOL_ENV"
  ; "domain", "SOL_DOMAIN"
  ; "service", "SOL_SERVICE"
  ; "primitive", "SOL_PRIMITIVE"
  ; "release", "SOL_RELEASE"
  ]
;;

let identity_value ?env ?release ~workspace ~domain ~service ~primitive = function
  | "workspace" -> Some (sanitize_label_value workspace)
  | "env" -> Option.map sanitize_label_value env
  | "domain" -> Some (sanitize_label_value domain)
  | "service" -> Some (sanitize_label_value service)
  | "primitive" -> Some (sanitize_label_value primitive)
  | "release" -> Option.map Sol_cli_release_id.to_string release
  | _ -> None
;;

let taxonomy_fields ?env ?release ~workspace ~domain ~service ~primitive () =
  observability_identity
  |> List.filter_map (fun (label, var) ->
    Option.map
      (fun value -> label, var, value)
      (identity_value ?env ?release ~workspace ~domain ~service ~primitive label))
;;

let observability_taxonomy ?env ?release ~workspace ~domain ~service ~primitive () =
  taxonomy_fields ?env ?release ~workspace ~domain ~service ~primitive ()
  |> List.map (fun (label, _, value) -> label, value)
;;

let taxonomy_labels ?env ~workspace ~domain ~service ~primitive ~release_id () =
  observability_taxonomy
    ?env
    ~release:release_id
    ~workspace
    ~domain
    ~service
    ~primitive
    ()
;;

let identity_env ?env ?release ~workspace ~domain ~service ~primitive () =
  taxonomy_fields ?env ?release ~workspace ~domain ~service ~primitive ()
  |> List.map (fun (_, var, value) -> var, value)
;;

let volume_claim_name ~name ~volume_name = Printf.sprintf "%s-%s" name volume_name

let pvc_docs ~ns ~name volumes =
  volumes
  |> List.map (fun (v : Sol_cli_toml.volume) ->
    resource
      ~api_version:"v1"
      ~kind:"PersistentVolumeClaim"
      [ "metadata", metadata ~ns ~name:(volume_claim_name ~name ~volume_name:v.name)
      ; ( "spec"
        , Y.map
            [ ( "accessModes"
              , Y.list
                  [ Y.string (Sol_cli_toml.volume_access_mode_to_string v.access_mode) ] )
            ; "resources", Y.map [ "requests", Y.map [ "storage", Y.string v.size ] ]
            ] )
      ])
;;

let default_termination_grace_seconds = 45

let probe ~path ~port settings =
  Y.map
    (("httpGet", Y.map [ "path", Y.string path; "port", Y.int port ])
     :: List.map (fun (key, n) -> key, Y.int n) settings)
;;

let container_port = function
  | Http_service -> 8080
  | Background_worker -> 9090
;;

let probes ~shape ~consumes_kafka ~readiness_path =
  match shape, consumes_kafka with
  | Http_service, _ ->
    [ ( "startupProbe"
      , probe ~path:"/healthz" ~port:8080 [ "failureThreshold", 30; "periodSeconds", 5 ] )
    ; ( "livenessProbe"
      , probe
          ~path:"/healthz"
          ~port:8080
          [ "initialDelaySeconds", 5; "periodSeconds", 10 ] )
    ; ( "readinessProbe"
      , probe
          ~path:readiness_path
          ~port:8080
          [ "initialDelaySeconds", 5; "periodSeconds", 10 ] )
    ]
  | Background_worker, true ->
    [ ( "startupProbe"
      , probe ~path:"/readyz" ~port:9090 [ "failureThreshold", 60; "periodSeconds", 5 ] )
    ; "readinessProbe", probe ~path:"/readyz" ~port:9090 [ "periodSeconds", 10 ]
    ; ( "livenessProbe"
      , probe ~path:"/livez" ~port:9090 [ "periodSeconds", 10; "failureThreshold", 3 ] )
    ]
  | Background_worker, false -> []
;;

let non_root_pod_security =
  Y.map
    [ "runAsNonRoot", Y.bool true
    ; "runAsUser", Y.int 65534
    ; "runAsGroup", Y.int 65534
    ; "seccompProfile", Y.map [ "type", Y.string "RuntimeDefault" ]
    ]
;;

let container_security =
  Y.map
    [ "allowPrivilegeEscalation", Y.bool false; "readOnlyRootFilesystem", Y.bool true ]
;;

let env_from ~name =
  Y.list [ Y.map [ "configMapRef", Y.map [ "name", Y.string (name ^ "-env") ] ] ]
;;

let resources ~cpu ~memory =
  let quantities = Y.map [ "cpu", Y.string cpu; "memory", Y.string memory ] in
  Y.map [ "requests", quantities; "limits", quantities ]
;;

let non_empty_list key = function
  | [] -> []
  | items -> [ key, Y.list items ]
;;

let pod_template
      { Workload_spec.extra_labels
      ; secret_keys
      ; secret_sources
      ; volumes
      ; projected_identities
      ; env
      ; config_hash
      ; availability
      ; consumes_kafka
      ; kafka_tls
      ; readiness_path
      ; shape
      ; cpu
      ; memory
      ; name
      ; image
      ; workspace
      ; domain
      ; primitive
      ; release_id
      ; db_dml_creds_name
      ; db_ca_configmap
      ; _
      }
  =
  let port = container_port shape in
  let labels =
    ("app", Y.string name)
    :: (taxonomy_labels ?env ~workspace ~domain ~service:name ~primitive ~release_id ()
        @ extra_labels
        |> List.map (fun (k, v) -> k, Y.quoted v))
  in
  let deployed_grants =
    match secret_keys with
    | [] -> []
    | keys ->
      [ ( Sol_cli_grant.annotation_key
        , Sol_cli_grant.encode_tags (List.map Sol_cli_grant.tag_of_secret_key keys) )
      ]
  in
  let annotations =
    quoted_map
      ([ "sol.dev/config-hash", config_hash
       ; "prometheus.io/scrape", "true"
       ; "prometheus.io/port", string_of_int port
       ]
       @ deployed_grants)
  in
  let spread =
    if Sol_cli_availability.is_node_failure_tolerant availability
    then
      [ ( "topologySpreadConstraints"
        , Y.list
            [ Y.map
                [ "maxSkew", Y.int 1
                ; "topologyKey", Y.string "kubernetes.io/hostname"
                ; "whenUnsatisfiable", Y.string "DoNotSchedule"
                ; "labelSelector", Y.map [ "matchLabels", app_selector name ]
                ]
            ] )
      ]
    else []
  in
  let pod_volumes =
    volumes
    |> List.map (fun (v : Sol_cli_toml.volume) ->
      Y.map
        [ "name", Y.string v.name
        ; ( "persistentVolumeClaim"
          , Y.map [ "claimName", Y.string (volume_claim_name ~name ~volume_name:v.name) ]
          )
        ])
  in
  let volume_mounts =
    volumes
    |> List.map (fun (v : Sol_cli_toml.volume) ->
      Y.map [ "name", Y.string v.name; "mountPath", Y.string v.mount_path ])
  in
  let projected_identity_volumes =
    projected_identities
    |> List.map (fun (p : Sol_cli_identity_projection.t) ->
      Y.map
        [ "name", Y.string p.volume_name
        ; ( "projected"
          , Y.map
              [ ( "sources"
                , Y.list
                    [ Y.map
                        [ ( "serviceAccountToken"
                          , Y.map
                              [ "audience", Y.string p.audience
                              ; "expirationSeconds", Y.int 3600
                              ; "path", Y.string "token"
                              ] )
                        ]
                    ] )
              ] )
        ])
  in
  let projected_identity_mounts =
    projected_identities
    |> List.map (fun (p : Sol_cli_identity_projection.t) ->
      Y.map
        [ "name", Y.string p.volume_name
        ; "mountPath", Y.string p.mount_path
        ; "readOnly", Y.bool true
        ])
  in
  let kafka_ca_volumes =
    if kafka_tls
    then
      [ Y.map
          [ "name", Y.string kafka_ca_volume
          ; ( "secret"
            , Y.map
                [ ( "secretName"
                  , Y.string
                      (secret_name_for_key
                         ~name
                         ~secret_sources
                         ~db_dml_creds_name
                         kafka_ca_secret_key) )
                ; ( "items"
                  , Y.list
                      [ Y.map
                          [ "key", Y.string kafka_ca_secret_key
                          ; "path", Y.string "ca.crt"
                          ]
                      ] )
                ] )
          ]
      ]
    else []
  in
  let db_ca_volumes =
    match db_ca_configmap with
    | None -> []
    | Some configmap ->
      [ Y.map
          [ "name", Y.string db_ca_volume
          ; "configMap", Y.map [ "name", Y.string configmap ]
          ]
      ]
  in
  let kafka_ca_mount =
    if kafka_tls
    then
      [ Y.map
          [ "name", Y.string kafka_ca_volume
          ; "mountPath", Y.string kafka_ca_mount_path
          ; "readOnly", Y.bool true
          ]
      ]
    else []
  in
  (* 2d: the database CA. Mounted only by units that consume the Sol-provisioned database,
     because only their namespaces hold the ConfigMap the deploy writes. **Prep**: the
     anchor is inert until 2b points the unit at its already-parameterized class Secret. *)
  let db_ca_mount =
    match db_ca_configmap with
    | None -> []
    | Some _ ->
      [ Y.map
          [ "name", Y.string db_ca_volume
          ; "mountPath", Y.string db_ca_mount_path
          ; "readOnly", Y.bool true
          ]
      ]
  in
  let container =
    Y.map
      ([ "name", Y.string (workload_container_name name)
       ; "image", Y.string image
       ; "imagePullPolicy", Y.string "Always"
       ; "securityContext", container_security
       ; "ports", Y.list [ Y.map [ "containerPort", Y.int port ] ]
       ]
       @ non_empty_list
           "volumeMounts"
           (volume_mounts @ projected_identity_mounts @ kafka_ca_mount @ db_ca_mount)
       @ non_empty_list
           "env"
           (secret_key_refs ~name ~secret_sources ~db_dml_creds_name secret_keys)
       @ [ "envFrom", env_from ~name; "resources", resources ~cpu ~memory ]
       @ probes ~shape ~consumes_kafka ~readiness_path)
  in
  Y.map
    [ "metadata", Y.map [ "labels", Y.map labels; "annotations", annotations ]
    ; ( "spec"
      , Y.map
          ([ "serviceAccountName", Y.string name
           ; "securityContext", non_root_pod_security
           ; "terminationGracePeriodSeconds", Y.int default_termination_grace_seconds
           ]
           @ spread
           @ non_empty_list
               "volumes"
               (pod_volumes
                @ projected_identity_volumes
                @ kafka_ca_volumes
                @ db_ca_volumes)
           @ [ "containers", Y.list [ container ] ]) )
    ]
;;

let deployment_doc ?(rollout_strategy = Sol_cli_toml.RollingUpdate) ~workload () =
  let { Workload_spec.replicas; ns; name; _ } = workload in
  let strategy_type =
    match rollout_strategy with
    | Sol_cli_toml.Recreate -> "Recreate"
    | Sol_cli_toml.RollingUpdate -> "RollingUpdate"
  in
  resource
    ~api_version:"apps/v1"
    ~kind:"Deployment"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "replicas", Y.int replicas
          ; "strategy", Y.map [ "type", Y.string strategy_type ]
          ; "selector", Y.map [ "matchLabels", app_selector name ]
          ; "template", pod_template workload
          ] )
    ]
;;

let pdb_doc ~ns ~name ~replicas =
  resource
    ~api_version:"policy/v1"
    ~kind:"PodDisruptionBudget"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "minAvailable", Y.int (max 1 (replicas - 1))
          ; "selector", Y.map [ "matchLabels", app_selector name ]
          ] )
    ]
;;

let canary_step = function
  | Sol_cli_toml.Weight n -> Y.map [ "setWeight", Y.int n ]
  | Sol_cli_toml.Pause None -> Y.map [ "pause", Y.map [] ]
  | Sol_cli_toml.Pause (Some d) -> Y.map [ "pause", Y.map [ "duration", Y.int d ] ]
;;

let rollout_strategy ~name = function
  | Sol_cli_toml.Canary { steps } ->
    Y.map [ "canary", Y.map [ "steps", Y.list (List.map canary_step steps) ] ]
  | Sol_cli_toml.Blue_green ->
    Y.map
      [ ( "blueGreen"
        , Y.map
            [ "activeService", Y.string (name ^ "-active")
            ; "previewService", Y.string (name ^ "-preview")
            ; "autoPromotionEnabled", Y.bool false
            ] )
      ]
;;

let rollout_doc ~workload ~pd () =
  let { Workload_spec.replicas; ns; name; _ } = workload in
  resource
    ~api_version:"argoproj.io/v1alpha1"
    ~kind:"Rollout"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "replicas", Y.int replicas
          ; "selector", Y.map [ "matchLabels", app_selector name ]
          ; "template", pod_template workload
          ; "strategy", rollout_strategy ~name pd
          ] )
    ]
;;

let service_doc ~ns ~name =
  resource
    ~api_version:"v1"
    ~kind:"Service"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "type", Y.string "ClusterIP"
          ; "selector", app_selector name
          ; "ports", Y.list [ Y.map [ "port", Y.int 80; "targetPort", Y.int 8080 ] ]
          ] )
    ]
;;

let blue_green_service_docs ~ns ~name =
  let service suffix =
    resource
      ~api_version:"v1"
      ~kind:"Service"
      [ "metadata", metadata ~ns ~name:(name ^ suffix)
      ; ( "spec"
        , Y.map
            [ "type", Y.string "ClusterIP"
            ; "selector", app_selector name
            ; "ports", Y.list [ Y.map [ "port", Y.int 80; "targetPort", Y.int 8080 ] ]
            ] )
      ]
  in
  [ service "-active"; service "-preview" ]
;;

let ingress_doc
      ?ingress_host
      ?(ingress_path = "/")
      ?(cluster_issuer = "letsencrypt-prod")
      ?tls_secret_name
      ~ns
      ~name
      ()
  =
  let host =
    match ingress_host with
    | Some host -> host
    | None -> Printf.sprintf "%s.%s.localhost" name ns
  in
  let annotations, tls =
    match ingress_host with
    | None -> [], []
    | Some host ->
      let secret_name = Option.value tls_secret_name ~default:(name ^ "-tls") in
      ( [ ( "annotations"
          , Y.map
              [ "cert-manager.io/cluster-issuer", Y.string cluster_issuer
              ; "nginx.ingress.kubernetes.io/ssl-redirect", Y.quoted "true"
              ] )
        ]
      , [ ( "tls"
          , Y.list
              [ Y.map
                  [ "hosts", Y.list [ Y.string host ]
                  ; "secretName", Y.string secret_name
                  ]
              ] )
        ] )
  in
  let rule =
    Y.map
      [ "host", Y.string host
      ; ( "http"
        , Y.map
            [ ( "paths"
              , Y.list
                  [ Y.map
                      [ "path", Y.string ingress_path
                      ; "pathType", Y.string "Prefix"
                      ; ( "backend"
                        , Y.map
                            [ ( "service"
                              , Y.map
                                  [ "name", Y.string name
                                  ; "port", Y.map [ "number", Y.int 80 ]
                                  ] )
                            ] )
                      ]
                  ] )
            ] )
      ]
  in
  resource
    ~api_version:"networking.k8s.io/v1"
    ~kind:"Ingress"
    [ "metadata", Y.map ([ "name", Y.string name; "namespace", Y.string ns ] @ annotations)
    ; ( "spec"
      , Y.map
          ([ "ingressClassName", Y.string "nginx" ] @ tls @ [ "rules", Y.list [ rule ] ])
      )
    ]
;;

let namespace_selector ns =
  Y.map
    [ ( "namespaceSelector"
      , Y.map [ "matchLabels", Y.map [ "kubernetes.io/metadata.name", Y.string ns ] ] )
    ]
;;

let peer ~ns ~name =
  Y.map
    [ ( "namespaceSelector"
      , Y.map [ "matchLabels", Y.map [ "kubernetes.io/metadata.name", Y.string ns ] ] )
    ; "podSelector", Y.map [ "matchLabels", app_selector name ]
    ]
;;

let managed_database_egress_doc ~cidrs ~port ~ns ~name =
  let destination cidr = Y.map [ "ipBlock", Y.map [ "cidr", Y.string cidr ] ] in
  resource
    ~api_version:"networking.k8s.io/v1"
    ~kind:"NetworkPolicy"
    [ "metadata", metadata ~ns ~name:(name ^ "-managed-database-egress")
    ; ( "spec"
      , Y.map
          [ "podSelector", Y.map [ "matchLabels", app_selector name ]
          ; "policyTypes", Y.list [ Y.string "Egress" ]
          ; ( "egress"
            , Y.list
                [ Y.map
                    [ "to", Y.list (List.map destination cidrs)
                    ; ( "ports"
                      , Y.list
                          [ Y.map [ "port", Y.int port; "protocol", Y.string "TCP" ] ] )
                    ]
                ] )
          ] )
    ]
;;

let network_policy_doc ?(egress_to = []) ?(ingress_from = []) ~ns ~name () =
  let platform_ingress =
    Y.map
      [ ( "from"
        , Y.list
            [ namespace_selector "ingress-nginx"
            ; namespace_selector Sol_cli_manifest_cluster_env.monitoring_namespace
            ; Y.map [ "podSelector", Y.map [] ]
            ] )
      ]
  in
  let caller_ingress (from_ns, from_name) =
    Y.map
      [ "from", Y.list [ peer ~ns:from_ns ~name:from_name ]
      ; "ports", Y.list [ Y.map [ "port", Y.int 8080 ] ]
      ]
  in
  let dns_egress =
    Y.map
      [ ( "ports"
        , Y.list
            [ Y.map [ "port", Y.int 53; "protocol", Y.string "UDP" ]
            ; Y.map [ "port", Y.int 53; "protocol", Y.string "TCP" ]
            ] )
      ]
  in
  let platform_egress =
    Y.map
      [ ( "to"
        , Y.list
            [ namespace_selector "redpanda"
            ; namespace_selector "postgresql"
            ; namespace_selector Sol_cli_manifest_cluster_env.monitoring_namespace
            ] )
      ]
  in
  let callee_egress (to_ns, to_name) =
    Y.map [ "to", Y.list [ peer ~ns:to_ns ~name:to_name ] ]
  in
  resource
    ~api_version:"networking.k8s.io/v1"
    ~kind:"NetworkPolicy"
    [ "metadata", metadata ~ns ~name:(name ^ "-netpol")
    ; ( "spec"
      , Y.map
          [ "podSelector", Y.map [ "matchLabels", app_selector name ]
          ; "policyTypes", Y.list [ Y.string "Ingress"; Y.string "Egress" ]
          ; "ingress", Y.list (platform_ingress :: List.map caller_ingress ingress_from)
          ; ( "egress"
            , Y.list (dns_egress :: platform_egress :: List.map callee_egress egress_to) )
          ] )
    ]
;;

module Scheduled_workload_spec = struct
  type t =
    { ns : string
    ; name : string
    ; image : string
    ; secret_keys : string list
    ; secret_sources : (string * secret_source) list
    ; projected_identities : Sol_cli_identity_projection.t list
    ; env : string option
    ; schedule : string
    ; concurrency_policy : string
    ; backoff_limit : int
    ; cpu : string
    ; memory : string
    ; kafka_tls : bool
    ; workspace : string
    ; domain : string
    ; release_id : Sol_cli_release_id.t
    ; (* 2d: see {!Workload_spec.db_ca_configmap}; a scheduled unit consumes the database
         the same way a service does. *)
      db_ca_configmap : string option
    ; (* 2b: see {!Workload_spec.db_dml_creds_name}. *)
      db_dml_creds_name : string option
    }
end

let cronjob_doc (workload : Scheduled_workload_spec.t) =
  let open Scheduled_workload_spec in
  let { ns
      ; name
      ; image
      ; secret_keys
      ; secret_sources
      ; projected_identities
      ; env
      ; schedule
      ; concurrency_policy
      ; backoff_limit
      ; cpu
      ; memory
      ; kafka_tls
      ; workspace
      ; domain
      ; release_id
      ; db_ca_configmap
      ; db_dml_creds_name
      }
    =
    workload
  in
  let labels =
    ("app", Y.string name)
    :: (taxonomy_labels
          ?env
          ~workspace
          ~domain
          ~service:name
          ~primitive:"fn"
          ~release_id
          ()
        |> List.map (fun (k, v) -> k, Y.quoted v))
  in
  let projected_identity_mounts =
    projected_identities
    |> List.map (fun (p : Sol_cli_identity_projection.t) ->
      Y.map
        [ "name", Y.string p.volume_name
        ; "mountPath", Y.string p.mount_path
        ; "readOnly", Y.bool true
        ])
  in
  let projected_identity_volumes =
    projected_identities
    |> List.map (fun (p : Sol_cli_identity_projection.t) ->
      Y.map
        [ "name", Y.string p.volume_name
        ; ( "projected"
          , Y.map
              [ ( "sources"
                , Y.list
                    [ Y.map
                        [ ( "serviceAccountToken"
                          , Y.map
                              [ "audience", Y.string p.audience
                              ; "expirationSeconds", Y.int 3600
                              ; "path", Y.string "token"
                              ] )
                        ]
                    ] )
              ] )
        ])
  in
  let kafka_ca_mounts =
    if kafka_tls
    then
      [ Y.map
          [ "name", Y.string kafka_ca_volume
          ; "mountPath", Y.string kafka_ca_mount_path
          ; "readOnly", Y.bool true
          ]
      ]
    else []
  in
  let db_ca_mounts =
    match db_ca_configmap with
    | None -> []
    | Some _ ->
      [ Y.map
          [ "name", Y.string db_ca_volume
          ; "mountPath", Y.string db_ca_mount_path
          ; "readOnly", Y.bool true
          ]
      ]
  in
  let kafka_ca =
    match kafka_ca_mounts @ db_ca_mounts @ projected_identity_mounts with
    | [] -> []
    | mounts -> [ "volumeMounts", Y.list mounts ]
  in
  let kafka_ca_volume_items =
    if kafka_tls
    then
      [ Y.map
          [ "name", Y.string kafka_ca_volume
          ; ( "secret"
            , Y.map
                [ ( "secretName"
                  , Y.string
                      (secret_name_for_key
                         ~name
                         ~secret_sources
                         ~db_dml_creds_name
                         kafka_ca_secret_key) )
                ; ( "items"
                  , Y.list
                      [ Y.map
                          [ "key", Y.string kafka_ca_secret_key
                          ; "path", Y.string "ca.crt"
                          ]
                      ] )
                ] )
          ]
      ]
    else []
  in
  let db_ca_volume_items =
    match db_ca_configmap with
    | None -> []
    | Some configmap ->
      [ Y.map
          [ "name", Y.string db_ca_volume
          ; "configMap", Y.map [ "name", Y.string configmap ]
          ]
      ]
  in
  let kafka_ca_volumes =
    match kafka_ca_volume_items @ db_ca_volume_items @ projected_identity_volumes with
    | [] -> []
    | volumes -> [ "volumes", Y.list volumes ]
  in
  let container =
    Y.map
      ([ "name", Y.string (workload_container_name name)
       ; "image", Y.string image
       ; "imagePullPolicy", Y.string "Always"
       ; "securityContext", container_security
       ]
       @ non_empty_list
           "env"
           (secret_key_refs ~name ~secret_sources ~db_dml_creds_name secret_keys)
       @ [ "envFrom", env_from ~name; "resources", resources ~cpu ~memory ]
       @ kafka_ca)
  in
  let pod_metadata =
    match secret_keys with
    | [] -> Y.map [ "labels", Y.map labels ]
    | keys ->
      Y.map
        [ "labels", Y.map labels
        ; ( "annotations"
          , quoted_map
              [ ( Sol_cli_grant.annotation_key
                , Sol_cli_grant.encode_tags
                    (List.map Sol_cli_grant.tag_of_secret_key keys) )
              ] )
        ]
  in
  resource
    ~api_version:"batch/v1"
    ~kind:"CronJob"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "schedule", Y.quoted schedule
          ; "concurrencyPolicy", Y.string concurrency_policy
          ; ( "jobTemplate"
            , Y.map
                [ ( "spec"
                  , Y.map
                      [ "backoffLimit", Y.int backoff_limit
                      ; ( "template"
                        , Y.map
                            [ "metadata", pod_metadata
                            ; ( "spec"
                              , Y.map
                                  ([ "serviceAccountName", Y.string name
                                   ; "restartPolicy", Y.string "OnFailure"
                                   ; "securityContext", non_root_pod_security
                                   ]
                                   @ kafka_ca_volumes
                                   @ [ "containers", Y.list [ container ] ]) )
                            ] )
                      ] )
                ] )
          ] )
    ]
;;

let migration_configmap_doc ~name ~namespace files =
  resource
    ~api_version:"v1"
    ~kind:"ConfigMap"
    [ "metadata", metadata ~ns:namespace ~name; "data", quoted_map files ]
;;

(* 2b: the migration Job is a DDL consumer, so its `POSTGRES_URL` comes from
   `<target>-ddl-creds`, never the workspace's `sol-secrets`. The reader asks for the class
   Secret by name and never learns the database's ownership: a Sol-provisioned target's
   setup step writes it, an externally bound target's ESO ExternalSecret does.

   The DDL URL carries `sslrootcert`, so a Sol-provisioned target's Job also mounts
   `<target>-db-ca` at the same path the setup Job and the workloads use. [ca_configmap] is
   [None] for an externally bound database, which publishes no Sol CA ConfigMap — mounting
   one that does not exist would leave the Job unstartable. *)
let migration_job_doc
      ~name
      ~namespace
      ~image
      ~args
      ~configmap_name
      ~ddl_creds_name
      ?ca_configmap
      ()
  =
  let db_ca_volume_items =
    match ca_configmap with
    | None -> []
    | Some configmap ->
      [ Y.map
          [ "name", Y.string db_ca_volume
          ; "configMap", Y.map [ "name", Y.string configmap ]
          ]
      ]
  in
  let db_ca_mounts =
    match ca_configmap with
    | None -> []
    | Some _ ->
      [ Y.map
          [ "name", Y.string db_ca_volume
          ; "mountPath", Y.string db_ca_mount_path
          ; "readOnly", Y.bool true
          ]
      ]
  in
  let container =
    Y.map
      [ "name", Y.string migration_container_name
      ; "image", Y.string image
      ; "args", Y.list (List.map Y.quoted args)
      ; ( "envFrom"
        , Y.list [ Y.map [ "secretRef", Y.map [ "name", Y.string ddl_creds_name ] ] ] )
      ; ( "volumeMounts"
        , Y.list
            (Y.map [ "name", Y.string "migrations"; "mountPath", Y.string "/migrations" ]
             :: db_ca_mounts) )
      ]
  in
  resource
    ~api_version:"batch/v1"
    ~kind:"Job"
    [ "metadata", metadata ~ns:namespace ~name
    ; ( "spec"
      , Y.map
          [ "backoffLimit", Y.int 0
          ; ( "template"
            , Y.map
                [ ( "spec"
                  , Y.map
                      [ "restartPolicy", Y.string "Never"
                      ; "containers", Y.list [ container ]
                      ; ( "volumes"
                        , Y.list
                            (Y.map
                               [ "name", Y.string "migrations"
                               ; "configMap", Y.map [ "name", Y.string configmap_name ]
                               ]
                             :: db_ca_volume_items) )
                      ] )
                ] )
          ] )
    ]
;;

let contract_job_doc ~cluster_env ~name ~namespace ~image ~command ~args =
  let kafka_tls = kafka_tls (kafka_transport_of_config cluster_env) in
  let env =
    List.map
      (fun (key, value) -> Y.map [ "name", Y.string key; "value", Y.string value ])
      cluster_env
  in
  let kafka_ca_mounts =
    if kafka_tls
    then
      [ Y.map
          [ "name", Y.string kafka_ca_volume
          ; "mountPath", Y.string kafka_ca_mount_path
          ; "readOnly", Y.bool true
          ]
      ]
    else []
  in
  let kafka_ca_volumes =
    if kafka_tls
    then
      [ Y.map
          [ "name", Y.string kafka_ca_volume
          ; ( "secret"
            , Y.map
                [ "secretName", Y.string runtime_secret_name
                ; ( "items"
                  , Y.list
                      [ Y.map
                          [ "key", Y.string kafka_ca_secret_key
                          ; "path", Y.string "ca.crt"
                          ]
                      ] )
                ] )
          ]
      ]
    else []
  in
  let env_from =
    if kafka_tls
    then
      [ ( "envFrom"
        , Y.list [ Y.map [ "secretRef", Y.map [ "name", Y.string runtime_secret_name ] ] ]
        )
      ]
    else []
  in
  let container =
    Y.map
      ([ "name", Y.string "contract"
       ; "image", Y.string image
       ; "command", Y.list (List.map Y.quoted command)
       ; "args", Y.list (List.map Y.quoted args)
       ; "env", Y.list env
       ]
       @ env_from
       @ non_empty_list "volumeMounts" kafka_ca_mounts)
  in
  resource
    ~api_version:"batch/v1"
    ~kind:"Job"
    [ "metadata", metadata ~ns:namespace ~name
    ; ( "spec"
      , Y.map
          [ "backoffLimit", Y.int 0
          ; ( "template"
            , Y.map
                [ ( "spec"
                  , Y.map
                      ([ "restartPolicy", Y.string "Never" ]
                       @ non_empty_list "volumes" kafka_ca_volumes
                       @ [ "containers", Y.list [ container ] ]) )
                ] )
          ] )
    ]
;;
