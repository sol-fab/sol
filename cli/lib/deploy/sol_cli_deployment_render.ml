type common_fields =
  { namespace : Sol_cli_kubernetes_name.namespace
  ; k8s_name : Sol_cli_kubernetes_name.k8s_name
  ; domain : string
  ; primitive : string
  ; spec_image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; secret_sources : (string * Sol_cli_secret_source.t) list
  ; calls : Sol_cli_deployment_plan.service_call list
  ; called_by : Sol_cli_deployment_plan.service_call list
  ; (* 2b: the `<target>-dml-creds` Secret this unit reads `POSTGRES_URL` from, derived from
       the plan's [db_uses_target] by {!Sol_cli_database_setup_render.dml_creds_name} — the
       one definition the Sol writer, the external writer and the reader share. [None] when
       the unit does not consume the target's database, so a unit that merely declares
       `POSTGRES_URL` keeps reading its own Secret. *)
    db_dml_creds_name : string option
  ; (* 2d: the database-CA ConfigMap this unit mounts, derived from the plan's
       [db_ca_target] by {!Sol_cli_database_setup_render.ca_configmap_name} — the one
       definition the deploy writes with. *)
    db_ca_configmap : string option
  }

type deployment_fields =
  { replicas : int
  ; cpu : Sol_cli_toml.cpu_quantity
  ; memory : Sol_cli_toml.memory_quantity
  ; rollout_strategy : Sol_cli_toml.rollout_strategy option
  ; extra_labels : (string * string) list
  ; progressive_delivery : Sol_cli_toml.progressive_delivery option
  ; volumes : Sol_cli_toml.volume list
  ; availability : Sol_cli_availability.t
  ; consumes_kafka : bool
  ; readiness_path : string
  }

type http_fields =
  { deployment : deployment_fields
  ; ingress_host : Sol_cli_toml.hostname option
  ; ingress_path : Sol_cli_toml.ingress_path option
  ; cluster_issuer : string
  }

type worker_fields = { deployment : deployment_fields }

type fn_fields =
  { schedule : string
  ; cpu : Sol_cli_toml.cpu_quantity
  ; memory : Sol_cli_toml.memory_quantity
  ; scheduled_concurrency : Sol_cli_toml.scheduled_concurrency
  ; backoff_limit : int
  }

type render_workload =
  | Render_svc of http_fields
  | Render_worker of worker_fields
  | Render_fn of fn_fields

type render_spec_t =
  { common : common_fields
  ; workload : render_workload
  }

