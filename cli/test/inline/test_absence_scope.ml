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
  ; provider_fields = [ "gcp", [ "project_id", "acme-project" ] ]
  ; secret_authorities = []
  }
;;

let target_aws
      ?(fields =
        [ "provisioner_role_arn", "arn:aws:iam::111122223333:role/acme-provisioner" ])
      ()
  : Sol_cli_config.target
  =
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
  ; provider_fields = (if fields = [] then [] else [ "aws", fields ])
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

let describe observations =
  String.concat " | " (List.map Sol_cli_absence.summary observations)
;;

let find_class resource_class observations =
  List.find_opt
    (fun observation -> String.equal (class_of observation) resource_class)
    observations
;;

let no_absent observations =
  not
    (List.exists
       (function
         | Sol_cli_absence.Absent _ -> true
         | _ -> false)
       observations)
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

let write_executable path script =
  Out_channel.with_open_text path (fun oc -> output_string oc script);
  Unix.chmod path 0o755
;;

let with_fake_command name script f =
  let dir = Filename.temp_file ("sol-fake-" ^ name ^ "-") "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir name in
  write_executable bin script;
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

let gcp_script =
  {|#!/bin/sh
printf '%s\n' "$*" >> "$SOL_FAKE_GCLOUD_LOG"
case "$*" in
  *" projects describe "*)
    printf '%s' "${SOL_PROJECT_OUT:-}"
    printf '%s' "${SOL_PROJECT_ERR:-}" >&2
    exit "${SOL_PROJECT_RC:-0}"
    ;;
  *" compute regions describe "*)
    printf '%s' "${SOL_REGION_OUT:-}"
    printf '%s' "${SOL_REGION_ERR:-}" >&2
    exit "${SOL_REGION_RC:-0}"
    ;;
  *" auth list "*)
    printf 'scope-caller@example.com\n'
    exit 0
    ;;
  *" container clusters list "*)
    printf '%s' "${SOL_CLUSTER_OUT:-}"
    printf '%s' "${SOL_CLUSTER_ERR:-}" >&2
    exit "${SOL_CLUSTER_RC:-0}"
    ;;
  *" container node-pools list "*)
    printf '%s' "${SOL_NODE_POOLS_OUT:-}"
    printf '%s' "${SOL_NODE_POOLS_ERR:-}" >&2
    exit "${SOL_NODE_POOLS_RC:-0}"
    ;;
  *" compute routers list "*)
    printf '%s' "${SOL_ROUTER_OUT:-}"
    exit 0
    ;;
  *" routers nats list "*)
    exit 0
    ;;
esac
exit 0
|}
;;

let with_gcloud values f =
  with_fake_command "gcloud" gcp_script (fun ~log ->
    with_env (("SOL_FAKE_GCLOUD_LOG", log) :: values) f)
;;

let gcp_scope_ok =
  [ "SOL_PROJECT_OUT", "acme-project\n"; "SOL_REGION_OUT", "us-central1\n" ]
;;

let%test "scope: a nonexistent GCP project cannot establish absence" =
  with_gcloud
    ([ "SOL_PROJECT_OUT", ""
     ; "SOL_PROJECT_ERR", "ERROR: Project acme-project was not found.\n"
     ; "SOL_PROJECT_RC", "1"
     ]
     @ gcp_scope_ok)
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations target_gcp ~cluster_name:"acme-prod"
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"no class is reported absent from an unestablished project"
    true
    (no_absent observations);
  match find_class "the provider scope" observations with
  | Some (Sol_cli_absence.Unobservable u) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the provider diagnostic is preserved"
      true
      (Sol_cli_string.contains ~needle:"was not found" u.reason)
  | _ -> Windtrap.fail "a project-not-found answer must be an unobservable scope"
;;

let%test "scope: a failed GCP list is unobservable, not absent" =
  with_gcloud
    (gcp_scope_ok
     @ [ "SOL_CLUSTER_ERR", "ERROR: NOT_FOUND: the resource was not found\n"
       ; "SOL_CLUSTER_RC", "1"
       ])
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations target_gcp ~cluster_name:"acme-prod"
  in
  match find_class "GKE cluster" observations with
  | Some (Sol_cli_absence.Unobservable _) -> ()
  | Some (Sol_cli_absence.Absent _) ->
    Windtrap.fail "a failed list command was read as absence"
  | _ -> Windtrap.fail "the GKE cluster class was not observed"
