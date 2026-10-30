let target : Sol_cli_config.target =
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
        , [ "provisioner_role_arn", "arn:aws:iam::123456789012:role/sol-provisioner" ] )
      ]
  ; secret_authorities = []
  }
;;

let fake_terraform ~log ~stdout ~exit_code =
  Printf.sprintf
    {|#!/bin/sh
printf '%%s\n' "$*" >> %s
printf '%%s' %s
exit %d
|}
    log
    (Filename.quote stdout)
    exit_code
;;

let with_fake_terraform ~stdout ~exit_code f =
  let dir = Filename.temp_file "sol-fake-terraform-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "terraform" in
  let oc = open_out bin in
  output_string oc (fake_terraform ~log ~stdout ~exit_code);
  close_out oc;
  Unix.chmod bin 0o755;
  let infra = Filename.concat dir "infra" in
  Unix.mkdir infra 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      (try Unix.rmdir infra with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f ~log ~infra)
;;

let reconcile ~infra ~act =
  Sol_cli_cloud_wiring.reconcile_ownership
    ~provider:Sol_cli_provider.Aws
    ~target_cfg:target
    ~cluster_name:"acme-prod"
    ~infra_dir:infra
    ~var_files:[]
    ~vars:[]
    ~act
;;

let imports log =
  In_channel.with_open_text log In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> Sol_cli_string.contains ~needle:"import" line)
;;

