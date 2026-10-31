let aws_target : Sol_cli_config.target =
  { name = "prod/aws/us-east-1"
  ; env = "prod"
  ; provider = Sol_cli_provider.Aws
  ; region = "us-east-1"
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = Some "acme-prod"
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; observability_logs_url = None
  ; observability_metrics_url = None
  ; observability_traces_url = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = None
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; shape = Some Sol_cli_profile.Local
  ; provider_fields =
      [ ( "aws"
        , [ "provisioner_role_arn", "arn:aws:iam::111122223333:role/sol-provisioner"
          ; "reconciler_trust_principal_arn", "arn:aws:iam::111122223333:role/ci"
          ] )
      ]
  ; secret_authorities = []
  }
;;

let gcp_target : Sol_cli_config.target =
  { aws_target with
    name = "prod/gcp/us-central1"
  ; provider = Sol_cli_provider.Gcp
  ; region = "us-central1"
  ; provider_fields =
      [ ( "gcp"
        , [ "project_id", "acme-project"
          ; "reconciler_trust_principal", "user:ci@example.test"
          ] )
      ]
  }
;;

let class_of (o : Sol_cli_absence.observation) =
  match o with
  | Sol_cli_absence.Absent a -> a.resource_class
  | Present p -> p.resource_class
  | External e -> e.resource_class
  | Not_attributable n -> n.resource_class
  | Unobservable u -> u.resource_class
;;

let find_class resource_class observations =
  List.find_opt
    (fun observation -> String.equal (class_of observation) resource_class)
    observations
;;

let with_fake_command name script f =
  let dir = Filename.temp_file ("sol-fake-" ^ name ^ "-") "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir name in
  Out_channel.with_open_text bin (fun oc -> output_string oc script);
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f ())
;;

let aws_script ?(workload_roles = "") ~roles ~roles_exit () =
  Printf.sprintf
    {|#!/bin/sh
case "$*" in
  *"sts get-caller-identity "*) printf '111122223333\n'; exit 0 ;;
  *"iam list-roles "*)
    case "$*" in
      *"Roles[?Path=="*) printf '%%s' %s ;;
      *) printf '%%s' %s ;;
    esac
    if [ %d -ne 0 ]; then printf 'access denied' >&2; fi
    exit %d
    ;;
  *"iam list-policies "*) exit 0 ;;
esac
exit 0
|}
    (Filename.quote workload_roles)
    (Filename.quote roles)
    roles_exit
    roles_exit
;;

let%test "authorization: AWS role residue is observed and a failed check is strict" =
  with_fake_command "aws" (aws_script ~roles:"sol-prod-authorization\n" ~roles_exit:0 ())
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations
      ~authorization_identities:[ "authorization IAM role", [ "sol-prod-authorization" ] ]
      aws_target
      ~cluster_name:"acme-prod"
  in
  (match find_class "authorization IAM role" observations with
   | Some (Sol_cli_absence.Present _) -> ()
   | _ -> Windtrap.fail "the authorization reconciler role was not observed");
  with_fake_command "aws" (aws_script ~roles:"" ~roles_exit:1 ())
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations
      ~authorization_identities:[ "authorization IAM role", [ "sol-prod-authorization" ] ]
      aws_target
      ~cluster_name:"acme-prod"
  in
  match find_class Sol_cli_absence.scope_class observations with
  | Some (Sol_cli_absence.Unobservable _) -> ()
  | _ ->
    Windtrap.fail "a failed authorization enumeration was not a strict scope observation"
;;

let aws_target_without_trust =
  { aws_target with
    provider_fields =
      [ ( "aws"
        , [ "provisioner_role_arn", "arn:aws:iam::111122223333:role/sol-provisioner" ] )
      ]
  }
;;