;;

let%test "scope: a child of a positively absent parent may be absent" =
  with_gcloud
    (gcp_scope_ok
     @ [ "SOL_NODE_POOLS_ERR", "ERROR: cluster acme-prod was not found\n"
       ; "SOL_NODE_POOLS_RC", "1"
       ])
  @@ fun () ->
  let observations =
    Sol_cli_gcp_absence.observations target_gcp ~cluster_name:"acme-prod"
  in
  (match find_class "GKE cluster" observations with
   | Some (Sol_cli_absence.Absent _) -> ()
   | _ -> Windtrap.fail "the fixture's parent cluster must be absent");
  match find_class "GKE node pool" observations with
  | Some (Sol_cli_absence.Absent _) -> ()
  | Some (Sol_cli_absence.Unobservable _) ->
    Windtrap.fail "a child of a positively absent parent was left unobservable"
  | _ -> Windtrap.fail "the node-pool class was not observed"
;;

let%test "scope: substrate absence is unobservable without a project scope" =
  with_gcloud
    [ "SOL_PROJECT_OUT", ""
    ; "SOL_PROJECT_ERR", "ERROR: Project acme-project was not found.\n"
    ; "SOL_PROJECT_RC", "1"
    ; "SOL_REGION_OUT", "us-central1\n"
    ]
  @@ fun () ->
  match Sol_cli_gcp_absence.substrate_absence target_gcp ~cluster_name:"acme-prod" with
  | Sol_cli_absence.Unobservable u ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the substrate is not absent on a scope failure"
      true
      (Sol_cli_string.contains ~needle:"was not found" u.reason)
  | _ -> Windtrap.fail "a scope failure was read as substrate absence"
;;

let aws_script =
  {|#!/bin/sh
printf '%s\n' "$*" >> "$SOL_FAKE_AWS_LOG"
case "$*" in
  *"sts get-caller-identity "*)
    printf '%s' "${SOL_IDENTITY_OUT:-}"
    printf '%s' "${SOL_IDENTITY_ERR:-}" >&2
    exit "${SOL_IDENTITY_RC:-0}"
    ;;
  *"eks list-clusters "*)
    printf '%s' "${SOL_CLUSTER_OUT:-}"
    printf '%s' "${SOL_CLUSTER_ERR:-}" >&2
    exit "${SOL_CLUSTER_RC:-0}"
    ;;
esac
exit 0
|}
;;

let with_aws values f =
  with_fake_command "aws" aws_script (fun ~log ->
    with_env (("SOL_FAKE_AWS_LOG", log) :: values) f)
;;

let%test "scope: a wrong AWS account cannot establish absence" =
  with_aws [ "SOL_IDENTITY_OUT", "444455556666\n" ]
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations (target_aws ()) ~cluster_name:"acme-prod"
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"no class is reported absent from another account"
    true
    (no_absent observations);
  match find_class "the provider scope" observations with
  | Some (Sol_cli_absence.Unobservable u) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"both accounts are named"
      true
      (Sol_cli_string.contains ~needle:"444455556666" u.reason
       && Sol_cli_string.contains ~needle:"111122223333" u.reason)
  | _ ->
    Windtrap.failf
      "a wrong-account answer must be an unobservable scope: %s"
      (describe observations)
;;

let%test "scope: a failed AWS list is unobservable, not absent" =
  with_aws
    [ "SOL_IDENTITY_OUT", "111122223333\n"
    ; ( "SOL_CLUSTER_ERR"
      , "An error occurred (ResourceNotFoundException) when calling the ListClusters \
         operation\n" )
    ; "SOL_CLUSTER_RC", "254"
    ]
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations (target_aws ()) ~cluster_name:"acme-prod"
  in
  match find_class "EKS cluster" observations with
  | Some (Sol_cli_absence.Unobservable _) -> ()
  | Some (Sol_cli_absence.Absent _) ->
    Windtrap.fail "a failed list command was read as absence"
  | _ ->
    Windtrap.failf "the EKS cluster class was not observed: %s" (describe observations)
;;