let failed_show_is_refused_before_any_import () =
  with_fake_terraform ~stdout:"" ~exit_code:1 (fun ~log ~infra ->
    match reconcile ~infra ~act:true with
    | Ok _ -> Windtrap.fail "an unreadable state must not reconcile successfully"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names the unreadable state"
        true
        (Sol_cli_string.contains ~needle:"could not be read" message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal says nothing is imported"
        true
        (Sol_cli_string.contains ~needle:"ownership is unknown" message);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no import was attempted"
        []
        (imports log))
;;

let malformed_state_is_refused_before_any_import () =
  with_fake_terraform ~stdout:"{ not json" ~exit_code:0 (fun ~log ~infra ->
    match reconcile ~infra ~act:true with
    | Ok _ -> Windtrap.fail "a malformed state must not reconcile successfully"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names the malformed state"
        true
        (Sol_cli_string.contains ~needle:"invalid" message);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no import was attempted"
        []
        (imports log))
;;

let with_unobservable_provider f =
  let dir = Filename.temp_file "sol-fake-aws-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "aws" in
  let oc = open_out bin in
  output_string oc "#!/bin/sh\nexit 1\n";
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let readable_empty_state_is_not_refused () =
  with_unobservable_provider
  @@ fun () ->
  with_fake_terraform ~stdout:{|{"values": null}|} ~exit_code:0 (fun ~log ~infra ->
    match reconcile ~infra ~act:false with
    | Error message ->
      Windtrap.failf "a readable empty state must not be refused: %s" message
    | Ok reconciliation ->
      Windtrap.equal
        Windtrap.int
        ~msg:"nothing was restored"
        0
        (List.length reconciliation.restored);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no import was attempted"
        []
        (imports log))
;;

let%test "unreadable state: a failed terraform show refuses before importing" =
  failed_show_is_refused_before_any_import ()
;;

let%test "unreadable state: a malformed state refuses before importing" =
  malformed_state_is_refused_before_any_import ()
;;

let%test "unreadable state: a readable empty state is not refused" =
  readable_empty_state_is_not_refused ()
;;

(* Recovery is destructive authority. The inventories deliberately report every candidate
   their attribution rule finds, but only an exact provider name may be adopted; a name that
   merely contains the registry's prefix belongs to some other resource. *)
let present ~resource_class ~found =
  Sol_cli_absence.Present
    { resource_class
    ; identity = "test identity"
    ; found = [ found ]
    ; attribution = Sol_cli_absence.Named_for_target "test rule"
    ; checked_with = "test"
    }
;;

let gcp_disposition ~resource_class ~found =
  Sol_cli_ownership_reconciliation.dispositions
    ~entries:
      (Sol_cli_resource_identity.gcp
         ~cluster_name:"acme-prod"
         ~project_id:(Some "acme-project"))
    ~state_addresses:[]
    [ present ~resource_class ~found ]
  |> List.hd
;;

let recovered address disposition =
  match disposition with
  | Sol_cli_ownership_reconciliation.Recover candidate ->
    Windtrap.equal Windtrap.string ~msg:"the recovered address" address candidate.address
  | Sol_cli_ownership_reconciliation.Unmapped _ ->
    Windtrap.fail "an exact provider name was not mapped to its Terraform address"
  | _ -> Windtrap.fail "the observation did not produce a recovery or an unmapped refusal"
;;

let test_recovery_requires_an_exact_observed_name () =
  recovered
    "google_sql_database_instance.postgres[0]"
    (gcp_disposition ~resource_class:"Cloud SQL instance" ~found:"acme-prod-postgres");
  (match
     gcp_disposition
       ~resource_class:"Cloud SQL instance"
       ~found:"acme-prod-postgres-replica"
   with
   | Sol_cli_ownership_reconciliation.Unmapped _ -> ()
   | Sol_cli_ownership_reconciliation.Recover candidate ->
     Windtrap.failf
       "a longer SQL name was imported as %s; it belongs to another resource"
       candidate.address
   | _ -> Windtrap.fail "an unknown SQL name must be Unmapped");
  recovered
    "google_container_cluster.main"
    (gcp_disposition ~resource_class:"GKE cluster" ~found:"acme-prod");
  (match gcp_disposition ~resource_class:"GKE cluster" ~found:"acme-prod-old" with
   | Sol_cli_ownership_reconciliation.Unmapped _ -> ()
   | Sol_cli_ownership_reconciliation.Recover candidate ->
     Windtrap.failf "a longer cluster name was imported as %s" candidate.address
   | _ -> Windtrap.fail "an unknown cluster name must be Unmapped");
  (* The two genuinely qualified forms keep working: a service account's email and a
     project-qualified custom role name. *)
  recovered
    "google_service_account.provisioner"
    (gcp_disposition
       ~resource_class:"service account"
       ~found:"acme-prod-provisioner@acme-project.iam.gserviceaccount.com");
  (match
     gcp_disposition
       ~resource_class:"service account"
       ~found:"acme-prod-provisioner@other-project.iam.gserviceaccount.com"
   with
   | Sol_cli_ownership_reconciliation.Unmapped _ -> ()
   | Sol_cli_ownership_reconciliation.Recover candidate ->
     Windtrap.failf
       "a service account in another project was imported as %s"
       candidate.address
   | _ -> Windtrap.fail "a service account in another project must be Unmapped");
  (match
     gcp_disposition
       ~resource_class:"service account"
       ~found:
         "acme-prod-provisioner@acme-project.iam.gserviceaccount.com.attacker.example"
   with
   | Sol_cli_ownership_reconciliation.Unmapped _ -> ()
   | Sol_cli_ownership_reconciliation.Recover candidate ->
     Windtrap.failf
       "an email that merely starts with the expected identity was imported as %s"
       candidate.address
   | _ ->
     Windtrap.fail
       "an email with the expected prefix but a different domain must be Unmapped");
  recovered
    "google_project_iam_custom_role.provisioner_cluster_access"
    (gcp_disposition
       ~resource_class:"custom role"
       ~found:"projects/acme-project/roles/sol_acme_prod_cluster_access");
  match
    gcp_disposition
      ~resource_class:"custom role"
      ~found:"projects/acme-project/roles/sol_acme_prod_cluster_access_v2"
  with
  | Sol_cli_ownership_reconciliation.Unmapped _ -> ()
  | Sol_cli_ownership_reconciliation.Recover candidate ->
    Windtrap.failf "a longer custom-role name was imported as %s" candidate.address
  | _ -> Windtrap.fail "an unknown custom-role name must be Unmapped"
;;

let%test "recovery: only an exact observed name becomes Terraform authority" =
  test_recovery_requires_an_exact_observed_name ()
;;

let state_with_cluster ~name =
  Printf.sprintf
    {|{"values":{"root_module":{"resources":[{"address":"module.eks.aws_eks_cluster.this[0]","type":"aws_eks_cluster","values":{"name":%S}}]}}}|}
    name
;;

let with_fake_aws_script script f =
  let dir = Filename.temp_file "sol-fake-aws-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "aws" in
  Out_channel.with_open_text bin (fun oc -> output_string oc script);
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let aws_reporting_an_rds_instance =
  {|#!/bin/sh
case " $* " in
  *" sts get-caller-identity "*) printf '123456789012\n' ;;
  *" rds describe-db-instances "*) printf 'acme-prod-postgres\n' ;;
esac
exit 0
|}
;;