let%test "authorization: AWS workload roles are observed by environment path" =
  with_fake_command
    "aws"
    (aws_script
       ~roles:"sol-prod-authorization\n"
       ~workload_roles:"sol-prod-charge-svc\n"
       ~roles_exit:0
       ())
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations
      ~authorization_identities:
        [ "authorization workload role", [ "sol-prod-charge-svc" ] ]
      aws_target
      ~cluster_name:"acme-prod"
  in
  match find_class "authorization workload role" observations with
  | Some (Sol_cli_absence.Present present) ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the workload role under the environment path is reported"
      [ "sol-prod-charge-svc" ]
      present.found
  | _ -> Windtrap.fail "the authorization workload role was not observed"
;;

let%test
    "authorization: AWS identities are observed after the trust declaration is removed"
  =
  with_fake_command "aws" (aws_script ~roles:"sol-prod-authorization\n" ~roles_exit:0 ())
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations
      ~authorization_identities:[ "authorization IAM role", [ "sol-prod-authorization" ] ]
      aws_target_without_trust
      ~cluster_name:"acme-prod"
  in
  match find_class "authorization IAM role" observations with
  | Some (Sol_cli_absence.Present _) -> ()
  | _ ->
    Windtrap.fail
      "an absent current trust declaration must not skip the historical authorization \
       root"
;;

let gcp_script
      ?(project_policy = "")
      ?(secrets = "")
      ?(secrets_stderr = "")
      ?(secret_policy = "")
      ~service_accounts
      ~roles
      ()
  =
  Printf.sprintf
    {|#!/bin/sh
case "$*" in
  *"iam service-accounts list "*) printf '%%s' %s; exit 0 ;;
  *"iam roles list "*) printf '%%s' %s; exit 0 ;;
  *"projects get-iam-policy "*) printf '%%s' %s; exit 0 ;;
  *"secrets list "*) printf '%%s' %s >&2; printf '%%s' %s; exit 0 ;;
  *"secrets get-iam-policy "*) printf '%%s' %s; exit 0 ;;
esac
exit 0
|}
    (Filename.quote service_accounts)
    (Filename.quote roles)
    (Filename.quote project_policy)
    (Filename.quote secrets_stderr)
    (Filename.quote secrets)
    (Filename.quote secret_policy)
;;

let gcp_auth_identity = "sol-prod-authorization@acme-project.iam.gserviceaccount.com\n"
let gcp_auth_role = "projects/acme-project/roles/sol_prod_authorization\n"

let%test "authorization: GCP identity residue is observed by its environment name" =
  with_fake_command
    "gcloud"
    (gcp_script ~service_accounts:gcp_auth_identity ~roles:gcp_auth_role ())
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations
      ~authorization_identities:
        [ "authorization service account", [ gcp_auth_identity ]
        ; "authorization custom role", [ gcp_auth_role ]
        ]
      gcp_target
      ~cluster_name:"acme-prod"
  in
  (match find_class "authorization service account" observations with
   | Some (Sol_cli_absence.Present _) -> ()
   | _ -> Windtrap.fail "the authorization service account was not observed");
  match find_class "authorization custom role" observations with
  | Some (Sol_cli_absence.Present _) -> ()
  | _ -> Windtrap.fail "the authorization custom role was not observed"
;;

let gcp_target_without_trust =
  { gcp_target with provider_fields = [ "gcp", [ "project_id", "acme-project" ] ] }
;;

let%test
    "authorization: GCP identities are observed after the trust declaration is removed"
  =
  with_fake_command
    "gcloud"
    (gcp_script ~service_accounts:gcp_auth_identity ~roles:gcp_auth_role ())
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations
      ~authorization_identities:
        [ "authorization service account", [ gcp_auth_identity ]
        ; "authorization custom role", [ gcp_auth_role ]
        ]
      gcp_target_without_trust
      ~cluster_name:"acme-prod"
  in
  match find_class "authorization service account" observations with
  | Some (Sol_cli_absence.Present _) -> ()
  | _ ->
    Windtrap.fail
      "an absent current trust declaration must not skip the historical authorization \
       root"
;;

