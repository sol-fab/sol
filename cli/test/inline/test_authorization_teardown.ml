let aws_fields =
  [ "provisioner_role_arn", "arn:aws:iam::111122223333:role/acme-provisioner"
  ; "reconciler_trust_principal_arn", "arn:aws:iam::111122223333:role/ci"
  ; "state_lock_table", "acme-lock"
  ]
;;

let target_aws : Sol_cli_config.target =
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
  ; state_bucket = Some "acme-state"
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; shape = Some Sol_cli_profile.Local
  ; provider_fields = [ "aws", aws_fields ]
  ; secret_authorities = []
  }
;;

let target_gcp : Sol_cli_config.target =
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

let without_authorization (target : Sol_cli_config.target) =
  { target with
    provider_fields =
      List.map
        (fun (provider, fields) ->
           ( provider
           , List.filter
               (fun (key, _) ->
                  not
                    (List.mem
                       key
                       [ "reconciler_trust_principal_arn"; "reconciler_trust_principal" ]))
               fields ))
        target.provider_fields
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

let with_env values f =
  let previous = List.map (fun (name, _) -> name, Sys.getenv_opt name) values in
  List.iter (fun (name, value) -> Unix.putenv name value) values;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (name, value) ->
           match value with
           | Some value -> Unix.putenv name value
           | None -> Unix.putenv name "")
        previous)
    f
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
    (fun () -> f ~log)
;;

let aws_script =
  {|#!/bin/sh
printf '%s\n' "$*" >> "$SOL_FAKE_AWS_LOG"
case "$*" in
  *"iam list-roles "*) printf '%s' "${SOL_IAM_ROLES_OUT:-}"; exit 0 ;;
  *"iam list-policies "*) printf '%s' "${SOL_IAM_POLICIES_OUT:-}"; exit 0 ;;
esac
exit 0
|}
;;

let with_aws values f =
  with_fake_command "aws" aws_script (fun ~log ->
    with_env (("SOL_FAKE_AWS_LOG", log) :: values) f)
;;

let%test "authorization: an AWS reconciler role left behind is residue" =
  with_aws [ "SOL_IAM_ROLES_OUT", "sol-prod-authorization\n" ]
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations target_aws ~cluster_name:"acme-prod"
  in
  match find_class "authorization IAM role" observations with
  | Some (Sol_cli_absence.Present _) -> ()
  | Some (Sol_cli_absence.Absent _) ->
    Windtrap.fail
      "the authorization reconciler role was reported absent although it exists"
  | _ -> Windtrap.fail "the authorization IAM role was not observed"
;;

let%test "authorization: AWS identities are absent when the lists are empty" =
  with_aws []
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations target_aws ~cluster_name:"acme-prod"
  in
  (match find_class "authorization IAM role" observations with
   | Some (Sol_cli_absence.Absent _) -> ()
   | _ -> Windtrap.fail "an empty IAM role list did not establish absence");
  match find_class "authorization IAM policy" observations with
  | Some (Sol_cli_absence.Absent _) -> ()
  | _ -> Windtrap.fail "an empty IAM policy list did not establish absence"
;;

let%test "authorization: no authorization checks run when no trust is declared" =
  with_aws [ "SOL_IAM_ROLES_OUT", "sol-prod-authorization\n" ]
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations
      (without_authorization target_aws)
      ~cluster_name:"acme-prod"
  in
  match find_class "authorization IAM role" observations with
  | None -> ()
  | Some _ -> Windtrap.fail "an undeclared authorization root was still observed"
;;

let gcp_script =
  {|#!/bin/sh
printf '%s\n' "$*" >> "$SOL_FAKE_GCLOUD_LOG"
case "$*" in
  *"iam service-accounts list "*) printf '%s' "${SOL_GCP_SA_OUT:-}"; exit 0 ;;
  *"iam roles list "*) printf '%s' "${SOL_GCP_ROLE_OUT:-}"; exit 0 ;;
esac
exit 0
|}
;;

let with_gcloud values f =
  with_fake_command "gcloud" gcp_script (fun ~log ->
    with_env (("SOL_FAKE_GCLOUD_LOG", log) :: values) f)
;;

let%test "authorization: GCP identities are observed by their environment names" =
  with_gcloud
    [ "SOL_GCP_SA_OUT", "sol-prod-authorization@acme-project.iam.gserviceaccount.com\n"
    ; "SOL_GCP_ROLE_OUT", "projects/acme-project/roles/sol_prod_authorization\n"
    ]
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations target_gcp ~cluster_name:"acme-prod"
  in
  (match find_class "authorization service account" observations with
   | Some (Sol_cli_absence.Present _) -> ()
   | _ -> Windtrap.fail "the authorization service account was not observed as present");
  match find_class "authorization custom role" observations with
  | Some (Sol_cli_absence.Present _) -> ()
  | _ -> Windtrap.fail "the authorization custom role was not observed as present"
;;

let%test "authorization: GCP identities are absent when the lists are empty" =
  with_gcloud []
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations target_gcp ~cluster_name:"acme-prod"
  in
  (match find_class "authorization service account" observations with
   | Some (Sol_cli_absence.Absent _) -> ()
   | _ -> Windtrap.fail "an empty service-account list did not establish absence");
  match find_class "authorization custom role" observations with
  | Some (Sol_cli_absence.Absent _) -> ()
  | _ -> Windtrap.fail "an empty role list did not establish absence"
;;

let%test "authorization: destroy fails when its state still represents a resource" =
  let state =
    {|{"values":{"root_module":{"resources":[{"address":"aws_iam_role.reconciler","type":"aws_iam_role","values":{}}]}}}|}
  in
  match Sol_cli_authorization_stage.verify_destroyed_state state with
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the refusal names the remaining authorization resource"
      true
      (Sol_cli_string.contains ~needle:"still represents" message)
  | Ok () ->
    Windtrap.fail
      "terraform destroy's exit status alone was accepted as authorization absence"
;;

let%test "authorization: destroy succeeds only when its state is empty" =
  match Sol_cli_authorization_stage.verify_destroyed_state {|{}|} with
  | Ok () -> ()
  | Error message -> Windtrap.failf "an empty authorization state was refused: %s" message
;;