(* The state, not the target name, is what Terraform will act on. If they disagree, an
   observation for the target's name cannot authorize importing a resource into this state,
   and it cannot authorize forgetting the state's cluster either. *)
let test_cluster_identity_mismatch_refuses_before_import () =
  with_fake_aws_script aws_reporting_an_rds_instance
  @@ fun () ->
  with_fake_terraform
    ~stdout:(state_with_cluster ~name:"other-cluster")
    ~exit_code:0
    (fun ~log ~infra ->
       match reconcile ~infra ~act:true with
       | Ok _ ->
         Windtrap.fail
           "a state whose cluster identity disagrees with the target must not reconcile"
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the refusal names the state's cluster"
           true
           (Sol_cli_string.contains ~needle:"other-cluster" message);
         Windtrap.equal
           Windtrap.bool
           ~msg:"and the target's cluster"
           true
           (Sol_cli_string.contains ~needle:"acme-prod" message);
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"no import was attempted"
           []
           (imports log))
;;

let%test "recovery: a state/target cluster identity mismatch refuses before importing" =
  test_cluster_identity_mismatch_refuses_before_import ()
;;

let aws_saying_nothing = "#!/bin/sh\nexit 0\n"

let assets () =
  match Sol_cli_platform_assets.resolve () with
  | Ok assets -> assets
  | Error error -> Windtrap.fail (Sol_cli_platform_assets.error_to_string error)
;;

(* The destroy-side counterpart of the import check: a provider observation for one
   cluster name must not authorize forgetting state that holds another. *)
let test_cluster_identity_mismatch_never_forgets_state () =
  let state =
    Sol_cli_cloud_destroy.inventory_of_show_json
      (state_with_cluster ~name:"other-cluster")
  in
  with_fake_aws_script aws_saying_nothing
  @@ fun () ->
  with_fake_terraform
    ~stdout:(state_with_cluster ~name:"other-cluster")
    ~exit_code:0
    (fun ~log ~infra ->
       let base = Filename.concat infra "run-log" in
       Unix.mkdir base 0o755;
       let run_log = Sol_cli_run_log.create ~base ~prefix:"test" () in
       match
         Sol_cli_cloud_wiring.provable_absence_reconciliation
           ~assets:(assets ())
           ~run_log
           ~provider:Sol_cli_provider.Aws
           ~target_cfg:target
           ~infra_dir:infra
           ~platform_dir:infra
           ~platform_backend:[]
           ~var_files:[]
           ~vars:[ "cluster_name=acme-prod" ]
           ~state
       with
       | Ok Sol_cli_cloud_destroy.Nothing_to_reconcile ->
         let calls =
           try In_channel.with_open_text log In_channel.input_all with
           | Sys_error _ -> ""
         in
         Windtrap.equal
           Windtrap.bool
           ~msg:"no state entry was forgotten while the cluster identities disagree"
           false
           (Sol_cli_string.contains ~needle:"state rm" calls)
       | Ok (Sol_cli_cloud_destroy.Reconciled _) ->
         Windtrap.fail
           "the state's cluster identity disagrees with the target, so nothing may be \
            forgotten"
       | Error message ->
         Windtrap.failf
           "an identity mismatch is a refusal to forget, not a failed run: %s"
           message)
;;

let%test "destroy: a state/target cluster identity mismatch never runs state rm" =
  test_cluster_identity_mismatch_never_forgets_state ()
;;

let state_cluster_without_name =
  {|{"values":{"root_module":{"resources":[{"address":"module.eks.aws_eks_cluster.this[0]","type":"aws_eks_cluster","values":{}}]}}}|}
;;

let%test "recovery: a state cluster without a name refuses before importing" =
  with_unobservable_provider
  @@ fun () ->
  with_fake_terraform ~stdout:state_cluster_without_name ~exit_code:0 (fun ~log ~infra ->
    match reconcile ~infra ~act:true with
    | Ok _ ->
      Windtrap.fail
        "a state cluster with no name cannot be attributed, so it must not reconcile"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal says the state records no name"
        true
        (Sol_cli_string.contains ~needle:"records no name" message);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no import was attempted"
        []
        (imports log))
;;

let state_of_resources resources =
  Sol_cli_cloud_destroy.inventory_of_show_json
    (Printf.sprintf {|{"values":{"root_module":{"resources":[%s]}}}|} resources)
;;

let state_with_clusters names =
  let resources =
    names
    |> List.mapi (fun index name ->
      Printf.sprintf
        {|{"address":"module.eks.aws_eks_cluster.this[%d]","type":"aws_eks_cluster","values":{"name":%S}}|}
        index
        name)
    |> String.concat ","
  in
  Printf.sprintf {|{"values":{"root_module":{"resources":[%s]}}}|} resources
;;

let%test "state identity: a similarly-prefixed object is not the cluster" =
  let state =
    state_of_resources
      {|{"address":"module.eks.aws_eks_cluster_extra","type":"aws_eks_cluster_extra","values":{"name":"not-the-cluster"}},{"address":"module.eks.aws_eks_cluster.this[0]","type":"aws_eks_cluster","values":{"name":"acme-prod"}}|}
  in
  match
    Sol_cli_cloud_wiring.state_cluster_identity ~provider:Sol_cli_provider.Aws state
  with
  | Sol_cli_cloud_wiring.Cluster_named "acme-prod" -> ()
  | Sol_cli_cloud_wiring.Cluster_named other ->
    Windtrap.failf "the wrong resource supplied the cluster identity: %s" other
  | _ -> Windtrap.fail "the real cluster resource was not identified"
;;

let%test "state identity: a prefix match with another type is not a cluster" =
  let state =
    state_of_resources
      {|{"address":"module.eks.aws_eks_cluster_extra","type":"aws_eks_cluster_extra","values":{"name":"not-the-cluster"}}|}
  in
  match
    Sol_cli_cloud_wiring.state_cluster_identity ~provider:Sol_cli_provider.Aws state
  with
  | Sol_cli_cloud_wiring.Cluster_not_in_state -> ()
  | _ -> Windtrap.fail "a non-cluster type must not supply a cluster identity"
;;

(* Distinct Terraform resources are distinct ownership even when their recorded names are
   equal. Resolving that ambiguity by name would let one cluster's absence authorize
   forgetting the other's state. *)
let%test "state identity: multiple cluster resources are ambiguous, even with one name" =
  let state =
    Sol_cli_cloud_destroy.inventory_of_show_json
      (state_with_clusters [ "acme-prod"; "acme-prod" ])
  in
  match
    Sol_cli_cloud_wiring.state_cluster_identity ~provider:Sol_cli_provider.Aws state
  with
  | Sol_cli_cloud_wiring.Cluster_ambiguous addresses ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"both substrate resources are named in the ambiguity"
      [ "module.eks.aws_eks_cluster.this[0]"; "module.eks.aws_eks_cluster.this[1]" ]
      addresses
  | _ ->
    Windtrap.fail
      "two substrate resources must be ambiguous even when their names are identical"
;;

let%test "recovery: an ambiguous state cluster identity refuses before importing" =
  let state = state_with_clusters [ "acme-prod"; "other-cluster" ] in
  with_fake_aws_script aws_saying_nothing
  @@ fun () ->
  with_fake_terraform ~stdout:state ~exit_code:0 (fun ~log ~infra ->
    match reconcile ~infra ~act:true with
    | Ok _ ->
      Windtrap.fail "a state representing more than one cluster must not reconcile"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names the first cluster resource"
        true
        (Sol_cli_string.contains ~needle:"module.eks.aws_eks_cluster.this[0]" message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and the second cluster resource"
        true
        (Sol_cli_string.contains ~needle:"module.eks.aws_eks_cluster.this[1]" message);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no import was attempted"
        []
        (imports log))
;;

let%test "destroy: an ambiguous state cluster identity never runs state rm" =
  let state_json = state_with_clusters [ "acme-prod"; "other-cluster" ] in
  let state = Sol_cli_cloud_destroy.inventory_of_show_json state_json in
  with_fake_aws_script aws_saying_nothing
  @@ fun () ->
  with_fake_terraform ~stdout:state_json ~exit_code:0 (fun ~log ~infra ->
    let base = Filename.concat infra "run-log" in
    Unix.mkdir base 0o755;
    let run_log = Sol_cli_run_log.create ~base ~prefix:"test" () in
    match
      Sol_cli_cloud_wiring.provable_absence_reconciliation
        ~assets:(assets ())
        ~run_log
        ~provider:Sol_cli_provider.Aws
        ~target_cfg:target
        ~infra_dir:infra
        ~platform_dir:infra
        ~platform_backend:[]
        ~var_files:[]
        ~vars:[ "cluster_name=acme-prod" ]
        ~state
    with
    | Ok Sol_cli_cloud_destroy.Nothing_to_reconcile ->
      let calls =
        try In_channel.with_open_text log In_channel.input_all with
        | Sys_error _ -> ""
      in
      Windtrap.equal
        Windtrap.bool
        ~msg:"no state entry was forgotten while the cluster identity was ambiguous"
        false
        (Sol_cli_string.contains ~needle:"state rm" calls)
    | Ok (Sol_cli_cloud_destroy.Reconciled _) ->
      Windtrap.fail "an ambiguous state cluster identity authorized state removal"
    | Error message ->
      Windtrap.failf
        "an ambiguous identity is a refusal to forget, not a failed run: %s"
        message)
;;

let with_fake_gcloud_script script f =
  let dir = Filename.temp_file "sol-fake-gcloud-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "gcloud" in
  Out_channel.with_open_text bin (fun oc -> output_string oc script);
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let gcp_target : Sol_cli_config.target =
  { target with
    name = "prod/gcp/us-central1"
  ; provider = Sol_cli_provider.Gcp
  ; region = "us-central1"
  ; provider_fields = [ "gcp", [ "project_id", "missing-project" ] ]
  }
;;

let gcp_nonexistent_project_script =
  {|#!/bin/sh
case " $* " in
  *" container clusters list "*)
    printf 'WARNING: Some requests did not succeed.\n - The resource '"'"'projects/missing-project'"'"' was not found\n' >&2
    exit 0
    ;;
esac
exit 0
|}
;;

let gcp_state_with_cluster_and_incluster_resources =
  {|{"values":{"root_module":{"resources":[
    {"address":"google_container_cluster.main","type":"google_container_cluster","values":{"name":"acme-prod"}},
    {"address":"kubernetes_namespace.app","type":"kubernetes_namespace","values":{}}
  ]}}}|}
;;

(* The acceptance case the review called out: a nonexistent project is an unknown scope,
   not an absent cluster, and must not authorize state removal. *)
let test_nonexistent_gcp_project_never_forgets_state () =
  let state =
    Sol_cli_cloud_destroy.inventory_of_show_json
      gcp_state_with_cluster_and_incluster_resources
  in
  with_fake_gcloud_script gcp_nonexistent_project_script
  @@ fun () ->
  with_fake_terraform ~stdout:"{}" ~exit_code:0 (fun ~log ~infra ->
    let base = Filename.concat infra "run-log" in
    Unix.mkdir base 0o755;
    let run_log = Sol_cli_run_log.create ~base ~prefix:"test" () in
    match
      Sol_cli_cloud_wiring.provable_absence_reconciliation
        ~assets:(assets ())
        ~run_log
        ~provider:Sol_cli_provider.Gcp
        ~target_cfg:gcp_target
        ~infra_dir:infra
        ~platform_dir:infra
        ~platform_backend:[]
        ~var_files:[]
        ~vars:[ "cluster_name=acme-prod" ]
        ~state
    with
    | Ok Sol_cli_cloud_destroy.Nothing_to_reconcile ->
      let calls =
        try In_channel.with_open_text log In_channel.input_all with
        | Sys_error _ -> ""
      in
      Windtrap.equal
        Windtrap.bool
        ~msg:"a nonexistent project did not authorize state rm"
        false
        (Sol_cli_string.contains ~needle:"state rm" calls)
    | Ok (Sol_cli_cloud_destroy.Reconciled _) ->
      Windtrap.fail
        "a nonexistent project must not be read as a positively established absence"
    | Error message ->
      Windtrap.failf
        "a scope failure should decline to reconcile, not fail the run: %s"
        message)
;;

let%test "destroy: a nonexistent GCP project never authorizes state rm" =
  test_nonexistent_gcp_project_never_forgets_state ()
;;

let%test "recovery: the target's own account still yields its exact candidate" =
  with_fake_aws_script aws_reporting_an_rds_instance
  @@ fun () ->
  with_fake_terraform
    ~stdout:(state_with_cluster ~name:"acme-prod")
    ~exit_code:0
    (fun ~log:_ ~infra ->
       match reconcile ~infra ~act:false with
       | Error message ->
         Windtrap.failf "the target's own account was refused: %s" message
       | Ok reconciliation ->
         let candidate =
           List.find_opt
             (fun (candidate : Sol_cli_ownership_reconciliation.candidate) ->
                String.equal candidate.address "aws_db_instance.postgres[0]")
             (List.filter_map
                Sol_cli_ownership_reconciliation.candidate
                reconciliation.dispositions)
         in
         (match candidate with
          | Some candidate ->
            Windtrap.equal
              Windtrap.string
              ~msg:"the full provider name maps to the RDS address"
              "acme-prod-postgres"
              candidate.found
          | None ->
            Windtrap.fail
              "the exact RDS name in the target's own account must be recoverable"))
;;

let%test "recovery: a custom role in another project is Unmapped" =
  match
    gcp_disposition
      ~resource_class:"custom role"
      ~found:"projects/other-project/roles/sol_acme_prod_cluster_access"
  with
  | Sol_cli_ownership_reconciliation.Unmapped _ -> ()
  | Sol_cli_ownership_reconciliation.Recover candidate ->
    Windtrap.failf "a custom role in another project was imported as %s" candidate.address
  | _ -> Windtrap.fail "a custom role in another project must be Unmapped"
;;

let%test "state identity: a GCP cluster with a name is identified" =
  let state =
    state_of_resources
      {|{"address":"google_container_cluster.main","type":"google_container_cluster","values":{"name":"sol-qual"}}|}
  in
  match
    Sol_cli_cloud_wiring.state_cluster_identity ~provider:Sol_cli_provider.Gcp state
  with
  | Sol_cli_cloud_wiring.Cluster_named "sol-qual" -> ()
  | Sol_cli_cloud_wiring.Cluster_named other ->
    Windtrap.failf "the wrong GCP resource supplied the cluster identity: %s" other
  | _ -> Windtrap.fail "the GCP cluster resource was not identified"
;;

let%test "scope: a scope failure fails the destruction postcondition" =
  let verdict =
    Sol_cli_destroy_verification.classify
      { state = State_absent
      ; sweep =
          Sol_cli_absence.to_sweep
            (Sol_cli_absence.scope_failure ~reason:"the caller is in another account")
      ; retention = Retention_not_required "fixture"
      }
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"unknown scope cannot establish the destruction postcondition"
    false
    (Sol_cli_destroy_verification.is_verified verdict);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"unknown scope does not manufacture a present resource"
    []
    verdict.violations;
  Windtrap.equal
    Windtrap.bool
    ~msg:"the unknown preserves the scope diagnostic"
    true
    (List.exists
       (Sol_cli_string.contains ~needle:"the caller is in another account")
       verdict.unknowns)
;;

let gcp_state_with_unnamed_cluster_and_incluster_resources =
  {|{"values":{"root_module":{"resources":[
    {"address":"google_container_cluster.main","type":"google_container_cluster","values":{}},
    {"address":"kubernetes_namespace.app","type":"kubernetes_namespace","values":{}}
  ]}}}|}
;;

(* A provider observation for the configured cluster name does not establish that an
   unnamed cluster represented in state is that cluster. The actual reconciliation
   decision must not even probe the provider, because a probe may authorize state rm. *)
let test_unnamed_state_cluster_never_forgets_state () =
  let state =
    Sol_cli_cloud_destroy.inventory_of_show_json
      gcp_state_with_unnamed_cluster_and_incluster_resources
  in
  let sentinel = Filename.temp_file "sol-gcloud-probe-" "" in
  Sys.remove sentinel;
  let script = Printf.sprintf "#!/bin/sh\ntouch %s\nexit 0\n" (Filename.quote sentinel) in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove sentinel with
      | Sys_error _ -> ())
    (fun () ->
       with_fake_gcloud_script script
       @@ fun () ->
       with_fake_terraform ~stdout:"{}" ~exit_code:0 (fun ~log:_ ~infra ->
         let base = Filename.concat infra "run-log" in
         Unix.mkdir base 0o755;
         let run_log = Sol_cli_run_log.create ~base ~prefix:"test" () in
         match
           Sol_cli_cloud_wiring.provable_absence_reconciliation
             ~assets:(assets ())
             ~run_log
             ~provider:Sol_cli_provider.Gcp
             ~target_cfg:gcp_target
             ~infra_dir:infra
             ~platform_dir:infra
             ~platform_backend:[]
             ~var_files:[]
             ~vars:[ "cluster_name=acme-prod" ]
             ~state
         with
         | Ok Sol_cli_cloud_destroy.Nothing_to_reconcile ->
           Windtrap.equal
             Windtrap.bool
             ~msg:"the unnamed state did not even probe the resolved name"
             false
             (Sys.file_exists sentinel)
         | Ok (Sol_cli_cloud_destroy.Reconciled _) ->
           Windtrap.fail
             "the provider's observation of the configured name does not identify the \
              unnamed state cluster"
         | Error message ->
           Windtrap.failf
             "an unnamed state should decline to reconcile, not fail the run: %s"
             message))
;;

let%test "destroy: an unnamed state cluster never authorizes state rm" =
  test_unnamed_state_cluster_never_forgets_state ()
;;

let string_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> value
     | _ -> Windtrap.failf "the JSON outcome has no string %S" key)
  | _ -> Windtrap.fail "the JSON outcome is not an object"