let render ~workspace ?env ?(image = "") ~release_id { common; workload } =
  let { namespace
      ; k8s_name
      ; domain
      ; primitive
      ; spec_image
      ; config
      ; secrets
      ; secret_sources
      ; calls
      ; called_by
      ; db_dml_creds_name
      ; db_ca_configmap
      }
    =
    common
  in
  let ns = Sol_cli_kubernetes_name.namespace_to_string namespace in
  let name = Sol_cli_kubernetes_name.k8s_name_to_string k8s_name in
  let img = if image = "" then spec_image else image in
  let identity =
    Sol_cli_manifest.identity_env
      ?env
      ~release:release_id
      ~workspace
      ~domain
      ~service:name
      ~primitive
      ()
  in
  (* The callee's own unit and the callers declared for it (DEC-063). Derived
     from the committed declaration, never from user config: a workload cannot
     spoof its audience or widen its called_by set. *)
  let identity =
    (("SOL_UNIT", domain ^ "/" ^ name)
     ::
     (match called_by with
      | [] -> []
      | callers ->
        [ ( "SOL_CALLED_BY"
          , callers
            |> List.map (fun (c : Sol_cli_deployment_plan.service_call) ->
              Printf.sprintf
                "%s=%s:%s"
                c.unit_id
                (Sol_cli_kubernetes_name.namespace_to_string c.target_namespace)
                (Sol_cli_kubernetes_name.k8s_name_to_string c.target_name))
            |> String.concat "," )
        ]))
    @ identity
  in
  let reserved = List.map fst identity in
  let config =
    identity @ List.filter (fun (key, _) -> not (List.mem key reserved)) config
  in
  let config =
    match primitive with
    | "fn" ->
      let key = "SOL_PUSHGATEWAY_JOB" in
      (key, ns ^ "." ^ name) :: List.filter (fun (k, _) -> k <> key) config
    | _ -> config
  in
  (* The projected-token file path is part of the workload's environment and is
     derived from the same declared calls as the projected volume, so the env
     and the mount can never name different files. *)
  let config =
    List.map
      (fun (c : Sol_cli_deployment_plan.service_call) ->
         Sol_cli_deployment_plan.identity_env c)
      calls
    @ config
  in
  let transport = Sol_cli_manifest.kafka_transport_of_config config in
  let base_cluster_env = Sol_cli_manifest.cluster_env Sol_cli_manifest.Plaintext in
  let cfg_hash = Sol_cli_manifest.config_hash base_cluster_env config in
  let kafka_tls_enabled = Sol_cli_manifest.kafka_tls transport in
  let secret_keys =
    Sol_cli_manifest.required_secret_keys
      ~transport
      ?db_dml_creds_name
      (List.map fst secrets)
  in
  Sol_cli_manifest.(
    let ns_yaml = namespace_doc ~ns in
    let external_secret_resource =
      secret_sources
      |> List.filter_map (fun (key, source) ->
        match source with
        | Sol_cli_manifest.Sol_managed -> None
        | External { store; key = remote_key } -> Some (key, store, remote_key))
      |> function
      | [] -> None
      | secret_refs -> Some (external_secret_doc ~secret_refs ~ns ~name)
    in
    Result.map
      (fun () ->
         let common_resources =
           [ service_account_doc ~ns ~name
           ; configmap_doc ~cluster_env:base_cluster_env ~extra_env:config ~ns ~name ()
           ]
           @ Option.to_list external_secret_resource
           @ [ network_policy_doc
                 ~egress_to:
                   (calls
                    |> List.map (fun (c : Sol_cli_deployment_plan.service_call) ->
                      ( Sol_cli_kubernetes_name.namespace_to_string c.target_namespace
                      , Sol_cli_kubernetes_name.k8s_name_to_string c.target_name )))
                 ~ingress_from:
                   (called_by
                    |> List.map (fun (c : Sol_cli_deployment_plan.service_call) ->
                      ( Sol_cli_kubernetes_name.namespace_to_string c.target_namespace
                      , Sol_cli_kubernetes_name.k8s_name_to_string c.target_name )))
                 ~ns
                 ~name
                 ()
             ]
         in
         let deployment_resources
               ~shape
               ~ingress_host
               ~ingress_path
               ~cluster_issuer
               ~deployment
           =
           let { replicas
               ; cpu
               ; memory
               ; rollout_strategy
               ; extra_labels
               ; progressive_delivery
               ; volumes
               ; availability
               ; consumes_kafka
               ; readiness_path
               }
             =
             deployment
           in
           let cpu = Sol_cli_toml.cpu_quantity_to_string cpu in
           let memory = Sol_cli_toml.memory_quantity_to_string memory in
           let workload : Sol_cli_manifest.Workload_spec.t =
             { Sol_cli_manifest.Workload_spec.extra_labels
             ; secret_keys
             ; secret_sources
             ; volumes
             ; projected_identities = Sol_cli_deployment_plan.identity_projections calls
             ; env
             ; config_hash = cfg_hash
             ; availability
             ; consumes_kafka
             ; kafka_tls = kafka_tls_enabled
             ; readiness_path
             ; shape
             ; replicas
             ; cpu
             ; memory
             ; ns
             ; name
             ; image = img
             ; workspace
             ; domain
             ; primitive
             ; release_id
             ; db_dml_creds_name
             ; db_ca_configmap
             }
           in
           let workload_resources =
             match progressive_delivery with
             | Some pd ->
               let rollout = rollout_doc ~workload ~pd () in
               (match pd with
                | Sol_cli_toml.Blue_green ->
                  let ingress =
                    if shape = Http_service
                    then
                      [ ingress_doc
                          ?ingress_host
                          ~ingress_path
                          ~cluster_issuer
                          ~tls_secret_name:(name ^ "-tls")
                          ~ns
                          ~name:(name ^ "-active")
                          ()
                      ]
                    else []
                  in
                  (rollout :: blue_green_service_docs ~ns ~name) @ ingress
                | Sol_cli_toml.Canary _ ->
                  let svc =
                    if shape = Http_service then [ service_doc ~ns ~name ] else []
                  in
                  let ingr =
                    if shape = Http_service
                    then
                      [ ingress_doc
                          ?ingress_host
                          ~ingress_path
                          ~cluster_issuer
                          ~ns
                          ~name
                          ()
                      ]
                    else []
                  in
                  [ rollout ] @ svc @ ingr)
             | None ->
               let rollout_strategy =
                 Option.value rollout_strategy ~default:Sol_cli_toml.RollingUpdate
               in
               [ deployment_doc ~rollout_strategy ~workload () ]
           in
           let pdb =
             if Sol_cli_availability.is_node_failure_tolerant availability
             then [ Sol_cli_manifest_yaml.pdb_doc ~ns ~name ~replicas ]
             else []
           in
           let pvcs = pvc_docs ~ns ~name volumes in
           pvcs @ pdb @ workload_resources
         in
         let resources =
           match workload with
           | Render_svc { deployment; ingress_host; ingress_path; cluster_issuer } ->
             let ingress_host = Option.map Sol_cli_toml.hostname_to_string ingress_host in
             let ingress_path =
               match ingress_path with
               | Some path -> Sol_cli_toml.ingress_path_to_string path
               | None -> "/"
             in
             let resources =
               deployment_resources
                 ~shape:Http_service
                 ~ingress_host
                 ~ingress_path
                 ~cluster_issuer
                 ~deployment
             in
             (match deployment.progressive_delivery with
              | Some _ -> resources
              | None ->
                resources
                @ [ service_doc ~ns ~name
                  ; ingress_doc ?ingress_host ~ingress_path ~cluster_issuer ~ns ~name ()
                  ])
           | Render_worker { deployment } ->
             deployment_resources
               ~shape:Background_worker
               ~ingress_host:None
               ~ingress_path:"/"
               ~cluster_issuer:"letsencrypt-prod"
               ~deployment
           | Render_fn { schedule; cpu; memory; scheduled_concurrency; backoff_limit } ->
             let concurrency_policy =
               match scheduled_concurrency with
               | Sol_cli_toml.Allow -> "Allow"
               | Sol_cli_toml.Forbid -> "Forbid"
               | Sol_cli_toml.Replace -> "Replace"
             in
             let workload : Scheduled_workload_spec.t =
               { secret_keys
               ; secret_sources
               ; projected_identities = Sol_cli_deployment_plan.identity_projections calls
               ; env
               ; ns
               ; name
               ; image = img
               ; schedule
               ; concurrency_policy
               ; backoff_limit
               ; cpu = Sol_cli_toml.cpu_quantity_to_string cpu
               ; memory = Sol_cli_toml.memory_quantity_to_string memory
               ; kafka_tls = kafka_tls_enabled
               ; workspace
               ; domain
               ; release_id
               ; db_dml_creds_name
               ; db_ca_configmap
               }
             in
             [ cronjob_doc workload ]
         in
         { Sol_cli_manifest.namespace_yaml = Sol_cli_yaml.render [ ns_yaml ]
         ; prerequisites_yaml = Sol_cli_yaml.render common_resources
         ; workload_yaml = Sol_cli_yaml.render resources
         })
      (Ok ()))