let gcp_project_bindings =
  "projects/acme-project/roles/sol_acme_prod_cluster_access\tserviceAccount:acme-prod-provisioner@acme-project.iam.gserviceaccount.com\n\
   projects/acme-project/roles/sol_acme_prod_cert_manager_dns_discovery\tserviceAccount:acme-prod-cert-manager@acme-project.iam.gserviceaccount.com\n\
   projects/acme-project/roles/sol_prod_authorization\tserviceAccount:sol-prod-authorization@acme-project.iam.gserviceaccount.com\n"
;;

let%test "authorization: GCP project IAM bindings survive their principals" =
  with_fake_command
    "gcloud"
    (gcp_script
       ~project_policy:gcp_project_bindings
       ~service_accounts:gcp_auth_identity
       ~roles:gcp_auth_role
       ())
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations
      ~authorization_identities:
        [ ( "provisioner project IAM binding"
          , [ "projects/acme-project/roles/sol_acme_prod_cluster_access\tserviceAccount:acme-prod-provisioner@acme-project.iam.gserviceaccount.com"
            ] )
        ; ( "cert-manager DNS discovery project IAM binding"
          , [ "projects/acme-project/roles/sol_acme_prod_cert_manager_dns_discovery\tserviceAccount:acme-prod-cert-manager@acme-project.iam.gserviceaccount.com"
            ] )
        ; ( "authorization project IAM binding"
          , [ "projects/acme-project/roles/sol_prod_authorization\tserviceAccount:sol-prod-authorization@acme-project.iam.gserviceaccount.com"
            ] )
        ]
      gcp_target
      ~cluster_name:"acme-prod"
  in
  List.iter
    (fun resource_class ->
       match find_class resource_class observations with
       | Some (Sol_cli_absence.Present _) -> ()
       | _ -> Windtrap.failf "%s was not observed" resource_class)
    [ "provisioner project IAM binding"
    ; "cert-manager DNS discovery project IAM binding"
    ; "authorization project IAM binding"
    ]
;;

let gcp_project_bindings_near_match =
  "projects/acme-project/roles/sol_acme_prod_cluster_access_extra\tserviceAccount:acme-prod-provisioner@acme-project.iam.gserviceaccount.com\n\
   projects/acme-project/roles/sol_acme_prod_cluster_access\tserviceAccount:acme-prod-provisioner@acme-project.iam.gserviceaccount.com.evil\n"
;;

let%test "authorization: a near-match project binding is not that binding" =
  with_fake_command
    "gcloud"
    (gcp_script
       ~project_policy:gcp_project_bindings_near_match
       ~service_accounts:gcp_auth_identity
       ~roles:gcp_auth_role
       ())
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations
      ~authorization_identities:
        [ ( "provisioner project IAM binding"
          , [ "projects/acme-project/roles/sol_acme_prod_cluster_access\tserviceAccount:acme-prod-provisioner@acme-project.iam.gserviceaccount.com"
            ] )
        ]
      gcp_target
      ~cluster_name:"acme-prod"
  in
  match find_class "provisioner project IAM binding" observations with
  | Some (Sol_cli_absence.Absent _) -> ()
  | _ ->
    Windtrap.fail
      "a role or member that merely contains the expected text must not be attributed"
;;

let gcp_secret_policy =
  {|{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["serviceAccount:acme-project.svc.id.goog[app/charge-svc]"]}]}|}
;;

let%test "authorization: GCP secret IAM bindings are observed" =
  with_fake_command
    "gcloud"
    (gcp_script
       ~secrets:"sol-prod-db-password\n"
       ~secret_policy:gcp_secret_policy
       ~service_accounts:gcp_auth_identity
       ~roles:gcp_auth_role
       ())
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations
      ~authorization_identities:
        [ ( "authorization secret IAM binding"
          , [ "sol-prod-db-password: roles/secretmanager.secretAccessor -> \
               serviceAccount:acme-project.svc.id.goog[app/charge-svc]"
            ] )
        ]
      gcp_target
      ~cluster_name:"acme-prod"
  in
  match find_class "authorization secret IAM binding" observations with
  | Some (Sol_cli_absence.Present present) ->
    Windtrap.equal
      Windtrap.int
      ~msg:"the secret binding is reported"
      1
      (List.length present.found)
  | _ -> Windtrap.fail "the authorization secret IAM binding was not observed"