let%test "scope: an AWS target without an authoritative account is unobservable" =
  with_aws [ "SOL_IDENTITY_OUT", "111122223333\n" ]
  @@ fun () ->
  let observations =
    Sol_cli_aws_absence.observations (target_aws ~fields:[] ()) ~cluster_name:"acme-prod"
  in
  match find_class "the provider scope" observations with
  | Some (Sol_cli_absence.Unobservable u) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the missing contract is named"
      true
      (Sol_cli_string.contains ~needle:"authoritative AWS account identity" u.reason)
  | _ -> Windtrap.fail "a target with no account identity must not establish absence"
;;

let state_with_cluster =
  {|{"values":{"root_module":{"resources":[{"address":"module.eks.aws_eks_cluster.this[0]","type":"aws_eks_cluster","values":{"name":"acme-prod"}}]}}}|}
;;

let assets () =
  match Sol_cli_platform_assets.resolve () with
  | Ok assets -> assets
  | Error error -> Windtrap.fail (Sol_cli_platform_assets.error_to_string error)
;;

let fake_terraform =
  {|#!/bin/sh
printf '%s\n' "$*" >> "$SOL_FAKE_TERRAFORM_LOG"
exit 0
|}
;;

let%test "scope: a wrong AWS account never authorizes state rm" =
  with_fake_command "terraform" fake_terraform (fun ~log:terraform_log ->
    with_aws [ "SOL_IDENTITY_OUT", "444455556666\n" ]
    @@ fun () ->
    let infra = Filename.dirname terraform_log in
    let base = Filename.concat infra "run-log" in
    Unix.mkdir base 0o755;
    let run_log = Sol_cli_run_log.create ~base ~prefix:"test" () in
    let state = Sol_cli_cloud_destroy.inventory_of_show_json state_with_cluster in
    match
      Sol_cli_cloud_wiring.provable_absence_reconciliation
        ~assets:(assets ())
        ~run_log
        ~provider:Sol_cli_provider.Aws
        ~target_cfg:(target_aws ())
        ~infra_dir:infra
        ~platform_dir:infra
        ~platform_backend:[]
        ~var_files:[]
        ~vars:[ "cluster_name=acme-prod" ]
        ~state
    with
    | Ok Sol_cli_cloud_destroy.Nothing_to_reconcile ->
      let calls =
        try In_channel.with_open_text terraform_log In_channel.input_all with
        | Sys_error _ -> ""
      in
      Windtrap.equal
        Windtrap.bool
        ~msg:"no state entry was forgotten from an unobservable account"
        false
        (Sol_cli_string.contains ~needle:"state rm" calls)
    | Ok (Sol_cli_cloud_destroy.Reconciled _) ->
      Windtrap.fail "a wrong account authorized state removal"
    | Error message ->
      Windtrap.failf
        "an unobservable account is a refusal to forget, not a failed run: %s"
        message)
;;

let scope_observation reason =
  Sol_cli_absence.Unobservable
    { resource_class = Sol_cli_absence.scope_class
    ; reason
    ; checked_with = "aws sts get-caller-identity"
    }
;;

let%test "scope: a scope failure cannot produce a verified destruction" =
  let sweep =
    Sol_cli_absence.to_sweep [ scope_observation "the caller was another account" ]
  in
  let observation : Sol_cli_destroy_verification.observation =
    { state = State_absent
    ; sweep
    ; retention = Retention_not_required "no retention surface"
    }
  in
  let verdict = Sol_cli_destroy_verification.classify observation in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a scope failure is not a verified destruction"
    false
    (Sol_cli_destroy_verification.is_verified verdict);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the failure explains that absence is not established"
    true
    (List.exists
       (fun violation ->
          Sol_cli_string.contains ~needle:"cannot establish absence" violation)
       verdict.violations)
;;

let%test "scope: an ordinary failed residue probe still degrades rather than fails" =
  let observation =
    Sol_cli_absence.Unobservable
      { resource_class = "EBS volume"
      ; reason = "the provider throttled the read"
      ; checked_with = "aws ec2 describe-volumes"
      }
  in
  match Sol_cli_absence.to_sweep [ observation ] with
  | Sol_cli_destroy_verification.Sweep_ran { residues = []; indeterminate = [ _ ] } -> ()
  | Sol_cli_destroy_verification.Sweep_ran { residues = _ :: _; _ } ->
    Windtrap.fail "an ordinary failed residue probe was promoted to a violation"
  | _ -> Windtrap.fail "the failed residue probe was not recorded as indeterminate"
;;