;;

let int_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int value) -> value
     | _ -> Windtrap.failf "the JSON summary has no integer %S" key)
  | _ -> Windtrap.fail "the JSON summary is not an object"
;;

let nested key json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> Windtrap.failf "the JSON outcome has no %S" key)
  | _ -> Windtrap.fail "the JSON outcome is not an object"
;;

let json_examples =
  [ Sol_cli_ownership_reconciliation.Unmapped
      { resource_class = "VPC"; found = "vpc-unmapped" }
  ; Sol_cli_ownership_reconciliation.Cannot_recover
      { resource_class = "GKE cluster"
      ; found = "cluster-ambiguous"
      ; reason = "two entries"
      }
  ; Sol_cli_ownership_reconciliation.Unresolved
      { resource_class = "load balancer"; reason = "provider read failed" }
  ; Sol_cli_ownership_reconciliation.Recover
      { address = "aws_vpc.main"
      ; resource_class = "VPC"
      ; found = "vpc-recoverable"
      ; import_identity = "vpc-123"
      }
  ; Sol_cli_ownership_reconciliation.Already_owned
      { address = "aws_s3_bucket.logs"; found = "bucket-owned" }
  ; Sol_cli_ownership_reconciliation.By_contract
      { resource_class = "hosted zone"; found = "zone-retained" }
  ]