;;

let%test "authorization: an empty filtered secret list with the benign warning is absent" =
  with_fake_command
    "gcloud"
    (gcp_script
       ~secrets_stderr:
         "WARNING: The following filter keys were not present in any resource : name\n"
       ~service_accounts:gcp_auth_identity
       ~roles:gcp_auth_role
       ())
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations
      ~authorization_identities:[ "authorization secret IAM binding", [] ]
      gcp_target
      ~cluster_name:"acme-prod"
  in
  match find_class "authorization secret IAM binding" observations with
  | Some (Sol_cli_absence.Absent _) -> ()
  | _ ->
    Windtrap.fail
      "an empty filtered secret listing with the documented warning is absence, not \
       UNKNOWN"
;;

let%test "authorization: AWS workload roles are target-scoped by the auth state" =
  with_fake_command
    "aws"
    (aws_script
       ~roles:"sol-prod-authorization\n"
       ~workload_roles:"sol-prod-this-target\nsol-prod-other-target\n"
       ~roles_exit:0
       ())
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations
      ~authorization_identities:
        [ "authorization workload role", [ "sol-prod-this-target" ] ]
      aws_target
      ~cluster_name:"acme-prod"
  in
  match find_class "authorization workload role" observations with
  | Some (Sol_cli_absence.Present present) ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"another target's environment-level role is not this target's residue"
      [ "sol-prod-this-target" ]
      present.found
  | _ -> Windtrap.fail "the target's own workload role was not observed"
;;

let%test "authorization: GCP project bindings are target-scoped by the auth state" =
  let this_binding =
    "projects/acme-project/roles/sol_acme_prod_cluster_access\tserviceAccount:acme-prod-provisioner@acme-project.iam.gserviceaccount.com"
  in
  let other_binding =
    "projects/acme-project/roles/sol_acme_prod_cluster_access\tserviceAccount:acme-prod-other-provisioner@acme-project.iam.gserviceaccount.com"
  in
  with_fake_command
    "gcloud"
    (gcp_script
       ~project_policy:(this_binding ^ "\n" ^ other_binding ^ "\n")
       ~service_accounts:gcp_auth_identity
       ~roles:gcp_auth_role
       ())
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations
      ~authorization_identities:[ "provisioner project IAM binding", [ this_binding ] ]
      gcp_target
      ~cluster_name:"acme-prod"
  in
  match find_class "provisioner project IAM binding" observations with
  | Some (Sol_cli_absence.Present present) ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"another target's project binding is not this target's residue"
      [ this_binding ]
      present.found
  | _ -> Windtrap.fail "the target's own project binding was not observed"
;;

let gcp_authorization_state () =
  Sol_cli_cloud_destroy.inventory_of_show_json
    {|{"values":{"root_module":{"resources":[
      {"address":"google_project_iam_custom_role.reconciler","type":"google_project_iam_custom_role","values":{"name":"projects/acme-project/roles/sol_prod_authorization"}},
      {"address":"google_service_account.reconciler","type":"google_service_account","values":{"email":"sol-prod-authorization@acme-project.iam.gserviceaccount.com"}},
      {"address":"google_project_iam_member.reconciler","type":"google_project_iam_member","values":{"role":"projects/acme-project/roles/sol_prod_authorization","member":"serviceAccount:sol-prod-authorization@acme-project.iam.gserviceaccount.com"}},
      {"address":"google_secret_manager_secret_iam_member.workload","type":"google_secret_manager_secret_iam_member","values":{"secret_id":"projects/acme-project/secrets/sol-prod-db-password","role":"roles/secretmanager.secretAccessor","member":"serviceAccount:acme-project.svc.id.goog[app/charge-svc]"}}
    ]}}}|}
;;

