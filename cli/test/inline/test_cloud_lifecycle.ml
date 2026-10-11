module L = Sol_cli_cloud_lifecycle

let provider = Sol_cli_provider.Aws

let target : Sol_cli_config.target =
  { name = "prod/aws/us-east-1"
  ; env = "prod"
  ; provider
  ; region = "us-east-1"
  ; registry = None
  ; base_domain = Some "acme.example"
  ; cluster_issuer = Some "letsencrypt-prod"
  ; letsencrypt_email = Some "ops@example.test"
  ; cluster_name = Some "acme-prod"
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = Some "self_hosted_durable"
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = Some "acme-state"
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; provider_fields =
      [ ( "aws"
        , [ "state_lock_table", "acme-lock"
          ; "provisioner_role_arn", "arn:aws:iam::1:role/provisioner"
          ; "cluster_access_role_arn", "arn:aws:iam::1:role/cluster-access"
          ] )
      ]
  ; secret_authorities = []
  }
;;

let without_aws_field key (t : Sol_cli_config.target) =
  { t with
    provider_fields =
      t.provider_fields
      |> List.map (fun (provider, fields) ->
        if provider = "aws"
        then provider, List.remove_assoc key fields
        else provider, fields)
  }
;;

let output ?(value = `String "x") name =
  name, `Assoc [ "sensitive", `Bool false; "value", value ]
;;

let valid_outputs () =
  `Assoc
    [ output "cluster_name" ~value:(`String "acme-prod")
    ; output "kubeconfig_command"
    ; output
        "cluster_access_role_arn"
        ~value:(`String "arn:aws:iam::1:role/cluster-access")
    ; output "cert_manager_irsa_arn" ~value:(`String "arn:aws:iam::1:role/cert-manager")
    ; output "loki_s3_bucket" ~value:(`String "loki")
    ; output "loki_irsa_arn" ~value:(`String "loki-role")
    ; output "thanos_s3_bucket" ~value:(`String "thanos")
    ; output "thanos_irsa_arn" ~value:(`String "thanos-role")
    ; output "grafana_irsa_arn" ~value:`Null
    ; output "managed_resource_dashboards" ~value:(`Assoc [])
    ; output "database_egress_cidrs" ~value:(`List [ `String "10.0.0.0/16" ])
    ]
;;

let parse json = Sol_cli_aws_cluster.aws_outputs_of_json (Yojson.Safe.to_string json)

(* The provisioning output the database setup step consumes. No code read this output
   before 2c, so this is the first assertion that it is read at all, and that a target
   which provisions no database reports none rather than an empty string. *)
let test_postgres_url_output () =
  let with_url value =
    match valid_outputs () with
    | `Assoc fields -> `Assoc (fields @ [ output "postgres_url" ~value ])
    | _ -> assert false
  in
  (match
     parse (with_url (`String "postgresql://postgres:master@db.internal:5432/app"))
   with
   | Error message -> Windtrap.fail message
   | Ok outputs ->
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"the provisioning connection is read"
       (Some "postgresql://postgres:master@db.internal:5432/app")
       outputs.postgres_url);
  match parse (with_url `Null) with
  | Error message -> Windtrap.fail message
  | Ok outputs ->
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"a target that provisions no database reports none"
      None
      outputs.postgres_url
;;

let%test
    "postgres_url: the provisioning connection is read, and absence is not a blank string"
  =
  test_postgres_url_output ()
;;

let test_outputs () =
  (match parse (valid_outputs ()) with
   | Ok _ -> ()
   | Error message -> Windtrap.fail message);
  let missing =
    match valid_outputs () with
    | `Assoc fields -> `Assoc (List.remove_assoc "cluster_name" fields)
    | _ -> assert false
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"missing required"
    true
    (Result.is_error (parse missing));
  let wrong =
    match valid_outputs () with
    | `Assoc fields ->
      `Assoc
        (("cluster_name", `Assoc [ "value", `Int 1 ])
         :: List.remove_assoc "cluster_name" fields)
    | _ -> assert false
  in
  Windtrap.equal Windtrap.bool ~msg:"wrong type" true (Result.is_error (parse wrong))
;;

let test_outputs_absent_optional () =
  let optional =
    [ "loki_s3_bucket"
    ; "loki_irsa_arn"
    ; "thanos_s3_bucket"
    ; "thanos_irsa_arn"
    ; "grafana_irsa_arn"
    ]
  in
  let without_optional =
    match valid_outputs () with
    | `Assoc fields ->
      `Assoc (List.filter (fun (k, _) -> not (List.mem k optional)) fields)
    | _ -> assert false
  in
  (match parse without_optional with
   | Ok _ -> ()
   | Error message ->
     Windtrap.fail ("absent optional outputs must parse, not crash: " ^ message));
  let without_required =
    match without_optional with
    | `Assoc fields -> `Assoc (List.remove_assoc "cert_manager_irsa_arn" fields)
    | _ -> assert false
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a missing required output still fails closed"
    true
    (Result.is_error (parse without_required))
;;

let valid_gcp_outputs () =
  `Assoc
    [ output "cluster_name" ~value:(`String "sol-qual")
    ; output "project_id" ~value:(`String "sol-qualification")
    ; output "region" ~value:(`String "us-central1")
    ; output
        "artifact_registry"
        ~value:(`String "us-central1-docker.pkg.dev/sol-qualification/sol-qual")
    ; output
        "provisioner_service_account"
        ~value:(`String "sol-qual-provisioner@sol-qualification.iam.gserviceaccount.com")
    ; output "loki_gcs_bucket" ~value:`Null
    ; output "thanos_gcs_bucket" ~value:`Null
    ; output "loki_workload_identity_sa_email" ~value:`Null
    ; output "thanos_workload_identity_sa_email" ~value:`Null
    ; output
        "cert_manager_workload_identity_sa_email"
        ~value:(`String "sol-qual-cert-manager@sol-qualification.iam.gserviceaccount.com")
    ]
;;

let parse_gcp json = Sol_cli_gcp_cluster.gcp_outputs_of_json (Yojson.Safe.to_string json)

let without_output name json =
  match json with
  | `Assoc fields -> `Assoc (List.remove_assoc name fields)
  | _ -> assert false
;;

let test_gcp_outputs () =
  (match parse_gcp (valid_gcp_outputs ()) with
   | Ok outputs ->
     Windtrap.equal Windtrap.string ~msg:"cluster" "sol-qual" outputs.cluster_name;
     Windtrap.equal Windtrap.string ~msg:"project" "sol-qualification" outputs.project_id;
     Windtrap.equal Windtrap.string ~msg:"region" "us-central1" outputs.region;
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"no loki bucket"
       None
       outputs.loki_gcs_bucket
   | Error message -> Windtrap.fail message);
  List.iter
    (fun name ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(name ^ " is required")
         true
         (Result.is_error (parse_gcp (without_output name (valid_gcp_outputs ())))))
    [ "cluster_name"
    ; "project_id"
    ; "region"
    ; "artifact_registry"
    ; "provisioner_service_account"
    ];
  List.iter
    (fun name ->
       match parse_gcp (without_output name (valid_gcp_outputs ())) with
       | Ok _ -> ()
       | Error message -> Windtrap.fail ("absent optional " ^ name ^ ": " ^ message))
    [ "loki_gcs_bucket"
    ; "thanos_gcs_bucket"
    ; "loki_workload_identity_sa_email"
    ; "thanos_workload_identity_sa_email"
    ]
;;

(* The provider reader the deploy's database-setup step calls. It must not conflate "no
   database was created" (null) with "the output could not be read" (error): the setup step
   fails closed on both, but for different reasons and with different messages. *)
let test_postgres_url_of_outputs () =
  let with_url base value =
    match base with
    | `Assoc fields -> `Assoc (fields @ [ output "postgres_url" ~value ])
    | _ -> assert false
  in
  let check ~provider ~base ~value ~msg expected =
    match
      Sol_cli_provider_registry.postgres_url_of_outputs
        provider
        (Yojson.Safe.to_string (with_url base value))
    with
    | Error failure ->
      Windtrap.fail (Sol_cli_provider_registry.resolution_failure_to_string failure)
    | Ok url -> Windtrap.equal (Windtrap.option Windtrap.string) ~msg expected url
  in
  check
    ~provider:Sol_cli_provider.Aws
    ~base:(valid_outputs ())
    ~value:(`String "postgresql://postgres:master@db.internal:5432/app")
    ~msg:"AWS reads postgres_url through the provider parser"
    (Some "postgresql://postgres:master@db.internal:5432/app");
  check
    ~provider:Sol_cli_provider.Gcp
    ~base:(valid_gcp_outputs ())
    ~value:(`String "postgresql://postgres:master@db.internal:5432/app")
    ~msg:"GCP dispatches to the GCP parser"
    (Some "postgresql://postgres:master@db.internal:5432/app");
  check
    ~provider:Sol_cli_provider.Aws
    ~base:(valid_outputs ())
    ~value:`Null
    ~msg:"a target that provisions no database is None, not an error"
    None;
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unreadable output is an error, not None"
    true
    (Result.is_error
       (Sol_cli_provider_registry.postgres_url_of_outputs Sol_cli_provider.Aws "not json"))
;;

let gcp_target () =
  { target with
    name = "prod/gcp/us-central1"
  ; provider = Sol_cli_provider.Gcp
  ; region = "us-central1"
  ; kube_context = Some "gke_sol-qualification_us-central1_sol"
  ; cluster_issuer = None
  }
;;

let test_cluster_identity_check () =
  let aws_target = Result.get_ok (L.cloud_target target) in
  let cluster role =
    let outputs =
      match valid_outputs () with
      | `Assoc fields ->
        `Assoc
          (("cluster_access_role_arn", `Assoc [ "value", `String role ])
           :: List.remove_assoc "cluster_access_role_arn" fields)
      | _ -> assert false
    in
    Sol_cli_aws_cluster.cluster
      ~region:"us-east-1"
      ~provisioner_role_arn:None
      ~deploy_role_arn:None
      (Result.get_ok (parse outputs))
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a different role is refused"
    true
    (Result.is_error
       (L.platform_inputs aws_target (cluster "arn:aws:iam::1:role/somebody-else")));
  Windtrap.equal
    Windtrap.bool
    ~msg:"the declared role is accepted"
    true
    (Result.is_ok
       (L.platform_inputs aws_target (cluster "arn:aws:iam::1:role/cluster-access")))
;;

let fake_aws () =
  let dir = Filename.temp_file "sol-deploy-access" "" in
  (try Sys.remove dir with
   | Sys_error _ -> ());
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls" in
  let script = Filename.concat dir "aws" in
  let out = open_out script in
  output_string
    out
    (Printf.sprintf "#!/bin/sh\nprintf '%%s\\n' \"$*\" >>%s\nexit 0\n" log);
  close_out out;
  Unix.chmod script 0o755;
  dir, log
;;

let test_cluster_deploy_access () =
  let dir, log = fake_aws () in
  let previous = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" (dir ^ ":" ^ Option.value previous ~default:"");
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some path -> Unix.putenv "PATH" path
       | None -> ());
      Sol_cli_fs.remove_reporting (Filename.concat dir "aws");
      Sol_cli_fs.remove_reporting log;
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () ->
       let outputs_with context =
         match valid_outputs () with
         | `Assoc fields ->
           `Assoc
             (("deploy_kube_context", `Assoc [ "value", `String context ])
              :: List.remove_assoc "deploy_kube_context" fields)
         | _ -> assert false
       in
       let cluster ~deploy_role_arn context =
         Sol_cli_aws_cluster.cluster
           ~region:"us-east-1"
           ~provisioner_role_arn:None
           ~deploy_role_arn
           (Result.get_ok (parse (outputs_with context)))
       in
       (match
          (cluster ~deploy_role_arn:(Some "arn:aws:iam::1:role/sol-deploy") "acme-deploy")
            .Sol_cli_cluster.deploy_access
            ()
        with
        | Ok (Some destination) ->
          Windtrap.equal
            Windtrap.string
            ~msg:"the run's destination is the root's deploy context"
            "acme-deploy"
            destination.Sol_cli_kube_destination.context;
          Windtrap.equal
            Windtrap.bool
            ~msg:"and it carries a kubeconfig scoped to this run"
            true
            (Option.is_some destination.Sol_cli_kube_destination.kubeconfig)
        | Ok None ->
          Windtrap.fail "a declared deploy identity must establish cluster access"
        | Error message -> Windtrap.fail message);
       let calls = In_channel.with_open_text log In_channel.input_all in
       Windtrap.equal
         Windtrap.bool
         ~msg:"the run assumes the deploy identity (DEC-058 option A)"
         true
         (Sol_cli_string.contains
            ~needle:"--role-arn arn:aws:iam::1:role/sol-deploy"
            calls);
       Windtrap.equal
         Windtrap.bool
         ~msg:"and never the provisioning identity (DEC-034)"
         false
         (Sol_cli_string.contains ~needle:"provisioner" calls);
       (match
          (cluster ~deploy_role_arn:None "acme-deploy").Sol_cli_cluster.deploy_access ()
        with
        | Ok None -> ()
        | Ok (Some _) ->
          Windtrap.fail "a target that declares no deploy identity must not be given one"
        | Error message -> Windtrap.fail message);
       let gcp =
         Sol_cli_gcp_cluster.cluster
           ~region:"us-central1"
           (Result.get_ok (parse_gcp (valid_gcp_outputs ())))
       in
       match gcp.Sol_cli_cluster.deploy_access () with
       | Ok None -> ()
       | Ok (Some _) ->
         Windtrap.fail "a provider with no deploy identity must not fabricate one"
       | Error message -> Windtrap.fail message)
;;

let fake_gcp_commands () =
  let dir = Filename.temp_file "sol-gcp-window" "" in
  (try Sys.remove dir with
   | Sys_error _ -> ());
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls" in
  let write name body =
    let path = Filename.concat dir name in
    let out = open_out path in
    output_string out body;
    close_out out;
    Unix.chmod path 0o755
  in
  write "gcloud" "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$SOL_TEST_GCP_LOG\"\nexit 0\n";
  write "gke-gcloud-auth-plugin" "#!/bin/sh\nexit 0\n";
  write
    "kubectl"
    (String.concat
       "\n"
       [ "#!/bin/sh"
       ; "printf '%s\\n' \"$*\" >>\"$SOL_TEST_GCP_LOG\""
       ; "case \" $* \" in"
       ; "  *\" auth can-i escalate clusterroles \"*|*\" auth can-i bind clusterroles \
          \"*)"
       ; "    case \"${SOL_TEST_GCP_WINDOW:-}\" in"
       ; "      open) printf 'yes\\n'; exit 0 ;;"
       ; "      *) printf 'no - no RBAC policy matched\\n'; exit 1 ;;"
       ; "    esac ;;"
       ; "  *\" auth can-i create namespaces \"*|*\" auth can-i create clusterroles \
          \"*|*\" auth can-i create storageclasses \"*)"
       ; "    case \"${SOL_TEST_GCP_WINDOW:-}\" in"
       ; "      closed) printf 'yes\\n'; exit 0 ;;"
       ; "      *) printf 'no - no RBAC policy matched\\n'; exit 1 ;;"
       ; "    esac ;;"
       ; "esac"
       ; "exit 1"
       ]);
  dir, log
;;

let with_fake_gcp_commands f =
  let dir, log = fake_gcp_commands () in
  let previous_path = Sys.getenv_opt "PATH" in
  let previous_log = Sys.getenv_opt "SOL_TEST_GCP_LOG" in
  let previous_window = Sys.getenv_opt "SOL_TEST_GCP_WINDOW" in
  Unix.putenv "SOL_TEST_GCP_LOG" log;
  Unix.putenv "PATH" (dir ^ ":" ^ Option.value previous_path ~default:"");
  Fun.protect
    ~finally:(fun () ->
      (match previous_path with
       | Some path -> Unix.putenv "PATH" path
       | None -> Unix.putenv "PATH" "");
      (match previous_log with
       | Some value -> Unix.putenv "SOL_TEST_GCP_LOG" value
       | None -> Unix.putenv "SOL_TEST_GCP_LOG" "");
      (match previous_window with
       | Some value -> Unix.putenv "SOL_TEST_GCP_WINDOW" value
       | None -> Unix.putenv "SOL_TEST_GCP_WINDOW" "");
      List.iter
        (fun name -> Sol_cli_fs.remove_reporting (Filename.concat dir name))
        [ "gcloud"; "gke-gcloud-auth-plugin"; "kubectl" ];
      Sol_cli_fs.remove_reporting log;
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    f
;;

let gcp_window () =
  let gcp =
    Sol_cli_gcp_cluster.cluster
      ~region:"us-central1"
      (Result.get_ok (parse_gcp (valid_gcp_outputs ())))
  in
  match gcp.Sol_cli_cluster.bootstrap_window with
  | Sol_cli_cluster.Verified window -> window
  | Sol_cli_cluster.No_role_declared | Sol_cli_cluster.Closed_by_platform_root ->
    Windtrap.fail "GCP apply must verify the installation window, not skip it"
;;

let test_gcp_installation_window () =
  with_fake_gcp_commands (fun () ->
    let window = gcp_window () in
    Windtrap.equal
      Windtrap.string
      ~msg:"the window names the provisioner"
      "sol-qual-provisioner@sol-qualification.iam.gserviceaccount.com"
      window.principal;
    (* A window that never became effective is reported as a missing window,
       not discovered as a RBAC denial inside the platform apply. *)
    Unix.putenv "SOL_TEST_GCP_WINDOW" "closed";
    (match window.gate () with
     | Ok () -> Windtrap.fail "a window that never showed a capability passed the gate"
     | Error message ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"the gate names the missing window"
         true
         (Sol_cli_string.contains ~needle:"bootstrap window" message));
    (* An effective window passes the gate and is observed. *)
    Unix.putenv "SOL_TEST_GCP_WINDOW" "open";
    (match window.gate () with
     | Ok () -> ()
     | Error message -> Windtrap.fail message);
    (match window.observe () with
     | Ok () -> ()
     | Error message -> Windtrap.fail message);
    (* After removal the bootstrap surface is gone and the successor holds. *)
    Unix.putenv "SOL_TEST_GCP_WINDOW" "closed";
    (match window.deescalated () with
     | Ok () -> ()
     | Error message -> Windtrap.fail message);
    (match window.successor () with
     | Ok () -> ()
     | Error message -> Windtrap.fail message);
    (* A capability still permitted after removal is refused. *)
    Unix.putenv "SOL_TEST_GCP_WINDOW" "open";
    match window.deescalated () with
    | Ok () ->
      Windtrap.fail "a still-permitted bootstrap capability was accepted as removal"
    | Error _ -> ())
;;

let test_platform_terraform_vars () =
  let vars inputs =
    match L.platform_terraform_vars inputs with
    | Ok vars -> vars
    | Error message -> Windtrap.fail message
  in
  let has vars entry = List.mem entry vars in
  let prefixed vars prefix =
    List.filter (fun entry -> String.starts_with ~prefix entry) vars
  in
  let aws_cloud =
    Sol_cli_aws_cluster.cluster
      ~region:"us-east-1"
      ~provisioner_role_arn:None
      ~deploy_role_arn:None
      (Result.get_ok (parse (valid_outputs ())))
  in
  let aws_target = Result.get_ok (L.cloud_target target) in
  let aws_inputs = Result.get_ok (L.platform_inputs aws_target aws_cloud) in
  let aws = vars aws_inputs in
  Windtrap.equal
    Windtrap.bool
    ~msg:"AWS selects its own provider"
    true
    (has aws "cloud_provider=aws");
  Windtrap.equal
    Windtrap.bool
    ~msg:"AWS passes its region"
    true
    (has aws "aws_region=us-east-1");
  Windtrap.equal
    Windtrap.bool
    ~msg:"AWS passes the cert-manager role its issuer branch reads"
    true
    (has aws "cert_manager_irsa_role_arn=arn:aws:iam::1:role/cert-manager");
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"AWS passes no GCS inputs to a root that does not declare them"
    []
    (prefixed aws "loki_gcs_bucket=" @ prefixed aws "thanos_gcs_bucket=");
  let gcp = Result.get_ok (L.cloud_target (gcp_target ())) in
  let gcp_cloud =
    Sol_cli_gcp_cluster.cluster
      ~region:"us-central1"
      (Result.get_ok (parse_gcp (valid_gcp_outputs ())))
  in
  let gcp_inputs = Result.get_ok (L.platform_inputs gcp gcp_cloud) in
  let gcp_vars = vars gcp_inputs in
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP selects its own provider"
    true
    (has gcp_vars "cloud_provider=gcp");
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP names the StorageClass it adopts"
    true
    (has gcp_vars "storage_class_name=standard-rwo");
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP passes no AWS inputs to a root that does not declare them"
    true
    (prefixed gcp_vars "aws_region="
     @ prefixed gcp_vars "cert_manager_irsa_role_arn="
     @ prefixed gcp_vars "loki_s3_bucket="
     @ prefixed gcp_vars "grafana_irsa_role_arn="
     = []);
  let tls_target = { (gcp_target ()) with cluster_issuer = Some "letsencrypt-prod" } in
  let tls_cloud = Result.get_ok (L.cloud_target tls_target) in
  match L.platform_inputs tls_cloud gcp_cloud |> Result.map L.platform_terraform_vars with
  | Ok (Ok vars) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:
        "a GCP target asking for TLS is installed, with the identity its solver \
         authenticates as"
      true
      (has
         vars
         "cert_manager_workload_identity_sa_email=sol-qual-cert-manager@sol-qualification.iam.gserviceaccount.com")
  | Ok (Error message) -> Windtrap.fail message
  | Error message -> Windtrap.fail message
;;

let test_preparation_failure_policies () =
  let open L in
  let ordinary =
    Preparation_failed
      { reason = "guard-lowering apply exited 1"; policy = Continue_to_destroy }
  in
  let required =
    Preparation_failed
      { reason = "final snapshot could not be prepared"; policy = Block_destroy }
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"an ordinary failure is reported"
    (Some "guard-lowering apply exited 1")
    (preparation_failure ordinary);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"and it does NOT block destruction"
    None
    (destruction_blocked ordinary);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a required-preparation failure is reported"
    (Some "final snapshot could not be prepared")
    (preparation_failure required);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"and it blocks, with the reason the target's own guarantee gives"
    (Some "final snapshot could not be prepared")
    (destruction_blocked required);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"nothing to prepare never blocks"
    None
    (destruction_blocked Nothing_to_prepare);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a success never blocks"
    None
    (destruction_blocked (Prepared "snap-1"));
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a success is not a failure"
    None
    (preparation_failure (Prepared "snap-1"))
;;

let test_preparations_eligible () =
  let desired =
    [ "google_sql_database_instance.postgres"; "google_container_cluster.main" ]
  in
  let eligible state = L.preparations_eligible ~state ~desired in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"both represented: both are eligible"
    desired
    (eligible desired);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "the half-built case: the cluster exists in the provider but not in state, so it \
       is NOT prepared -- preparing it would create it"
    [ "google_sql_database_instance.postgres" ]
    (eligible [ "google_sql_database_instance.postgres" ]);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing represented: nothing to prepare"
    []
    (eligible []);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"state that holds neither of the desired resources yields nothing"
    []
    (eligible [ "aws_db_instance.postgres" ]);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"order follows the configuration, not the state"
    desired
    (eligible (List.rev desired));
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"a counted resource in state satisfies the declared address (INFRA-081)"
    [ "aws_db_instance.postgres" ]
    (L.preparations_eligible
       ~state:[ "aws_db_instance.postgres[0]" ]
       ~desired:[ "aws_db_instance.postgres" ]);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"a string-keyed instance in state satisfies the declared address"
    [ "aws_db_instance.postgres" ]
    (L.preparations_eligible
       ~state:[ "aws_db_instance.postgres[\"primary\"]" ]
       ~desired:[ "aws_db_instance.postgres" ]);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"a declared resource with no state instance is still unrepresented (INFRA-081)"
    [ "aws_db_instance.postgres" ]
    (L.preparations_unrepresented
       ~state:[ "aws_db_instance.other[0]" ]
       ~desired:[ "aws_db_instance.postgres" ]);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the unrepresented set is the complement of the eligible one"
    [ "google_container_cluster.main" ]
    (L.preparations_unrepresented
       ~state:[ "google_sql_database_instance.postgres" ]
       ~desired);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing unrepresented when state holds everything"
    []
    (L.preparations_unrepresented ~state:desired ~desired);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"everything is unrepresented when state holds nothing"
    desired
    (L.preparations_unrepresented ~state:[] ~desired)
;;

let test_platform_vars_destruction_context () =
  let tls_target = { (gcp_target ()) with cluster_issuer = Some "letsencrypt-prod" } in
  let tls_cloud = Result.get_ok (L.cloud_target tls_target) in
  let gcp_cloud =
    Sol_cli_gcp_cluster.cluster
      ~region:"us-central1"
      (Result.get_ok (parse_gcp (valid_gcp_outputs ())))
  in
  let inputs = Result.get_ok (L.platform_inputs tls_cloud gcp_cloud) in
  (match L.platform_terraform_vars inputs with
   | Error message ->
     Windtrap.fail
       ("installation must accept a GCP target asking for TLS once the issuer path is \
         wired          (DEC-055), but it refused: "
        ^ message)
   | Ok vars ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"installation passes cert-manager's Workload Identity service account"
       true
       (List.mem
          "cert_manager_workload_identity_sa_email=sol-qual-cert-manager@sol-qualification.iam.gserviceaccount.com"
          vars);
     Windtrap.equal
       Windtrap.bool
       ~msg:"installation names the project the Cloud DNS zone lives in"
       true
       (List.mem "cert_manager_dns01_project=sol-qualification" vars);
     Windtrap.equal
       Windtrap.bool
       ~msg:"and still carries the issuer the target declared"
       true
       (List.mem "cluster_issuer=letsencrypt-prod" vars));
  match L.platform_terraform_vars ~context:L.Destruction inputs with
  | Ok vars ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"destruction gets the variables it needs to remove the platform"
      true
      (List.mem "cluster_issuer=letsencrypt-prod" vars)
  | Error message ->
    Windtrap.fail
      ("destruction must not be refused by an install-time requirement: " ^ message)
;;

let test_provisioner_kube_env () =
  let path = "/tmp/sol-platform-provisioner-test.kubeconfig" in
  let env = Sol_cli_cluster.provisioner_kube_env path in
  List.iter
    (fun key ->
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         ~msg:key
         (Some path)
         (List.assoc_opt key env))
    [ "KUBECONFIG"; "KUBE_CONFIG_PATH"; "KUBE_CONFIG_PATHS" ]
;;

let test_lifecycle_phases () =
  let open L in
  let name = phase_to_string in
  Windtrap.equal
    Windtrap.bool
    ~msg:"PlatformInstalling uses Installation policy"
    true
    (policy_of_phase Platform_installing = Installation);
  Windtrap.equal
    Windtrap.bool
    ~msg:"Ready uses Production policy"
    true
    (policy_of_phase Ready = Production);
  Windtrap.equal
    Windtrap.bool
    ~msg:"PreparingDestroy uses Destroy policy"
    true
    (policy_of_phase Preparing_destroy = Destroy);
  Windtrap.equal
    Windtrap.bool
    ~msg:"Ready policy applies in Ready"
    true
    (ready_policy_applies Ready);
  List.iter
    (fun p ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(name p ^ " is not Ready policy")
         false
         (ready_policy_applies p))
    [ Absent
    ; Cloud_bootstrap
    ; Platform_installing
    ; Platform_updating
    ; Preparing_destroy
    ; Destroying
    ];
  List.iter
    (fun (from, to_) ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(name from ^ " -> " ^ name to_ ^ " is legal")
         true
         (transition_allowed ~from ~to_))
    [ Absent, Cloud_bootstrap
    ; Cloud_bootstrap, Platform_installing
    ; Platform_installing, Ready
    ; Ready, Platform_updating
    ; Platform_updating, Ready
    ; Ready, Preparing_destroy
    ; Preparing_destroy, Destroying
    ; Destroying, Absent
    ];
  List.iter
    (fun (from, to_) ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(name from ^ " -> " ^ name to_ ^ " is rejected")
         false
         (transition_allowed ~from ~to_))
    [ Preparing_destroy, Ready
    ; Preparing_destroy, Platform_installing
    ; Destroying, Preparing_destroy
    ; Destroying, Ready
    ; Ready, Platform_installing
    ; Absent, Ready
    ; Cloud_bootstrap, Ready
    ; Platform_installing, Preparing_destroy
    ];
  Windtrap.equal
    Windtrap.bool
    ~msg:"the forward relation still rejects PlatformInstalling -> PreparingDestroy"
    false
    (transition_allowed ~from:Platform_installing ~to_:Preparing_destroy);
  List.iter
    (fun phase ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(name phase ^ " admits destruction")
         (phase <> Absent)
         (destruction_available phase);
       Windtrap.equal
         Windtrap.string
         ~msg:(name phase ^ " enters destruction as expected")
         (if phase = Absent then "Absent" else "PreparingDestroy")
         (phase_to_string (enter_destruction ~from:phase)))
    [ Absent
    ; Cloud_bootstrap
    ; Platform_installing
    ; Ready
    ; Platform_updating
    ; Preparing_destroy
    ; Destroying
    ];
  List.iter
    (fun phase ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(name phase ^ " does not enter a Ready-policy phase by destroying")
         false
         (ready_policy_applies (enter_destruction ~from:phase)))
    [ Absent
    ; Cloud_bootstrap
    ; Platform_installing
    ; Ready
    ; Platform_updating
    ; Preparing_destroy
    ; Destroying
    ];
  let destroy_vars =
    policy_vars
      ~provider:Sol_cli_provider.Aws
      ~phase:Preparing_destroy
      ~destroy_snapshot_id:"snap-1"
      ~retention:default_destroy_retention
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"destroy policy disables RDS deletion protection"
    (Some "false")
    (List.assoc_opt "rds_deletion_protection" destroy_vars);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"destroy policy carries the prepared final snapshot"
    (Some "snap-1")
    (List.assoc_opt "rds_final_snapshot_identifier" destroy_vars);
  Windtrap.equal
    Windtrap.int
    ~msg:"destroy policy is exactly the three destroy vars"
    3
    (List.length destroy_vars);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the GCP destroy policy carries both of GCP's guards"
    [ "sql_deletion_protection"; "false"; "gke_deletion_protection"; "false" ]
    (List.concat_map
       (fun (k, v) -> [ k; v ])
       (policy_vars
          ~provider:Sol_cli_provider.Gcp
          ~phase:Preparing_destroy
          ~destroy_snapshot_id:"snap-1"
          ~retention:default_destroy_retention));
  Windtrap.equal
    Windtrap.int
    ~msg:"Ready adds no policy overrides"
    0
    (List.length
       (policy_vars
          ~provider:Sol_cli_provider.Aws
          ~phase:Ready
          ~destroy_snapshot_id:"x"
          ~retention:default_destroy_retention));
  Windtrap.equal
    Windtrap.int
    ~msg:"GCP Ready adds no policy overrides either"
    0
    (List.length
       (policy_vars
          ~provider:Sol_cli_provider.Gcp
          ~phase:Ready
          ~destroy_snapshot_id:"x"
          ~retention:default_destroy_retention));
  Windtrap.equal
    Windtrap.string
    ~msg:"no substrate observes as Absent"
    "Absent"
    (phase_to_string (observed_phase ~cloud_exists:false ~platform_installed:false));
  Windtrap.equal
    Windtrap.string
    ~msg:"an absent substrate observes as Absent whatever else is claimed"
    "Absent"
    (phase_to_string (observed_phase ~cloud_exists:false ~platform_installed:true));
  Windtrap.equal
    Windtrap.string
    ~msg:"an uninstalled platform observes as PlatformInstalling"
    "PlatformInstalling"
    (phase_to_string (observed_phase ~cloud_exists:true ~platform_installed:false));
  Windtrap.equal
    Windtrap.string
    ~msg:"a completed install observes as Ready"
    "Ready"
    (phase_to_string (observed_phase ~cloud_exists:true ~platform_installed:true));
  Windtrap.equal
    Windtrap.bool
    ~msg:"PlatformInstalling -> Ready is admitted"
    true
    (Result.is_ok (enter ~from:Platform_installing ~to_:Ready));
  Windtrap.equal
    Windtrap.bool
    ~msg:"Ready -> PlatformUpdating is admitted"
    true
    (Result.is_ok (enter ~from:Ready ~to_:Platform_updating));
  Windtrap.equal
    Windtrap.bool
    ~msg:"PlatformUpdating -> Ready is admitted"
    true
    (Result.is_ok (enter ~from:Platform_updating ~to_:Ready));
  Windtrap.equal
    Windtrap.bool
    ~msg:"Ready -> PlatformInstalling is refused"
    true
    (Result.is_error (enter ~from:Ready ~to_:Platform_installing));
  Windtrap.equal
    Windtrap.bool
    ~msg:"PreparingDestroy -> Ready is refused"
    true
    (Result.is_error (enter ~from:Preparing_destroy ~to_:Ready));
  Windtrap.equal
    Windtrap.bool
    ~msg:"CloudBootstrap -> Ready is refused (the install is not skippable)"
    true
    (Result.is_error (enter ~from:Cloud_bootstrap ~to_:Ready));
  Windtrap.equal
    Windtrap.string
    ~msg:"a refused transition names both phases"
    "illegal lifecycle transition Ready -> PlatformInstalling"
    (Result.get_error (enter ~from:Ready ~to_:Platform_installing))
;;

let test_backends () =
  let get t root = Result.get_ok (L.backend_config t ~root) in
  let cloud = get target `Cloud
  and platform = get target `Platform in
  Windtrap.equal Windtrap.bool ~msg:"distinct" true (cloud <> platform);
  Windtrap.equal
    Windtrap.bool
    ~msg:"cloud key"
    true
    (List.mem "key=sol/prod/aws/us-east-1/cloud.tfstate" cloud);
  Windtrap.equal
    Windtrap.bool
    ~msg:"platform key"
    true
    (List.mem "key=sol/prod/aws/us-east-1/platform.tfstate" platform);
  let aws_without_lock = without_aws_field "state_lock_table" target in
  (match L.backend_config aws_without_lock ~root:`Cloud with
   | Error _ -> ()
   | Ok _ -> Windtrap.fail "an AWS target without a lock table must be refused");
  let gcp =
    { target with
      name = "prod/gcp/us-central1"
    ; provider = Sol_cli_provider.Gcp
    ; region = "us-central1"
    ; kube_context = Some "gke_sol-qualification_us-central1_sol"
    }
  in
  let gcp_cloud = get gcp `Cloud in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"GCS addresses the object by prefix and names no lock resource"
    [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/cloud.tfstate" ]
    gcp_cloud;
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCS platform state is its own object"
    true
    (get gcp `Platform
     = [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/platform.tfstate" ]);
  (match
     L.backend_config
       { gcp with provider_fields = [ "gcp", [ "state_lock_table", "unnecessary" ] ] }
       ~root:`Cloud
   with
   | Ok config ->
     Windtrap.equal
       (Windtrap.list Windtrap.string)
       ~msg:"a GCP target's lock table is not a backend attribute at all"
       [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/cloud.tfstate" ]
       config
   | Error message -> Windtrap.fail ("a GCP lock table must not be an error: " ^ message));
  List.iter
    (fun t ->
       match L.backend_config { t with state_bucket = None } ~root:`Cloud with
       | Error _ -> ()
       | Ok _ -> Windtrap.fail "a target without a state bucket must be refused")
    [ target; gcp ]
;;

let test_cloud_target () =
  let gcp =
    { target with
      name = "prod/gcp/us-central1"
    ; provider = Sol_cli_provider.Gcp
    ; region = "us-central1"
    ; kube_context = Some "gke_sol-qualification_us-central1_sol"
    }
  in
  let aws = Result.get_ok (L.cloud_target target) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"AWS carries the provisioner role it must assume"
    true
    (aws.cluster_access_role_arn = Some "arn:aws:iam::1:role/cluster-access");
  let gcp = Result.get_ok (L.cloud_target gcp) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP carries no role ARN and is not refused for it"
    true
    (gcp.cluster_access_role_arn = None);
  Windtrap.equal
    Windtrap.string
    ~msg:"region travels from the target"
    "us-central1"
    gcp.target.region;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the target's own backends are the ones selected"
    [ "bucket=acme-state"; "prefix=sol/prod/gcp/us-central1/platform.tfstate" ]
    gcp.platform_backend;
  (match L.cloud_target (without_aws_field "cluster_access_role_arn" target) with
   | Error _ -> ()
   | Ok _ -> Windtrap.fail "an AWS target without a cluster-access role must be refused");
  match L.cloud_target { target with base_domain = None } with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "a target without a base domain must be refused"
;;

let test_platform_root_selection () =
  Windtrap.equal
    Windtrap.string
    ~msg:"AWS has a root that declares the S3 backend"
    "platform/cloud/aws/platform"
    (Sol_cli_platform_assets.cloud_root_rel
       Sol_cli_provider.Aws
       Sol_cli_platform_assets.Platform);
  Windtrap.equal
    Windtrap.string
    ~msg:"GCP has a root that declares the GCS backend"
    "platform/cloud/gcp/platform"
    (Sol_cli_platform_assets.cloud_root_rel
       Sol_cli_provider.Gcp
       Sol_cli_platform_assets.Platform);
  Windtrap.equal
    Windtrap.string
    ~msg:"an address goes through the module that reaches the definition"
    "module.platform.kubernetes_namespace.cert_manager"
    (L.platform_address "kubernetes_namespace.cert_manager");
  Windtrap.equal
    Windtrap.bool
    ~msg:"the two providers do not select the same platform root"
    true
    (Sol_cli_platform_assets.cloud_root_rel
       Sol_cli_provider.Aws
       Sol_cli_platform_assets.Platform
     <> Sol_cli_platform_assets.cloud_root_rel
          Sol_cli_provider.Gcp
          Sol_cli_platform_assets.Platform)
;;

let test_deferred () =
  let open L in
  (match
     platform_plan_phases
       ~cluster_exists:false
       ~rbac_established:false
       ~install_window_open:false
       ~crds_established:false
   with
   | Deferred _, Deferred _ -> ()
   | _ -> Windtrap.fail "fresh target must defer both platform phases");
  (match
     platform_plan_phases
       ~cluster_exists:true
       ~rbac_established:false
       ~install_window_open:false
       ~crds_established:false
   with
   | Deferred _, Deferred _ -> ()
   | _ -> Windtrap.fail "a cluster without provisioner RBAC must defer both phases");
  (match
     platform_plan_phases
       ~cluster_exists:true
       ~rbac_established:true
       ~install_window_open:false
       ~crds_established:false
   with
   | Plannable, Deferred _ -> ()
   | _ -> Windtrap.fail "existing cluster must plan prerequisites only");
  (match
     platform_plan_phases
       ~cluster_exists:true
       ~rbac_established:true
       ~install_window_open:false
       ~crds_established:true
   with
   | Plannable, Deferred reason ->
     if not (Sol_cli_string.contains ~needle:"installation window" reason)
     then
       Windtrap.fail
         ("a steady-state plan must defer the whole-root platform on the install window, \
           but said: "
          ^ reason)
   | _ ->
     Windtrap.fail
       "a steady-state plan without the install window must defer the whole-root platform");
  (match
     platform_plan_phases
       ~cluster_exists:true
       ~rbac_established:false
       ~install_window_open:true
       ~crds_established:true
   with
   | Plannable, Plannable -> ()
   | _ -> Windtrap.fail "the install window must make both platform phases plannable");
  match
    platform_plan_phases
      ~cluster_exists:true
      ~rbac_established:false
      ~install_window_open:true
      ~crds_established:false
  with
  | Plannable, Deferred _ -> ()
  | _ ->
    Windtrap.fail
      "the install window with unestablished CRDs must still defer the substrate"
;;

let test_install_window_open () =
  let open L in
  Windtrap.equal
    Windtrap.bool
    ~msg:"both bootstrap-only capabilities permitted means the install window is open"
    true
    (install_window_open ~can_i:(fun _ -> true));
  Windtrap.equal
    Windtrap.bool
    ~msg:"a denied bootstrap-only capability means the install window is closed"
    false
    (install_window_open ~can_i:(fun args -> List.mem "bind" args |> not));
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "the window is probed through the bootstrap-only capabilities, not the steady state"
    [ "escalate clusterroles"; "bind clusterroles" ]
    (install_window_authorization_checks
     |> List.map (fun (_, args) -> String.concat " " args))
;;

let converged_cluster provider =
  let { L.storage_class; csi_driver } = L.platform_storage provider in
  function
  | "get" :: "storageclass" :: _ ->
    Ok (Printf.sprintf "%s|%s|true " storage_class csi_driver)
  | "get" :: "service/ingress-nginx-controller" :: _ -> Ok "example.elb.amazonaws.com"
  | "get" :: "daemonset" :: _ -> Ok "4/4 4/4 "
  | "get" :: "statefulset" :: _ -> Ok "3/3 1/1 "
  | "get" :: "pvc" :: _ -> Ok "Bound Bound "
  | "get" :: "nodes" :: _ -> Ok "True True "
  | _ -> Ok ""
;;

let test_readiness_fails_each_predicate () =
  Sol_cli_provider.all
  |> List.filter Sol_cli_provider_capabilities.owns_root
  |> List.iter (fun p ->
    let succeeds = converged_cluster p in
    let all = L.readiness ~provider:p ~run:succeeds in
    Windtrap.equal
      Windtrap.string
      ~msg:(Printf.sprintf "baseline (%s)" (Sol_cli_provider.to_string p))
      "Ready"
      (L.readiness_summary all);
    all
    |> List.iteri (fun failed _ ->
      let index = ref (-1) in
      let checks =
        L.readiness ~provider:p ~run:(fun argv ->
          incr index;
          if !index = failed then Error "the probe could not run" else succeeds argv)
      in
      Windtrap.equal
        Windtrap.bool
        ~msg:
          (Printf.sprintf
             "predicate %d fails closed (%s)"
             failed
             (Sol_cli_provider.to_string p))
        true
        (L.readiness_summary checks <> "Ready")))
;;

let readiness_with_unobservable_certificates ~provider =
  L.readiness ~provider ~run:(fun argv ->
    match argv with
    | "wait" :: "--for=condition=Ready" :: certificate :: _
      when String.starts_with ~prefix:"certificate/" certificate ->
      Error "exited with code 1: error: timed out waiting for the condition"
    | other -> converged_cluster provider other)
;;

let test_ready_requires_the_declared_certificates () =
  Sol_cli_provider.all
  |> List.filter Sol_cli_provider_capabilities.owns_root
  |> List.iter (fun provider ->
    let label = Sol_cli_provider.to_string provider in
    let summary =
      L.readiness_summary (readiness_with_unobservable_certificates ~provider)
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:
        (Printf.sprintf
           "a cluster whose declared certificates could not be observed ready is not \
            Ready (%s)"
           label)
      false
      (String.equal summary "Ready");
    Sol_cli_platform_tls.certificates
    |> List.iter (fun (declared : Sol_cli_platform_tls.declared_certificate) ->
      Windtrap.equal
        Windtrap.bool
        ~msg:
          (Printf.sprintf
             "the reason names %s/%s (%s)"
             declared.namespace
             declared.certificate
             label)
        true
        (Sol_cli_string.contains ~needle:declared.certificate summary)))
;;

let readiness_with_storage ~provider storage_output =
  L.readiness ~provider ~run:(fun argv ->
    match argv with
    | "get" :: "storageclass" :: _ -> Ok storage_output
    | other -> converged_cluster provider other)
  |> L.readiness_summary
;;

let test_storage_contract_is_provider_specific () =
  let aws = Sol_cli_provider.Aws in
  let gcp = Sol_cli_provider.Gcp in
  let check_ready provider label output =
    Windtrap.equal
      Windtrap.string
      ~msg:label
      "Ready"
      (readiness_with_storage ~provider output)
  in
  let check_unmet provider label output =
    Windtrap.equal
      Windtrap.bool
      ~msg:label
      true
      (readiness_with_storage ~provider output <> "Ready")
  in
  check_ready
    aws
    "the AWS contract is satisfied by gp3 on EBS CSI"
    "gp3|ebs.csi.aws.com|true ";
  check_ready
    gcp
    "the GCP contract is satisfied by GKE's default class"
    "standard-rwo|pd.csi.storage.gke.io|true ";
  check_unmet aws "no default StorageClass is unmet" "gp3|ebs.csi.aws.com|false ";
  check_unmet aws "a default class is unmet" "gp3|ebs.csi.aws.com|";
  check_unmet aws "an empty listing is unmet" "";
  check_unmet
    aws
    "two default classes are unmet, not resolved arbitrarily"
    "gp3|ebs.csi.aws.com|true gp2|ebs.csi.aws.com|true ";
  check_unmet
    aws
    "a default class Sol did not establish is unmet even on the same driver"
    "some-other-class|ebs.csi.aws.com|true ";
  check_unmet
    aws
    "the GCP provider's class does not satisfy the AWS contract"
    "standard-rwo|pd.csi.storage.gke.io|true ";
  check_unmet
    gcp
    "the AWS provider's class does not satisfy the GCP contract"
    "gp3|ebs.csi.aws.com|true "
;;

let test_readiness_invocations_are_provider_specific () =
  let aws = L.readiness_invocations ~provider:Sol_cli_provider.Aws in
  let gcp = L.readiness_invocations ~provider:Sol_cli_provider.Gcp in
  let mentions needle checks =
    List.exists (fun (_, argv) -> List.exists (fun arg -> arg = needle) argv) checks
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"AWS asserts the EBS CSI driver"
    true
    (mentions "csidriver/ebs.csi.aws.com" aws);
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP asserts the PD CSI driver"
    true
    (mentions "csidriver/pd.csi.storage.gke.io" gcp);
  Windtrap.equal
    Windtrap.bool
    ~msg:"AWS does not assert the GCP driver"
    false
    (mentions "csidriver/pd.csi.storage.gke.io" aws);
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP does not assert the AWS driver"
    false
    (mentions "csidriver/ebs.csi.aws.com" gcp);
  Windtrap.equal
    Windtrap.int
    ~msg:"both providers assert the same number of checks"
    (List.length aws)
    (List.length gcp)
;;

let test_destroy_retention () =
  let destroy_vars retention =
    L.policy_vars
      ~provider:Sol_cli_provider.Aws
      ~phase:L.Preparing_destroy
      ~destroy_snapshot_id:"snap-1"
      ~retention
  in
  let round_trip raw =
    Result.map L.destroy_retention_to_string (L.destroy_retention_of_string raw)
  in
  Windtrap.equal
    (Windtrap.result Windtrap.string Windtrap.string)
    ~msg:"final-snapshot parses"
    (Ok "final-snapshot")
    (round_trip "final-snapshot");
  Windtrap.equal
    (Windtrap.result Windtrap.string Windtrap.string)
    ~msg:"none parses"
    (Ok "none")
    (round_trip "none");
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unknown mode is refused rather than defaulted"
    true
    (Result.is_error (L.destroy_retention_of_string "keep-everything"));
  Windtrap.equal
    Windtrap.bool
    ~msg:"the default retains a final snapshot"
    true
    (List.mem_assoc
       "rds_final_snapshot_identifier"
       (destroy_vars L.Retain_final_snapshot));
  Windtrap.equal
    Windtrap.bool
    ~msg:"retaining nothing passes no snapshot identity"
    true
    (List.assoc_opt "rds_final_snapshot_identifier" (destroy_vars L.Retain_nothing) = None);
  Windtrap.equal
    Windtrap.bool
    ~msg:"retaining nothing skips the final snapshot"
    true
    (List.assoc_opt "rds_skip_final_snapshot" (destroy_vars L.Retain_nothing)
     = Some "true");
  Windtrap.equal
    Windtrap.bool
    ~msg:"retention still lifts deletion protection either way"
    true
    (List.assoc_opt "rds_deletion_protection" (destroy_vars L.Retain_nothing)
     = Some "false")
;;

let test_convergence_predicates () =
  let summary_with kind output =
    L.readiness ~provider ~run:(fun argv ->
      match argv with
      | "get" :: listed :: _ when listed = kind -> Ok output
      | other -> converged_cluster provider other)
    |> L.readiness_summary
  in
  let check_ready label summary =
    Windtrap.equal Windtrap.string ~msg:label "Ready" summary
  in
  let check_unmet label summary =
    Windtrap.equal Windtrap.bool ~msg:label true (summary <> "Ready")
  in
  check_ready
    "every daemonset pod scheduled and ready"
    (summary_with "daemonset" "4/4 4/4 ");
  check_unmet
    "a daemonset short of its desired pods is unmet"
    (summary_with "daemonset" "4/4 3/4 ");
  check_unmet
    "a daemonset scheduling no pods is not converged"
    (summary_with "daemonset" "0/0 ");
  check_unmet "no daemonsets at all is unmet" (summary_with "daemonset" "");
  check_ready
    "every statefulset replica declared and ready"
    (summary_with "statefulset" "3/3 1/1 ");
  check_unmet
    "a statefulset short of its declared replicas is unmet"
    (summary_with "statefulset" "3/2 ");
  check_ready
    "a statefulset declared at zero replicas is its owner's choice"
    (summary_with "statefulset" "0/0 ");
  check_unmet "no statefulsets at all is unmet" (summary_with "statefulset" "");
  check_ready "every PVC bound" (summary_with "pvc" "Bound Bound ");
  check_unmet "a Pending PVC is unmet" (summary_with "pvc" "Bound Pending ");
  check_unmet "no PVCs at all is unmet" (summary_with "pvc" "");
  check_ready "every node Ready" (summary_with "nodes" "True True ");
  check_unmet "a NotReady node is unmet" (summary_with "nodes" "True False ");
  check_unmet "no nodes at all is unmet" (summary_with "nodes" "")
;;

let capability verb resource = { Sol_cli_cloud_lifecycle.verb; resource }
let permitted capability = capability, Sol_cli_cloud_lifecycle.Permitted
let denied capability = capability, Sol_cli_cloud_lifecycle.Denied
let indeterminate capability why = capability, Sol_cli_cloud_lifecycle.Indeterminate why

let test_can_i_classification () =
  let classify ?(stderr = "") ~exit_code stdout =
    Sol_cli_cloud_lifecycle.capability_answer_of_can_i_output ~exit_code ~stdout ~stderr
  in
  let label = function
    | Sol_cli_cloud_lifecycle.Permitted -> "permitted"
    | Sol_cli_cloud_lifecycle.Denied -> "denied"
    | Sol_cli_cloud_lifecycle.Indeterminate _ -> "indeterminate"
  in
  let check name expected actual =
    Windtrap.equal Windtrap.string ~msg:name expected (label actual)
  in
  check "yes" "permitted" (classify ~exit_code:0 "yes\n");
  check "no" "denied" (classify ~exit_code:1 "no\n");
  check
    "no with a reason"
    "denied"
    (classify ~exit_code:1 "no - no RBAC policy matched\n");
  check
    "yes with a trailing line"
    "permitted"
    (classify ~exit_code:0 "yes\nsome trailing line\n");
  check "yes with exit 1" "indeterminate" (classify ~exit_code:1 "yes\n");
  check "no with exit 0" "indeterminate" (classify ~exit_code:0 "no\n");
  check
    "a transport failure"
    "indeterminate"
    (classify ~exit_code:1 ~stderr:"error: unable to connect to the server" "");
  check
    "an unclassifiable answer"
    "indeterminate"
    (classify ~exit_code:1 "something unexpected\n")
;;

let test_deescalation_requires_the_effective_surface () =
  let verdict
        ?(principal = Sol_cli_cloud_lifecycle.Principal_confirmed "…/sol-provisioner")
        probes
    =
    Sol_cli_cloud_lifecycle.deescalation_verdict ~principal probes
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"all denied -> de-escalated"
    "de-escalated"
    (match
       verdict
         [ denied (capability "create" "clusterroles")
         ; denied (capability "create" "clusterrolebindings")
         ]
     with
     | Sol_cli_cloud_lifecycle.Deescalated -> "de-escalated"
     | Sol_cli_cloud_lifecycle.Still_elevated _ -> "still elevated"
     | Sol_cli_cloud_lifecycle.Undetermined _ -> "undetermined");
  (match
     verdict
       [ denied (capability "create" "clusterroles")
       ; permitted (capability "escalate" "clusterroles")
       ]
   with
   | Sol_cli_cloud_lifecycle.Still_elevated still ->
     Windtrap.equal
       (Windtrap.list Windtrap.string)
       ~msg:"the permitted capability is named"
       [ "escalate clusterroles" ]
       still
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "a permitted capability was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Undetermined _ ->
     Windtrap.fail "a permitted capability was read as undetermined");
  (match
     verdict
       [ permitted (capability "escalate" "clusterroles")
       ; indeterminate (capability "create" "clusterroles") "connection refused"
       ]
   with
   | Sol_cli_cloud_lifecycle.Still_elevated still ->
     Windtrap.equal
       (Windtrap.list Windtrap.string)
       ~msg:"the permitted capability is named despite the indeterminate one"
       [ "escalate clusterroles" ]
       still
   | Sol_cli_cloud_lifecycle.Undetermined _ ->
     Windtrap.fail "an indeterminate probe masked a capability that was permitted"
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "a permitted capability was read as de-escalated");
  (match verdict [] with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "no evidence was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Windtrap.fail "no evidence was read as elevated");
  (match
     verdict [ indeterminate (capability "create" "clusterroles") "connection refused" ]
   with
   | Sol_cli_cloud_lifecycle.Undetermined why ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the indeterminate capability is named"
       true
       (Sol_cli_string.contains ~needle:"connection refused" why)
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "an indeterminate probe was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Windtrap.fail "an indeterminate probe was read as elevated");
  (match
     verdict
       ~principal:(Sol_cli_cloud_lifecycle.Principal_unexpected "…/sol-cluster-access")
       [ denied (capability "create" "clusterroles") ]
   with
   | Sol_cli_cloud_lifecycle.Undetermined why ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the unexpected principal is named"
       true
       (Sol_cli_string.contains ~needle:"sol-cluster-access" why)
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "another principal's refusal was read as de-escalation"
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Windtrap.fail "another principal's answers were treated as answers");
  (match
     verdict
       ~principal:
         (Sol_cli_cloud_lifecycle.Principal_refused_by_cluster
            "…/sol-provisioner: Unauthorized")
       []
   with
   | Sol_cli_cloud_lifecycle.Deescalated -> ()
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Windtrap.fail "a refused principal was read as still elevated"
   | Sol_cli_cloud_lifecycle.Undetermined _ ->
     Windtrap.fail "a refused principal was read as undetermined");
  match
    verdict
      ~principal:
        (Sol_cli_cloud_lifecycle.Principal_probe_failed
           "could not establish ephemeral provisioner cluster access")
      []
  with
  | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
  | Sol_cli_cloud_lifecycle.Deescalated ->
    Windtrap.fail "a measurement failure was read as de-escalation"
  | Sol_cli_cloud_lifecycle.Still_elevated _ ->
    Windtrap.fail "a measurement failure was read as still elevated"
;;

let test_successor_authority_requires_demonstration () =
  let caps = [ capability "create" "namespaces"; capability "create" "clusterroles" ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a permitted successor set establishes the successor's authority"
    true
    (Result.is_ok (Sol_cli_cloud_lifecycle.successor_authority (List.map permitted caps)));
  Windtrap.equal
    Windtrap.bool
    ~msg:"a denied successor capability is not a demonstrated handoff"
    true
    (Result.is_error
       (Sol_cli_cloud_lifecycle.successor_authority
          [ permitted (List.nth caps 0); denied (List.nth caps 1) ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unanswered successor capability is not a demonstrated handoff"
    true
    (Result.is_error
       (Sol_cli_cloud_lifecycle.successor_authority
          [ permitted (List.nth caps 0)
          ; indeterminate (List.nth caps 1) "the probe never reached the server"
          ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"proving nothing is not proving the successor works"
    true
    (Result.is_error (Sol_cli_cloud_lifecycle.successor_authority []))
;;

let test_deescalation_requires_a_transition () =
  let caps =
    [ capability "create" "clusterroles"
    ; capability "create" "clusterrolebindings"
    ; capability "escalate" "clusterroles"
    ]
  in
  let granted = List.map permitted caps in
  let refused = List.map denied caps in
  let confirmed = Sol_cli_cloud_lifecycle.Principal_confirmed "…/sol-provisioner" in
  let not_a_transition before =
    match
      Sol_cli_cloud_lifecycle.deescalation_transition
        ~before
        ~after_principal:confirmed
        ~after:refused
    with
    | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
    | Sol_cli_cloud_lifecycle.Deescalated ->
      Windtrap.fail
        "a capability never observed granted was read as a verified transition"
    | Sol_cli_cloud_lifecycle.Still_elevated _ ->
      Windtrap.fail "a capability never observed granted was read as still elevated"
  in
  not_a_transition [];
  not_a_transition refused;
  not_a_transition
    [ indeterminate (capability "create" "clusterroles") "the API was unreachable" ];
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:
         (Sol_cli_cloud_lifecycle.Principal_unexpected "…/sol-cluster-access")
       ~after:refused
   with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "a different principal's denial was read as a verified transition"
   | Sol_cli_cloud_lifecycle.Still_elevated _ -> Windtrap.fail "unexpected verdict");
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:
         (Sol_cli_cloud_lifecycle.Principal_probe_failed "expired credentials")
       ~after:refused
   with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "a measurement failure was read as a verified transition"
   | Sol_cli_cloud_lifecycle.Still_elevated _ -> Windtrap.fail "unexpected verdict");
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:confirmed
       ~after:refused
   with
   | Sol_cli_cloud_lifecycle.Deescalated -> ()
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Windtrap.fail "a demonstrated transition was read as still elevated"
   | Sol_cli_cloud_lifecycle.Undetermined why ->
     Windtrap.fail ("a demonstrated transition was read as undetermined: " ^ why));
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:confirmed
       ~after:
         [ indeterminate (capability "create" "clusterroles") "connection refused"
         ; denied (capability "create" "clusterrolebindings")
         ; denied (capability "escalate" "clusterroles")
         ]
   with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "an indeterminate post-de-escalation probe was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Still_elevated _ -> Windtrap.fail "unexpected verdict");
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:confirmed
       ~after:
         [ denied (capability "create" "clusterroles")
         ; denied (capability "create" "clusterrolebindings")
         ]
   with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "a capability the after-probe never covered was read as removed"
   | Sol_cli_cloud_lifecycle.Still_elevated _ -> Windtrap.fail "unexpected verdict");
  (match
     Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:confirmed
       ~after:
         [ permitted (capability "escalate" "clusterroles")
         ; indeterminate (capability "create" "clusterroles") "connection refused"
         ]
   with
   | Sol_cli_cloud_lifecycle.Still_elevated still ->
     Windtrap.equal
       (Windtrap.list Windtrap.string)
       ~msg:"the permitted capability is named despite the indeterminate one"
       [ "escalate clusterroles" ]
       still
   | Sol_cli_cloud_lifecycle.Undetermined _ ->
     Windtrap.fail "an indeterminate probe masked a capability that was permitted"
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "a permitted capability was read as de-escalated");
  match
    Sol_cli_cloud_lifecycle.deescalation_transition
      ~before:granted
      ~after_principal:confirmed
      ~after:granted
  with
  | Sol_cli_cloud_lifecycle.Still_elevated still ->
    Windtrap.equal Windtrap.int ~msg:"all three capabilities named" 3 (List.length still)
  | Sol_cli_cloud_lifecycle.Deescalated ->
    Windtrap.fail "a still-permitted capability was read as de-escalated"
  | Sol_cli_cloud_lifecycle.Undetermined _ -> Windtrap.fail "unexpected verdict"
;;

let test_whoami_identity_shapes () =
  let sts = "arn:aws:sts::111122223333:assumed-role/sol-provisioner/EKSGetTokenAuth" in
  let canonical = "arn:aws:iam::111122223333:role/sol-provisioner" in
  let eks_body session =
    Printf.sprintf
      {|{"apiVersion":"authentication.k8s.io/v1","kind":"SelfSubjectReview","metadata":{"creationTimestamp":null},"status":{"userInfo":{"username":"%s","uid":"aws-iam-authenticator:111122223333:AROA","groups":["system:authenticated","sol:platform-provisioners"],"extra":{"arn":["arn:aws:sts::111122223333:assumed-role/sol-provisioner/%s"],"canonicalArn":["%s"],"sessionName":["%s"],"principalId":["AROA:logan"]}}}}|}
      sts
      session
      canonical
      session
  in
  let role_of body =
    match Sol_cli_aws_cluster.whoami_identity_of_json body with
    | Ok i -> Sol_cli_aws_cluster.principal_role_name i
    | Error e -> Windtrap.fail e
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"eks shape yields the role"
    (Some "sol-provisioner")
    (role_of (eks_body "EKSGetTokenAuth"));
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a new session is still the same principal"
    (role_of (eks_body "EKSGetTokenAuth"))
    (role_of (eks_body "some-other-session"));
  let flat = Printf.sprintf {|{"status":{"userInfo":{"arn":"%s"}}}|} canonical in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"flat string form"
    (Some "sol-provisioner")
    (role_of flat);
  let pretty =
    Printf.sprintf
      {|{
  "status": {
    "userInfo": {
      "extra": {
        "canonicalArn": [
          "%s"
        ]
      }
    }
  }
}|}
      canonical
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"pretty-printed"
    (Some "sol-provisioner")
    (role_of pretty);
  (match
     Sol_cli_aws_cluster.whoami_identity_of_json
       {|{"status":{"userInfo":{"username":"system:node:ip-10-0-1-1"}}}|}
   with
   | Ok i ->
     Windtrap.equal
       (Windtrap.option Windtrap.string)
       ~msg:"username is the last resort"
       (Some "system:node:ip-10-0-1-1")
       (Sol_cli_aws_cluster.principal_role_name i)
   | Error e -> Windtrap.fail e);
  (match Sol_cli_aws_cluster.whoami_identity_of_json {|{"status":{"userInfo":{}}}|} with
   | Error _ -> ()
   | Ok i ->
     Windtrap.fail
       ("a response naming no principal produced "
        ^ Option.value (Sol_cli_aws_cluster.principal_role_name i) ~default:"?"));
  (match Sol_cli_aws_cluster.whoami_identity_of_json "error: You must be logged in" with
   | Error _ -> ()
   | Ok _ -> Windtrap.fail "a non-JSON response was accepted");
  Windtrap.equal
    Windtrap.string
    ~msg:"assumed-role ARN"
    "sol-provisioner"
    (Sol_cli_aws_cluster.role_name_of_arn sts);
  Windtrap.equal
    Windtrap.string
    ~msg:"role ARN"
    "sol-provisioner"
    (Sol_cli_aws_cluster.role_name_of_arn canonical)
;;

let test_principal_comparison_fails_closed () =
  let expected = "arn:aws:iam::111122223333:role/sol-provisioner" in
  let identity ?canonical ?arn ?username () =
    Sol_cli_aws_cluster.{ canonical_arn = canonical; arn; username; source = "test" }
  in
  Windtrap.equal
    (Windtrap.option Windtrap.bool)
    ~msg:"exact match"
    (Some true)
    (Sol_cli_aws_cluster.principal_matches ~expected (identity ~canonical:expected ()));
  Windtrap.equal
    (Windtrap.option Windtrap.bool)
    ~msg:"same role name in another account"
    (Some false)
    (Sol_cli_aws_cluster.principal_matches
       ~expected
       (identity
          ~canonical:("arn:aws:iam::" ^ String.make 12 '9' ^ ":role/sol-provisioner")
          ()));
  Windtrap.equal
    (Windtrap.option Windtrap.bool)
    ~msg:"same role behind a different path"
    (Some false)
    (Sol_cli_aws_cluster.principal_matches
       ~expected
       (identity ~canonical:"arn:aws:iam::111122223333:role/team/sol-provisioner" ()));
  Windtrap.equal
    (Windtrap.option Windtrap.bool)
    ~msg:"a session-carrying arn is not a role arn"
    (Some false)
    (Sol_cli_aws_cluster.principal_matches
       ~expected
       (identity
          ~arn:"arn:aws:sts::111122223333:assumed-role/sol-provisioner/EKSGetTokenAuth"
          ()));
  Windtrap.equal
    (Windtrap.option Windtrap.bool)
    ~msg:"no arn at all is None, not a default"
    None
    (Sol_cli_aws_cluster.principal_matches ~expected (identity ~username:"somebody" ()))
;;

let test_parse_failure_is_undetermined () =
  let granted = [ permitted (capability "create" "clusterroles") ] in
  let refused = [ denied (capability "create" "clusterroles") ] in
  let confirmed = Sol_cli_cloud_lifecycle.Principal_confirmed "arn:aws:iam::1:role/p" in
  let parse_failure =
    match Sol_cli_aws_cluster.whoami_identity_of_json "error: You must be logged in" with
    | Error why -> Sol_cli_cloud_lifecycle.Principal_probe_failed why
    | Ok _ -> Windtrap.fail "a non-JSON response was accepted by the parser"
  in
  let check_undetermined label verdict =
    match verdict with
    | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
    | Sol_cli_cloud_lifecycle.Deescalated ->
      Windtrap.fail (label ^ ": a parse failure was read as de-escalated")
    | Sol_cli_cloud_lifecycle.Still_elevated _ ->
      Windtrap.fail (label ^ ": a parse failure was read as still elevated")
  in
  check_undetermined
    "after"
    (Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:granted
       ~after_principal:parse_failure
       ~after:refused);
  check_undetermined
    "before"
    (Sol_cli_cloud_lifecycle.deescalation_transition
       ~before:[]
       ~after_principal:confirmed
       ~after:refused)
;;

let test_ambiguous_array_does_not_proceed () =
  let two_entries =
    {|{"status":{"userInfo":{"extra":{"canonicalArn":["arn:aws:iam::111122223333:role/sol-provisioner","arn:aws:iam::111122223333:role/sol-cluster-access"]}}}}|}
  in
  match Sol_cli_aws_cluster.whoami_identity_of_json two_entries with
  | Error _ -> ()
  | Ok identity ->
    Windtrap.fail
      (Printf.sprintf
         "a two-entry canonicalArn was accepted and produced %s; taking one element is a \
          default in disguise, and the array is ambiguous about which principal this is"
         (Option.value (Sol_cli_aws_cluster.principal_role_name identity) ~default:"?"))
;;

let test_identity_reports_its_source () =
  let source_of body =
    match Sol_cli_aws_cluster.whoami_identity_of_json body with
    | Ok i -> i.source
    | Error e -> Windtrap.fail e
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"canonicalArn from extra"
    "extra.canonicalArn"
    (source_of
       {|{"status":{"userInfo":{"extra":{"canonicalArn":["arn:aws:iam::111122223333:role/p"]}}}}|});
  Windtrap.equal
    Windtrap.string
    ~msg:"arn from extra when there is no canonicalArn"
    "extra.arn"
    (source_of
       {|{"status":{"userInfo":{"extra":{"arn":["arn:aws:iam::111122223333:role/p"]}}}}|});
  Windtrap.equal
    Windtrap.string
    ~msg:"the username fallback is named as such"
    "username"
    (source_of {|{"status":{"userInfo":{"username":"system:node:ip-10-0-1-1"}}}|})
;;

let test_refusal_needs_a_good_identity () =
  let granted = [ permitted (capability "create" "clusterroles") ] in
  let refused = [ denied (capability "create" "clusterroles") ] in
  let verdict_of assumption =
    Sol_cli_cloud_lifecycle.deescalation_transition
      ~before:granted
      ~after_principal:
        (Sol_cli_aws_cluster.refusal_is_deescalation assumption "Unauthorized")
      ~after:refused
  in
  (match verdict_of Sol_cli_aws_cluster.Credential_assumable with
   | Sol_cli_cloud_lifecycle.Deescalated -> ()
   | _ -> Windtrap.fail "a refusal with a working identity was not read as de-escalated");
  (match verdict_of Sol_cli_aws_cluster.Credential_refused with
   | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
   | Sol_cli_cloud_lifecycle.Deescalated ->
     Windtrap.fail "a refusal with an unassumable role was read as de-escalated"
   | Sol_cli_cloud_lifecycle.Still_elevated _ ->
     Windtrap.fail "a refusal with an unassumable role was read as still elevated");
  match verdict_of Sol_cli_aws_cluster.Credential_unchecked with
  | Sol_cli_cloud_lifecycle.Undetermined _ -> ()
  | Sol_cli_cloud_lifecycle.Deescalated ->
    Windtrap.fail "a refusal with no identity check was read as de-escalated"
  | Sol_cli_cloud_lifecycle.Still_elevated _ ->
    Windtrap.fail "a refusal with no identity check was read as still elevated"
;;

let test_effective_authorization () =
  let open L in
  let expected = provisioner_authorization_checks in
  let can_i args =
    match
      List.assoc_opt args (List.map (fun (result, argv) -> argv, result) expected)
    with
    | Some Required -> true
    | Some Forbidden -> false
    | None -> Windtrap.fail "authorization check was not declared"
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"declared boundary"
    true
    (provisioner_authorization_established ~can_i);
  expected
  |> List.iter (fun (_, failed) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:(String.concat " " failed)
      false
      (provisioner_authorization_established ~can_i:(fun args ->
         if args = failed then not (can_i args) else can_i args)))
;;

let test_terraform_layout_derives_from_cloud_target () =
  let layout_for cloud_target = Sol_cli_cloud_wiring.terraform_layout ~cloud_target in
  let aws = Result.get_ok (L.cloud_target target) in
  let layout = layout_for aws in
  Windtrap.equal
    Windtrap.string
    ~msg:"provider name follows the target"
    "aws"
    layout.pname;
  Windtrap.equal
    Windtrap.bool
    ~msg:"the cluster workdir is derived from the target's provider and backend"
    true
    (String.equal
       layout.infra_dir
       (Sol_cli_terraform_workdir.chdir
          ~provider:Sol_cli_provider.Aws
          ~role:Sol_cli_platform_assets.Cluster
          ~backend_config:aws.L.cloud_backend));
  Windtrap.equal
    Windtrap.bool
    ~msg:"the platform workdir is derived from the target's provider and backend"
    true
    (String.equal
       layout.platform_dir
       (Sol_cli_terraform_workdir.chdir
          ~provider:Sol_cli_provider.Aws
          ~role:Sol_cli_platform_assets.Platform
          ~backend_config:aws.L.platform_backend));
  Windtrap.equal
    Windtrap.bool
    ~msg:"the two roles never share a workdir"
    true
    (not (String.equal layout.infra_dir layout.platform_dir));
  let gcp = layout_for (Result.get_ok (L.cloud_target (gcp_target ()))) in
  Windtrap.equal
    Windtrap.string
    ~msg:"a second provider derives its own name"
    "gcp"
    gcp.pname;
  Windtrap.equal
    Windtrap.bool
    ~msg:"a second provider derives a different workdir"
    true
    (not (String.equal layout.infra_dir gcp.infra_dir))
;;

let test_terraform_scope () =
  ignore (Sol_cli_terraform.targets "helm_release.cert_manager" []);
  Windtrap.raises
    ~msg:"empty target rejected"
    (Invalid_argument "Terraform target must not be empty")
    (fun () -> ignore (Sol_cli_terraform.targets "" []));
  ignore Sol_cli_terraform.whole_root
;;

let%test "contracts: strict AWS outputs" = test_outputs ()
let%test "contracts: absent optional AWS outputs" = test_outputs_absent_optional ()
let%test "contracts: strict GCP outputs" = test_gcp_outputs ()

let%test "contracts: postgres_url reads through the provider parser" =
  test_postgres_url_of_outputs ()
;;

let%test "contracts: provider-shaped platform variables" = test_platform_terraform_vars ()
let%test "contracts: cluster identity check" = test_cluster_identity_check ()

let%test "contracts: the deploy identity reaches the cluster (DEC-058)" =
  test_cluster_deploy_access ()
;;

let%test "contracts: GCP apply verifies the installation window" =
  test_gcp_installation_window ()
;;

let%test "contracts: a preparation failure's policy decides" =
  test_preparation_failure_policies ()
;;

let%test "contracts: preparation targets only what state represents" =
  test_preparations_eligible ()
;;

let%test "contracts: destruction is not refused by an install-time requirement" =
  test_platform_vars_destruction_context ()
;;

(* Readiness evidence is typed: a probe that could not run is [Unobservable]
   with its own evidence, a probe that ran and reported a bad state is a
   confirmed [Unmet], and the two are never collapsed. *)
let test_readiness_classifies_probe_failure_as_unobservable () =
  Sol_cli_provider.all
  |> List.filter Sol_cli_provider_capabilities.owns_root
  |> List.iter (fun provider ->
    let label = Sol_cli_provider.to_string provider in
    let checks =
      L.readiness ~provider ~run:(fun _ -> Error "exited with code 5: Forbidden")
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:(label ^ ": no failed probe reads as a confirmed condition")
      true
      (List.for_all
         (function
           | _, L.Unobservable why -> Sol_cli_string.contains ~needle:"Forbidden" why
           | _, (L.Established | L.Unmet _) -> false)
         checks))
;;

let test_confirmed_unmet_and_unobservable_are_distinct () =
  let provider = Sol_cli_provider.Aws in
  let checks =
    L.readiness ~provider ~run:(fun argv ->
      match argv with
      | "get" :: "storageclass" :: _ -> Ok "wrong-class|wrong.csi|true "
      | "get" :: resource :: _ when String.starts_with ~prefix:"csidriver/" resource ->
        Error "exited with code 5: Forbidden"
      | other -> converged_cluster provider other)
  in
  (match List.assoc_opt "default StorageClass" checks with
   | Some (L.Unmet _) -> ()
   | _ -> Windtrap.fail "an unacceptable successful result must be a confirmed Unmet");
  (match List.assoc_opt "block-storage CSI driver" checks with
   | Some (L.Unobservable why) ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the probe evidence is kept"
       true
       (Sol_cli_string.contains ~needle:"Forbidden" why)
   | _ -> Windtrap.fail "an errored probe must be Unobservable, not Unmet");
  let summary = L.readiness_summary checks in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the summary distinguishes confirmed unmet from unobservable"
    true
    (Sol_cli_string.contains ~needle:"Unmet —" summary
     && Sol_cli_string.contains ~needle:"nobservable —" summary);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the decision refuses the mixed outcome"
    true
    (Result.is_error (L.readiness_decision checks))
;;

let test_readiness_decision_follows_the_typed_state () =
  Windtrap.equal
    (Windtrap.result Windtrap.unit Windtrap.string)
    ~msg:"every check established"
    (Ok ())
    (L.readiness_decision [ "a", L.Established; "b", L.Established ]);
  Windtrap.equal
    Windtrap.bool
    ~msg:"a confirmed unmet refuses"
    true
    (Result.is_error (L.readiness_decision [ "a", L.Unmet "still coming up" ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unobservable check refuses"
    true
    (Result.is_error (L.readiness_decision [ "a", L.Unobservable "no tool" ]));
  let summary = L.readiness_summary [ "a", L.Unobservable "no tool" ] in
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unobservable summary is marked unobservable"
    true
    (Sol_cli_string.contains ~needle:"Unobservable —" summary);
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unobservable summary is never a confirmed unmet condition"
    false
    (Sol_cli_string.contains ~needle:"Unmet —" summary)
;;

let%test "contracts: provisioner kubeconfig env" = test_provisioner_kube_env ()
let%test "contracts: lifecycle phases and policy" = test_lifecycle_phases ()
let%test "contracts: separate backends" = test_backends ()
let%test "contracts: provider-shaped cloud target" = test_cloud_target ()
let%test "contracts: provider-specific platform root" = test_platform_root_selection ()
let%test "contracts: deferred plan" = test_deferred ()

let%test "contracts: the install window is the bootstrap-only capability set" =
  test_install_window_open ()
;;

let%test "contracts: readiness predicates" = test_readiness_fails_each_predicate ()

let%test "contracts: a probe that could not run is unobservable, with its evidence" =
  test_readiness_classifies_probe_failure_as_unobservable ()
;;

let%test "contracts: confirmed unmet and unobservable stay distinct" =
  test_confirmed_unmet_and_unobservable_are_distinct ()
;;

let%test "contracts: the readiness decision follows the typed state" =
  test_readiness_decision_follows_the_typed_state ()
;;

let%test "contracts: a declared certificate gates Ready (DEC-056)" =
  test_ready_requires_the_declared_certificates ()
;;

let%test "contracts: provider-specific storage contract" =
  test_storage_contract_is_provider_specific ()
;;

let%test "contracts: provider-specific readiness invocations" =
  test_readiness_invocations_are_provider_specific ()
;;

let%test "contracts: convergence predicates" = test_convergence_predicates ()
let%test "contracts: destroy retention" = test_destroy_retention ()
let%test "contracts: effective authorization" = test_effective_authorization ()
let%test "contracts: can-i answer classification (DEC-040)" = test_can_i_classification ()

let%test "contracts: verified de-escalation (DEC-040)" =
  test_deescalation_requires_the_effective_surface ()
;;

let%test "contracts: whoami identity shapes (DEC-040)" = test_whoami_identity_shapes ()

let%test "contracts: principal comparison fails closed (DEC-040)" =
  test_principal_comparison_fails_closed ()
;;

let%test "contracts: ambiguous array (DEC-040)" = test_ambiguous_array_does_not_proceed ()

let%test "contracts: a refusal needs a good identity (DEC-040)" =
  test_refusal_needs_a_good_identity ()
;;

let%test "contracts: identity reports its source (DEC-040)" =
  test_identity_reports_its_source ()
;;

let%test "contracts: parse failure is Undetermined (DEC-040)" =
  test_parse_failure_is_undetermined ()
;;

let%test "contracts: a handoff is claimed only with a demonstrated successor" =
  test_successor_authority_requires_demonstration ()
;;

let%test "contracts: verified de-escalation is a transition (DEC-040)" =
  test_deescalation_requires_a_transition ()
;;

let%test "contracts: terraform scope" = test_terraform_scope ()

let%test "contracts: terraform layout follows the cloud target" =
  test_terraform_layout_derives_from_cloud_target ()
;;

let%test "driver: byo is registered and owns no cloud root (DEC-051)" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"byo is registered and rootless by definition"
    true
    (Sol_cli_provider.of_string "byo" = Some Sol_cli_provider.Byo
     && Sol_cli_provider.to_string Sol_cli_provider.Byo = "byo"
     && Sol_cli_provider.is_known "byo"
     && List.mem Sol_cli_provider.Byo Sol_cli_provider.all
     && (Sol_cli_provider_capabilities.capabilities_of Sol_cli_provider.Byo).root_status
        = Sol_cli_provider_capabilities.Root_not_applicable)
;;

let%test "driver: aws and gcp declare a cloud root (DEC-051)" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"aws and gcp own roots"
    true
    ((Sol_cli_provider_capabilities.capabilities_of Sol_cli_provider.Aws).root_status
     = Sol_cli_provider_capabilities.Root_present
     && (Sol_cli_provider_capabilities.capabilities_of Sol_cli_provider.Gcp).root_status
        = Sol_cli_provider_capabilities.Root_present)
;;

let%test "driver: a rootless driver is never production-qualified" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"byo is not production-qualified"
    false
    (Sol_cli_provider_capabilities.capabilities_of Sol_cli_provider.Byo)
      .production_qualified
;;

let%test "driver: byo has no cloud root to resolve (DEC-051)" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"of_root refuses a rootless driver"
    true
    (match
       Sol_cli_provider_registry.of_root
         Sol_cli_provider.Byo
         ~target
         ~chdir:"/nonexistent"
     with
     | Error (Sol_cli_provider_registry.No_root _) -> true
     | _ -> false)
;;

let%test "driver: byo has nothing to observe, identify or credential (DEC-051)" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"a rootless driver observes and identifies nothing"
    true
    (Sol_cli_provider_registry.observations Sol_cli_provider.Byo target ~cluster_name:"x"
     = []
     && Sol_cli_provider_registry.resource_identity Sol_cli_provider.Byo ~cluster_name:"x"
        = []
     &&
     match
       Sol_cli_provider_registry.credentials
         Sol_cli_provider.Byo
         ~operation:"plan"
         ~leaves_target_standing:false
     with
     | Error _ -> true
     | Ok () -> false)
;;

let credential_components ~platform_profile =
  `Assoc
    [ ( "redpanda"
      , `Assoc
          [ ( platform_profile
            , `Assoc
                [ ( "auth"
                  , `Assoc [ "sasl", `Assoc [ "secretRef", `String "redpanda-users" ] ] )
                ] )
          ] )
    ]
;;

let credential_labels credentials =
  List.map
    (fun (credential : L.platform_credential) ->
       credential.namespace ^ "/" ^ credential.secret)
    credentials
;;

let%test "platform credentials: the durable layer requires the broker SASL Secret" =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the durable layer declares redpanda/redpanda-users"
    [ "redpanda/redpanda-users" ]
    (credential_labels
       (L.platform_credentials_of_components
          ~platform_profile:"durable"
          (credential_components ~platform_profile:"durable")))
;;

let%test "platform credentials: the local layer requires none" =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the local layer carries no SASL secretRef"
    []
    (credential_labels
       (L.platform_credentials_of_components
          ~platform_profile:"local"
          (credential_components ~platform_profile:"durable")))
;;

let%test "platform credentials: the profile comes from the effective platform vars" =
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"platform_profile=durable is read from the vars sent to Terraform"
    (Some "durable")
    (L.profile_of_platform_vars
       [ "base_domain=acme.example"; "platform_profile=durable" ])
;;

let%test "credential presence: a successful check is present" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"exit 0 means the Secret exists"
    true
    (match L.credential_presence ~exit_code:0 ~output:"" with
     | L.Credential_present -> true
     | L.Credential_absent | L.Credential_unverifiable _ -> false)
;;

let%test "credential presence: NotFound is absent, any other failure is unverifiable" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"a NotFound is a positive absence; a denied or unreachable check is not"
    true
    ((match
        L.credential_presence
          ~exit_code:1
          ~output:"Error from server (NotFound): secrets \"redpanda-users\" not found"
      with
      | L.Credential_absent -> true
      | L.Credential_present | L.Credential_unverifiable _ -> false)
     &&
     match
       L.credential_presence
         ~exit_code:1
         ~output:"error: You must be logged in to the server (Unauthorized)"
     with
     | L.Credential_unverifiable _ -> true
     | L.Credential_present | L.Credential_absent -> false)
;;

(* The platform install stops for a credential Sol must not hold, so the refusal is
   the one place the operator is told how to reach the cluster. When the target's
   cloud root has published its deploy handoff, the refusal carries it; without one
   it keeps the bare example rather than inventing a context. *)
let test_missing_platform_credential_message () =
  let credential = { L.namespace = "redpanda"; secret = "redpanda-users" } in
  let plain = L.missing_platform_credential_message credential in
  let contains needle haystack =
    let nl = String.length needle
    and hl = String.length haystack in
    let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
    nl = 0 || go 0
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the refusal names the Secret and its namespace"
    true
    (contains "redpanda-users" plain && contains "namespace redpanda" plain);
  Windtrap.equal
    Windtrap.bool
    ~msg:"without a handoff it keeps the bare kubectl example"
    true
    (contains "kubectl create secret generic redpanda-users" plain);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and claims no command it does not have"
    false
    (contains "deploy identity's command" plain);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and still says how to resume"
    true
    (contains "then re-run `sol deploy <target>` to resume the install." plain);
  let handed =
    L.missing_platform_credential_message
      ~deploy_handoff:
        ( "aws eks update-kubeconfig --region us-east-1 --name acme-prod --alias \
           acme-prod-deploy"
        , "acme-prod-deploy" )
      credential
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"with a handoff the refusal prints the target's own command"
    true
    (contains "aws eks update-kubeconfig --region us-east-1 --name acme-prod" handed);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and creates the Secret through the context that command writes"
    true
    (contains
       "kubectl --context acme-prod-deploy create secret generic redpanda-users"
       handed);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and still names the Secret"
    true
    (contains "redpanda-users" handed && contains "namespace redpanda" handed)
;;
