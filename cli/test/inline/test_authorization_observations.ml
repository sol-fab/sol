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
  { name = "prod/gcp/us-central1"
  ; env = "prod"
  ; provider = Sol_cli_provider.Gcp
  ; region = "us-central1"
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = Some "acme-prod"
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
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
      [ ( "gcp"
        , [ "project_id", "acme-project"
          ; "reconciler_trust_principal", "user:ci@example.test"
          ] )
      ]
  ; secret_authorities = []
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
  *"secrets list "*) printf '%%s' %s; exit 0 ;;
  *"secrets get-iam-policy "*) printf '%%s' %s; exit 0 ;;
esac
exit 0
|}
    (Filename.quote service_accounts)
    (Filename.quote roles)
    (Filename.quote project_policy)
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