let%test "authorization: GCP state preserves every provider identity representation" =
  let identities =
    Sol_cli_authorization_stage.identities_of_state
      ~target:gcp_target_without_trust
      (gcp_authorization_state ())
  in
  Windtrap.equal
    (Windtrap.list (Windtrap.pair Windtrap.string (Windtrap.list Windtrap.string)))
    [ "authorization service account", [ String.trim gcp_auth_identity ]
    ; "authorization custom role", [ String.trim gcp_auth_role ]
    ; ( "authorization project IAM binding"
      , [ "projects/acme-project/roles/sol_prod_authorization\tserviceAccount:sol-prod-authorization@acme-project.iam.gserviceaccount.com"
        ] )
    ; ( "authorization secret IAM binding"
      , [ "sol-prod-db-password: roles/secretmanager.secretAccessor -> \
           serviceAccount:acme-project.svc.id.goog[app/charge-svc]"
        ] )
    ]
    identities
;;

let%test "authorization: GCP role surviving state removal is residue, not absence" =
  let identities =
    Sol_cli_authorization_stage.identities_of_state
      ~target:gcp_target_without_trust
      (gcp_authorization_state ())
  in
  with_fake_command "gcloud" (gcp_script ~service_accounts:"" ~roles:gcp_auth_role ())
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations
      ~authorization_identities:identities
      gcp_target_without_trust
      ~cluster_name:"acme-prod"
  in
  match find_class "authorization custom role" observations with
  | Some (Sol_cli_absence.Present present as observation) ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      [ String.trim gcp_auth_role ]
      present.found;
    Windtrap.equal
      Windtrap.bool
      false
      (Sol_cli_absence.permits_absence_claim (Sol_cli_absence.verdict [ observation ]))
  | _ ->
    Windtrap.fail
      "a surviving role named by pre-destroy state must block verified absence"
;;

let%test "authorization: GCP secret bindings retain state identity for provider names" =
  let identities =
    Sol_cli_authorization_stage.identities_of_state
      ~target:gcp_target_without_trust
      (gcp_authorization_state ())
  in
  List.iter
    (fun secret ->
       with_fake_command
         "gcloud"
         (gcp_script
            ~secrets:(secret ^ "\n")
            ~secret_policy:gcp_secret_policy
            ~service_accounts:""
            ~roles:""
            ())
       @@ fun () ->
       let observations =
         Sol_cli_gcp_absence.observations
           ~authorization_identities:identities
           gcp_target_without_trust
           ~cluster_name:"acme-prod"
       in
       match find_class "authorization secret IAM binding" observations with
       | Some (Sol_cli_absence.Present present as observation) ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           [ "sol-prod-db-password: roles/secretmanager.secretAccessor -> \
              serviceAccount:acme-project.svc.id.goog[app/charge-svc]"
           ]
           present.found;
         Windtrap.equal
           Windtrap.bool
           false
           (Sol_cli_absence.permits_absence_claim
              (Sol_cli_absence.verdict [ observation ]))
       | _ ->
         Windtrap.fail ("a surviving secret IAM binding must block absence: " ^ secret))
    [ "sol-prod-db-password"; "projects/acme-project/secrets/sol-prod-db-password" ]
;;

let%test "authorization: malformed STS credentials do not escape through JSON diagnostics"
  =
  let canary = "STS_SECRET_CANARY_DO_NOT_DISCLOSE" in
  let script =
    Printf.sprintf
      "#!/bin/sh\nprintf '%%s' %s\n"
      (Filename.quote ("{\"Credentials\":{\"SecretAccessKey\":" ^ canary))
  in
  with_fake_command "aws" script (fun () ->
    match
      Sol_cli_provider_capabilities.aws.authorization_assumption
        (Reconciler_role "arn:aws:iam::111122223333:role/sol-authorization")
    with
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"parser input is confidential"
        false
        (Sol_cli_string.contains ~needle:canary message)
    | Ok _ -> Windtrap.fail "malformed STS credentials must fail")
;;