;;

let test_json_names_unrecoverable_and_unknown_separately () =
  let json =
    Sol_cli_ownership_reconciliation.to_json
      ~target:"prod/aws/us-east-1"
      ~dry_run:false
      ~restored:[]
      json_examples
  in
  Windtrap.equal Windtrap.string ~msg:"state" "unrecoverable" (string_field "state" json);
  let summary = nested "summary" json in
  Windtrap.equal
    Windtrap.int
    ~msg:"unrecoverable count"
    2
    (int_field "unrecoverable" summary);
  Windtrap.equal Windtrap.int ~msg:"unknown count" 1 (int_field "unknown" summary);
  Windtrap.equal Windtrap.int ~msg:"recoverable count" 1 (int_field "recoverable" summary);
  Windtrap.equal Windtrap.int ~msg:"already owned" 1 (int_field "already_owned" summary);
  Windtrap.equal Windtrap.int ~msg:"by contract" 1 (int_field "by_contract" summary);
  match nested "resources" json with
  | `List resources ->
    Windtrap.equal Windtrap.int ~msg:"every resource is listed" 6 (List.length resources);
    let unmapped =
      List.find (fun resource -> string_field "found" resource = "vpc-unmapped") resources
    in
    Windtrap.equal
      Windtrap.string
      ~msg:"unmapped disposition"
      "unrecoverable"
      (string_field "disposition" unmapped);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the reason is carried"
      true
      (string_field "reason" unmapped <> "")
  | _ -> Windtrap.fail "resources is not a list"
;;

let test_json_unknown_only_stays_unknown () =
  let json =
    Sol_cli_ownership_reconciliation.to_json
      ~target:"prod/aws/us-east-1"
      ~dry_run:false
      ~restored:[]
      [ Sol_cli_ownership_reconciliation.Unresolved
          { resource_class = "load balancer"; reason = "provider read failed" }
      ]
  in
  Windtrap.equal Windtrap.string ~msg:"state" "unknown" (string_field "state" json);
  Windtrap.equal
    Windtrap.int
    ~msg:"unknown count"
    1
    (int_field "unknown" (nested "summary" json))
;;

let test_json_adopted_is_reconciled () =
  let candidate : Sol_cli_ownership_reconciliation.candidate =
    { address = "aws_vpc.main"
    ; resource_class = "VPC"
    ; found = "vpc-recoverable"
    ; import_identity = "vpc-123"
    }
  in
  let json =
    Sol_cli_ownership_reconciliation.to_json
      ~target:"prod/aws/us-east-1"
      ~dry_run:false
      ~restored:[ candidate ]
      [ Sol_cli_ownership_reconciliation.Recover candidate ]
  in
  Windtrap.equal Windtrap.string ~msg:"state" "reconciled" (string_field "state" json);
  Windtrap.equal
    Windtrap.int
    ~msg:"adopted count"
    1
    (int_field "adopted" (nested "summary" json));
  match nested "resources" json with
  | `List [ resource ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"adopted disposition"
      "adopted"
      (string_field "disposition" resource)
  | _ -> Windtrap.fail "expected one resource"
;;

let test_json_dry_run_says_would_recover () =
  let candidate : Sol_cli_ownership_reconciliation.candidate =
    { address = "aws_vpc.main"
    ; resource_class = "VPC"
    ; found = "vpc-recoverable"
    ; import_identity = "vpc-123"
    }
  in
  let json =
    Sol_cli_ownership_reconciliation.to_json
      ~target:"prod/aws/us-east-1"
      ~dry_run:true
      ~restored:[]
      [ Sol_cli_ownership_reconciliation.Recover candidate ]
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"dry run"
    true
    (match nested "dry_run" json with
     | `Bool value -> value
     | _ -> false);
  Windtrap.equal Windtrap.string ~msg:"state" "recoverable" (string_field "state" json);
  match nested "resources" json with
  | `List [ resource ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"would_recover disposition"
      "would_recover"
      (string_field "disposition" resource)
  | _ -> Windtrap.fail "expected one resource"
;;

let test_adopted_identity_requires_an_exact_non_blank_match () =
  let agrees observed import_identity =
    Sol_cli_ownership_reconciliation.adopted_identity_agrees ~observed ~import_identity
  in
  List.iter
    (fun (observed, import_identity, expected) ->
       Windtrap.equal
         Windtrap.bool
         ~msg:(Printf.sprintf "adopted identity %S vs %S" observed import_identity)
         expected
         (agrees observed import_identity))
    [ "arn:aws:iam::123:role/sol-deploy", "arn:aws:iam::123:role/sol-deploy", true
    ; "", "arn:aws:iam::123:role/sol-deploy", false
    ; "arn:aws:iam::123:role/sol-dep", "arn:aws:iam::123:role/sol-deploy", false
    ; "arn:aws:iam::123:role/sol-deploy-extra", "arn:aws:iam::123:role/sol-deploy", false
    ]
;;

let%test "ownership: adoption requires an exact, non-blank identity" =
  test_adopted_identity_requires_an_exact_non_blank_match ()
;;

let%test "json: unrecoverable and unknown are separate" =
  test_json_names_unrecoverable_and_unknown_separately ()
;;

let%test "json: unknown-only state" = test_json_unknown_only_stays_unknown ()
let%test "json: adopted state" = test_json_adopted_is_reconciled ()
let%test "json: dry-run state" = test_json_dry_run_says_would_recover ()