;;

let render_spec
      ~workspace
      ?env
      ?(image = "")
      ~release_id
      (s : Sol_cli_deployment_plan.service_spec)
  =
  let primitive =
    match s.primitive with
    | Sol_cli_deployment_plan.Svc -> "svc"
    | Sol_cli_deployment_plan.Worker -> "worker"
    | Sol_cli_deployment_plan.Fn -> "fn"
  in
  let common =
    { namespace = s.namespace
    ; k8s_name = s.k8s_name
    ; domain = s.domain
    ; primitive
    ; spec_image = s.image
    ; config = s.config
    ; secrets = s.secrets
    ; secret_sources = s.secret_sources
    ; calls = s.calls
    ; called_by = s.called_by
    ; db_dml_creds_name =
        Option.map Sol_cli_database_setup_render.dml_creds_name s.db_uses_target
    ; db_ca_configmap =
        Option.map Sol_cli_database_setup_render.ca_configmap_name s.db_ca_target
    }
  in
  let deployment =
    { replicas = s.replicas
    ; cpu = s.cpu
    ; memory = s.memory
    ; rollout_strategy = s.rollout_strategy
    ; extra_labels = s.extra_labels
    ; progressive_delivery = s.progressive_delivery
    ; volumes = s.volumes
    ; availability = s.availability
    ; consumes_kafka = s.consumes_kafka
    ; readiness_path =
        (match s.language with
         | Some (Sol_cli_compat.Ocaml | Sol_cli_compat.Typescript) -> "/readyz"
         | None -> "/healthz")
    }
  in
  let workload =
    match s.primitive with
    | Svc ->
      Ok
        (Render_svc
           { deployment
           ; ingress_host = s.ingress_host
           ; ingress_path = s.ingress_path
           ; cluster_issuer = s.cluster_issuer
           })
    | Worker -> Ok (Render_worker { deployment })
    | Fn ->
      (match s.schedule with
       | Some schedule ->
         Ok
           (Render_fn
              { schedule
              ; cpu = s.cpu
              ; memory = s.memory
              ; scheduled_concurrency = s.scheduled_concurrency
              ; backoff_limit = s.backoff_limit
              })
       | None ->
         Error
           (Printf.sprintf
              "the -fn %s has no schedule; set [service] schedule in its sol.toml"
              (Sol_cli_kubernetes_name.k8s_name_to_string s.k8s_name)))
  in
  Result.bind workload (fun workload ->
    render ~workspace ?env ~image ~release_id { common; workload })
;;