let%test
    "Kafka authority: AWS missing, pending deletion, unreadable and wrong identity \
     remain distinct"
  =
  let name = "sol-kafka-acme-prod" in
  List.iter
    (fun (status, stdout, stderr, expected) ->
       let script =
         Printf.sprintf
           {|#!/bin/sh
case "$*" in
  *"sts get-caller-identity"*) printf '111122223333\n' ;;
  *"secretsmanager describe-secret --secret-id sol-kafka-acme-prod --region us-east-1 --query {name:Name,deleted:DeletedDate,stages:VersionIdsToStages} --output json"*)
    printf '%%s' %s
    printf '%%s' %s >&2
    exit %d
    ;;
esac
|}
           (Filename.quote stdout)
           (Filename.quote stderr)
           status
       in
       with_fake_command "aws" script (fun () ->
         let observations =
           Sol_cli_aws_absence.observations aws_target ~cluster_name:"acme-prod"
         in
         match find_class "Kafka credential secret" observations, expected with
         | Some (Sol_cli_absence.Present p), `Present ->
           Windtrap.equal (Windtrap.list Windtrap.string) [ name ] p.found
         | Some (Sol_cli_absence.Absent _), `Absent -> ()
         | Some (Sol_cli_absence.Unobservable _), `Unknown -> ()
         | _ ->
           Windtrap.fail "the exact-name authority read produced an incorrect verdict"))
    [ (* A scheduled deletion still permits DescribeSecret's Name read. *)
      0, {|{"name":"sol-kafka-acme-prod","deleted":1700000000,"stages":{}}|}, "", `Present
    ; ( 254
      , ""
      , "An error occurred (ResourceNotFoundException) when calling the DescribeSecret \
         operation"
      , `Absent )
    ; 254, "", "AccessDeniedException", `Unknown
    ; 254, "", "region not found", `Unknown
    ; 0, "", "", `Unknown
    ; 0, {|{"name":"another-target"}|}, "", `Unknown
    ; 0, {|{"name":"sol-kafka-acme-prod"}|}, "WARNING: incomplete response", `Unknown
    ]
;;

let%test
    "Kafka authority: independent observations authorize only a genuinely absent native \
     installation"
  =
  let script =
    {|#!/bin/sh
case "$*" in
  *"sts get-caller-identity"*) printf '111122223333\n' ;;
  *"secretsmanager describe-secret"*)
    printf 'An error occurred (ResourceNotFoundException) when calling the DescribeSecret operation' >&2
    exit 254 ;;
esac
|}
  in
  with_fake_command "aws" script (fun () ->
    match
      Sol_cli_provider_registry.kafka_initialization_evidence
        Sol_cli_provider.Aws
        aws_target
        ~cluster_name:"acme-prod"
        ~namespace:"redpanda"
        ~observe_broker:(fun () ->
          Windtrap.fail "an absent cluster must not require Kubernetes access")
    with
    | Error message -> Windtrap.fail message
    | Ok evidence ->
      (match Sol_cli_kafka_authority.check_initial_absence evidence with
       | Ok () -> ()
       | Error message -> Windtrap.fail message))
;;

