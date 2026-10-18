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

let aws_script ~roles ~roles_exit =
  Printf.sprintf
    {|#!/bin/sh
case "$*" in
  *"sts get-caller-identity "*) printf '111122223333\n'; exit 0 ;;
  *"iam list-roles "*) printf '%%s' %s; if [ %d -ne 0 ]; then printf 'access denied' >&2; fi; exit %d ;;
  *"iam list-policies "*) exit 0 ;;
esac
exit 0
|}
    (Filename.quote roles)
    roles_exit
    roles_exit
;;

let%test "authorization: AWS role residue is observed and a failed check is strict" =
  with_fake_command "aws" (aws_script ~roles:"sol-prod-authorization\n" ~roles_exit:0)
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations aws_target ~cluster_name:"acme-prod"
  in
  (match find_class "authorization IAM role" observations with
   | Some (Sol_cli_absence.Present _) -> ()
   | _ -> Windtrap.fail "the authorization reconciler role was not observed");
  with_fake_command "aws" (aws_script ~roles:"" ~roles_exit:1)
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations aws_target ~cluster_name:"acme-prod"
  in
  match find_class Sol_cli_absence.scope_class observations with
  | Some (Sol_cli_absence.Unobservable _) -> ()
  | _ ->
    Windtrap.fail "a failed authorization enumeration was not a strict scope observation"
;;

let gcp_script ~service_accounts ~roles =
  Printf.sprintf
    {|#!/bin/sh
case "$*" in
  *"iam service-accounts list "*) printf '%%s' %s; exit 0 ;;
  *"iam roles list "*) printf '%%s' %s; exit 0 ;;
esac
exit 0
|}
    (Filename.quote service_accounts)
    (Filename.quote roles)
;;

let%test "authorization: GCP identity residue is observed by its environment name" =
  with_fake_command
    "gcloud"
    (gcp_script
       ~service_accounts:"sol-prod-authorization@acme-project.iam.gserviceaccount.com\n"
       ~roles:"projects/acme-project/roles/sol_prod_authorization\n")
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations gcp_target ~cluster_name:"acme-prod"
  in
  (match find_class "authorization service account" observations with
   | Some (Sol_cli_absence.Present _) -> ()
   | _ -> Windtrap.fail "the authorization service account was not observed");
  match find_class "authorization custom role" observations with
  | Some (Sol_cli_absence.Present _) -> ()
  | _ -> Windtrap.fail "the authorization custom role was not observed"
;;