let assert_kafka_storage = function
  | Sol_cli_absence.Present _, `Present | Absent _, `Absent | Unobservable _, `Unknown ->
    ()
  | _ -> Windtrap.fail "Kafka initialization misclassified the storage obligation"
;;

let storage_identity resource_class identity =
  Sol_cli_absence.Present
    { resource_class
    ; identity
    ; found = [ identity ]
    ; attribution = Within_target "target inventory"
    ; checked_with = "provider inventory"
    }
;;

let%test
    "Kafka initialization distinguishes AWS broker, unrelated, boot and unattributable \
     disks"
  =
  let volume ?claim ?(attachments = []) ?(identity = "vol-target") () =
    `Assoc
      [ ( "Volumes"
        , `List
            [ `Assoc
                [ "VolumeId", `String identity
                ; ( "Tags"
                  , `List
                      (match claim with
                       | None -> []
                       | Some namespace ->
                         [ `Assoc
                             [ "Key", `String "kubernetes.io/created-for/pvc/namespace"
                             ; "Value", namespace
                             ]
                         ]) )
                ; "Attachments", `List attachments
                ]
            ] )
      ]
  in
  let attached = [ `Assoc [ "InstanceId", `String "i-target" ] ] in
  let instance root_volume =
    let mapping =
      `Assoc
        [ "DeviceName", `String "/dev/xvda"
        ; "Ebs", `Assoc [ "VolumeId", `String root_volume ]
        ]
    in
    let details =
      `Assoc
        [ "InstanceId", `String "i-target"
        ; "RootDeviceName", `String "/dev/xvda"
        ; "BlockDeviceMappings", `List [ mapping ]
        ]
    in
    `Assoc [ "Reservations", `List [ `Assoc [ "Instances", `List [ details ] ] ] ]
  in
  List.iter
    (fun (disk, boot, expected) ->
       let script =
         Printf.sprintf
           {|#!/bin/sh
case "$*" in
  *"ec2 describe-volumes --volume-ids vol-target --region us-east-1 --output json"*) printf '%%s' %s ;;
  *"ec2 describe-instances --instance-ids i-target --region us-east-1 --output json"*) printf '%%s' %s ;;
  *) exit 91 ;;
esac
|}
           (Filename.quote (Yojson.Safe.to_string disk))
           (Filename.quote (Yojson.Safe.to_string boot))
       in
       with_fake_command "aws" script (fun () ->
         let observation =
           Sol_cli_aws_absence.kafka_storage
             ~region:"us-east-1"
             ~namespace:"redpanda"
             (storage_identity "EBS volume" "vol-target")
         in
         assert_kafka_storage (observation, expected)))
    [ volume ~claim:(`String "redpanda") (), `Null, `Present
    ; volume ~claim:(`String "monitoring") (), `Null, `Absent
    ; volume (), `Null, `Unknown
    ; volume ~claim:(`Int 1) (), `Null, `Unknown
    ; volume ~identity:"vol-other" ~claim:(`String "monitoring") (), `Null, `Unknown
    ; volume ~attachments:attached (), instance "vol-target", `Absent
    ; volume ~attachments:attached (), instance "vol-other", `Unknown
    ; volume ~attachments:attached (), `Null, `Unknown
    ]
;;

let%test
    "Kafka initialization distinguishes GCP broker, unrelated, boot and unattributable \
     disks"
  =
  let identity =
    "https://www.googleapis.com/compute/v1/projects/acme-project/zones/us-central1-a/disks/target"
  in
  let user =
    "https://www.googleapis.com/compute/v1/projects/acme-project/zones/us-central1-a/instances/node"
  in
  let disk ?description ?(users = []) () =
    `Assoc
      ([ "selfLink", `String identity; "users", `List users ]
       @
       match description with
       | None -> []
       | Some description -> [ "description", description ])
  in
  let claim namespace =
    `String
      (Yojson.Safe.to_string
         (`Assoc [ "kubernetes.io/created-for/pvc/namespace", namespace ]))
  in
  let instance boot =
    `Assoc
      [ "selfLink", `String user
      ; "disks", `List [ `Assoc [ "source", `String identity; "boot", `Bool boot ] ]
      ]
  in
  List.iter
    (fun (disk, boot, expected) ->
       let script =
         Printf.sprintf
           {|#!/bin/sh
case "$*" in
  *"compute disks describe target --project acme-project --format json --zone us-central1-a"*) printf '%%s' %s ;;
  *"compute instances describe node --project acme-project --format json --zone us-central1-a"*) printf '%%s' %s ;;
  *) exit 91 ;;
esac
|}
           (Filename.quote (Yojson.Safe.to_string disk))
           (Filename.quote (Yojson.Safe.to_string boot))
       in
       with_fake_command "gcloud" script (fun () ->
         let observation =
           Sol_cli_gcp_absence.kafka_storage
             gcp_target
             ~namespace:"redpanda"
             (storage_identity "persistent disk" identity)
         in
         assert_kafka_storage (observation, expected)))
    [ disk ~description:(claim (`String "redpanda")) (), `Null, `Present
    ; disk ~description:(claim (`String "monitoring")) (), `Null, `Absent
    ; disk (), `Null, `Unknown
    ; disk ~description:(claim (`Int 1)) (), `Null, `Unknown
    ; disk ~description:(`String "{") (), `Null, `Unknown
    ; disk ~users:[ `String user ] (), instance true, `Absent
    ; disk ~users:[ `String user ] (), instance false, `Unknown
    ; disk ~users:[ `String user ] (), `Null, `Unknown
    ]
;;

let authority_is expected = function
  | Sol_cli_kafka_authority.Authority_current ->
    Windtrap.equal Windtrap.string ~msg:"Kafka authority state" "current" expected
  | Sol_cli_kafka_authority.Authority_missing _ ->
    Windtrap.equal Windtrap.string ~msg:"Kafka authority state" "missing" expected
  | Sol_cli_kafka_authority.Authority_unobservable _ ->
    Windtrap.equal Windtrap.string ~msg:"Kafka authority state" "unknown" expected
;;

let aws_authority_script stdout exit_code stderr =
  Printf.sprintf
    {|#!/bin/sh
case "$*" in
  *"secretsmanager describe-secret "*) printf '%%s' %s ; printf '%%s' %s >&2 ; exit %d ;;
  *) exit 91 ;;
esac
|}
    (Filename.quote stdout)
    (Filename.quote stderr)
    exit_code
;;

let%test "AWS Kafka authority requires an existing secret with an active version" =
  let observe stdout exit_code stderr expected =
    with_fake_command "aws" (aws_authority_script stdout exit_code stderr) (fun () ->
      Sol_cli_aws_absence.kafka_authority ~region:"us-east-1" ~cluster_name:"acme-prod"
      |> authority_is expected)
  in
  observe
    {|{"name":"sol-kafka-acme-prod","deleted":null,"stages":{"v1":["AWSCURRENT"]}}|}
    0
    ""
    "current";
  observe {|{"name":"sol-kafka-acme-prod","deleted":null,"stages":{}}|} 0 "" "missing";
  observe
    {|{"name":"sol-kafka-acme-prod","deleted":1700000000,"stages":{"v1":["AWSCURRENT"]}}|}
    0
    ""
    "missing";
  observe
    ""
    254
    "An error occurred (ResourceNotFoundException) when calling the DescribeSecret \
     operation"
    "missing";
  observe
    {|{"name":"another-target","deleted":null,"stages":{"v1":["AWSCURRENT"]}}|}
    0
    ""
    "unknown";
  observe {|{"deleted":null,"stages":{"v1":["AWSCURRENT"]}}|} 0 "" "unknown";
  observe "" 254 "An error occurred (AccessDeniedException)" "unknown"
;;

let gcp_authority_script stdout exit_code stderr =
  Printf.sprintf
    {|#!/bin/sh
case "$*" in
  *"secrets versions list "*) printf '%%s' %s ; printf '%%s' %s >&2 ; exit %d ;;
  *) exit 91 ;;
esac
|}
    (Filename.quote stdout)
    (Filename.quote stderr)
    exit_code
;;

let%test "GCP Kafka authority requires an enabled secret version" =
  let observe stdout exit_code stderr expected =
    with_fake_command "gcloud" (gcp_authority_script stdout exit_code stderr) (fun () ->
      Sol_cli_gcp_absence.kafka_authority gcp_target ~cluster_name:"acme-prod"
      |> authority_is expected)
  in
  observe "1\n" 0 "" "current";
  observe "" 0 "" "missing";
  observe
    ""
    1
    "ERROR: (gcloud.secrets.versions.list) NOT_FOUND: Secret \
     [projects/acme-project/secrets/sol-kafka-acme-prod] not found"
    "missing";
  observe "" 1 "ERROR: (gcloud.secrets.versions.list) PERMISSION_DENIED" "unknown"
;;
