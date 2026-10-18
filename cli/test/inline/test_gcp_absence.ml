let target : Sol_cli_config.target =
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

let fake_gcloud
      ~log
      ~node_pools_out
      ~node_pools_err
      ~nats_out
      ~roles_out
      ~disks_out
      ~list_exit
  =
  Printf.sprintf
    {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$*" in
  *"container node-pools list"*)
    printf '%%s' %s%s
    printf '%%s' %s >&2
    exit %d
    ;;
  *"routers nats list"*)
    printf '%%s' %s
    exit 0
    ;;
  *"iam roles list"*)
    printf '%%s' %s
    exit 0
    ;;
  *"compute disks list"*)
    printf '%%s' %s
    exit 0
    ;;
esac
exit 0
|}
    log
    (Filename.quote node_pools_out)
    (if list_exit = 0 then "" else " >&2")
    (Filename.quote node_pools_err)
    list_exit
    (Filename.quote nats_out)
    (Filename.quote roles_out)
    (Filename.quote disks_out)
;;

let with_fake_gcloud
      ~node_pools_out
      ~node_pools_err
      ~nats_out
      ~roles_out
      ~disks_out
      ~list_exit
      f
  =
  let dir = Filename.temp_file "sol-fake-gcloud-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "gcloud" in
  let oc = open_out bin in
  output_string
    oc
    (fake_gcloud
       ~log
       ~node_pools_out
       ~node_pools_err
       ~nats_out
       ~roles_out
       ~disks_out
       ~list_exit);
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  let old_default =
    try Some (Sys.getenv "CLOUDSDK_COMPUTE_REGION") with
    | Not_found -> None
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Unix.putenv "CLOUDSDK_COMPUTE_REGION" "europe-west1";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (match old_default with
       | Some value -> Unix.putenv "CLOUDSDK_COMPUTE_REGION" value
       | None -> ());
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let calls log = In_channel.with_open_text log In_channel.input_all

let arguments_of ~log ~contains =
  calls log
  |> String.split_on_char '\n'
  |> List.filter (fun line -> Sol_cli_string.contains ~needle:contains line)
;;

let class_of (o : Sol_cli_absence.observation) =
  match o with
  | Sol_cli_absence.Absent a -> a.resource_class
  | Present p -> p.resource_class
  | External e -> e.resource_class
  | Not_attributable n -> n.resource_class
  | Unobservable u -> u.resource_class
;;

let only observations resource_class =
  List.find (fun o -> String.equal (class_of o) resource_class) observations
;;

let with_calls
      ?(disks_out = "")
      ?(node_pools_err = "")
      ?(roles_out = "")
      ?(previously_attributed = [])
      ~node_pools_out
      ~nats_out
      ~list_exit
      f
  =
  with_fake_gcloud
    ~node_pools_out
    ~node_pools_err
    ~nats_out
    ~roles_out
    ~disks_out
    ~list_exit
    (fun () ->
       let observations =
         Sol_cli_gcp_absence.observations
           ~previously_attributed
           target
           ~cluster_name:"acme-prod"
       in
       let log =
         match Sys.getenv_opt "PATH" with
         | Some path ->
           Filename.concat (List.hd (String.split_on_char ':' path)) "calls.log"
         | None -> Windtrap.fail "PATH is unset"
       in
       f ~log ~observations)
;;

let test_location_is_explicit_on_every_regional_check () =
  with_calls ~node_pools_out:"" ~nats_out:"" ~list_exit:0 (fun ~log ~observations:_ ->
    let node_pools = arguments_of ~log ~contains:"node-pools list" in
    Windtrap.equal Windtrap.int ~msg:"one node-pool check" 1 (List.length node_pools);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the node-pool check carries the target's location"
      true
      (Sol_cli_string.contains ~needle:"--location us-central1" (List.hd node_pools));
    let nats = arguments_of ~log ~contains:"nats list" in
    Windtrap.equal Windtrap.int ~msg:"one Cloud NAT check" 1 (List.length nats);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the Cloud NAT check carries the target's router region"
      true
      (Sol_cli_string.contains ~needle:"--router-region us-central1" (List.hd nats));
    let regional =
      arguments_of ~log ~contains:"routers list"
      @ arguments_of ~log ~contains:"subnets list"
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"and so does every other regional list, with the flag gcloud accepts"
      true
      (List.for_all
         (fun call -> Sol_cli_string.contains ~needle:"--regions us-central1" call)
         regional);
    let clusters = arguments_of ~log ~contains:"clusters list" in
    Windtrap.equal Windtrap.int ~msg:"one cluster check" 1 (List.length clusters);
    Windtrap.equal
      Windtrap.bool
      ~msg:
        "the cluster check is scoped to the target's region, so a same-named cluster \
         elsewhere is not this target's"
      true
      (Sol_cli_string.contains ~needle:"--region us-central1" (List.hd clusters));
    let sql = arguments_of ~log ~contains:"sql instances list" in
    Windtrap.equal Windtrap.int ~msg:"one Cloud SQL check" 1 (List.length sql);
    Windtrap.equal
      Windtrap.bool
      ~msg:
        "the Cloud SQL check is scoped to the target's region, so a same-named instance \
         elsewhere is not this target's"
      true
      (Sol_cli_string.contains ~needle:"--filter region:us-central1" (List.hd sql));
    let artifacts = arguments_of ~log ~contains:"repositories list" in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the registry check is scoped to the target's region"
      true
      (List.exists
         (fun call -> Sol_cli_string.contains ~needle:"--location us-central1" call)
         artifacts);
    let disks = arguments_of ~log ~contains:"disks list" in
    Windtrap.equal Windtrap.int ~msg:"one disk check" 1 (List.length disks);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the disk check is scoped to the target's region"
      true
      (Sol_cli_string.contains ~needle:"--regions us-central1" (List.hd disks));
    Windtrap.equal
      Windtrap.bool
      ~msg:"and asks for the GKE cluster label that attributes a PVC disk"
      true
      (Sol_cli_string.contains
         ~needle:"value(name,labels.goog-k8s-cluster-name)"
         (List.hd disks)))
;;

let test_the_target_region_beats_the_configured_default () =
  with_calls ~node_pools_out:"" ~nats_out:"" ~list_exit:0 (fun ~log ~observations:_ ->
    let all = calls log in
    Windtrap.equal
      Windtrap.bool
      ~msg:"no check follows the operator's default region"
      false
      (Sol_cli_string.contains ~needle:"europe-west1" all))
;;

let test_an_empty_inventory_is_absent () =
  with_calls ~node_pools_out:"" ~nats_out:"" ~list_exit:0 (fun ~log:_ ~observations ->
    (match only observations "GKE node pool" with
     | Sol_cli_absence.Absent _ -> ()
     | _ -> Windtrap.fail "an empty node-pool list must be Absent");
    match only observations "Cloud NAT" with
    | Sol_cli_absence.Absent _ -> ()
    | _ -> Windtrap.fail "an empty Cloud NAT list must be Absent")
;;

let test_a_present_resource_is_reported () =
  with_calls
    ~node_pools_out:"acme-prod-pool-1\n"
    ~nats_out:"acme-prod-nat\n"
    ~list_exit:0
    (fun ~log:_ ~observations ->
       (match only observations "GKE node pool" with
        | Sol_cli_absence.Present p ->
          Windtrap.equal
            (Windtrap.list Windtrap.string)
            ~msg:"the node pool is reported"
            [ "acme-prod-pool-1" ]
            p.found
        | _ -> Windtrap.fail "a present node pool must be Present");
       match only observations "Cloud NAT" with
       | Sol_cli_absence.Present p ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"the NAT is reported"
           [ "acme-prod-nat" ]
           p.found
       | _ -> Windtrap.fail "a present NAT must be Present")
;;

let test_a_refused_list_is_unobservable () =
  with_calls
    ~node_pools_out:"One of [--location, --zone, --region] must be supplied\n"
    ~nats_out:""
    ~list_exit:1
    (fun ~log:_ ~observations ->
       match only observations "GKE node pool" with
       | Sol_cli_absence.Unobservable u ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the reason is the provider's"
           true
           (Sol_cli_string.contains ~needle:"must be supplied" u.reason)
       | _ -> Windtrap.fail "a refused list must be Unobservable")
;;

let%test "location-scoped inventory: passes the target location explicitly" =
  test_location_is_explicit_on_every_regional_check ()
;;

let%test "location-scoped inventory: the target region beats the configured default" =
  test_the_target_region_beats_the_configured_default ()
;;

let%test "location-scoped inventory: an empty inventory is Absent" =
  test_an_empty_inventory_is_absent ()
;;

let%test "location-scoped inventory: a present resource is Present" =
  test_a_present_resource_is_reported ()
;;

let%test "location-scoped inventory: a refused list is Unobservable" =
  test_a_refused_list_is_unobservable ()
;;

let test_a_not_found_list_failure_is_unobservable () =
  with_calls
    ~node_pools_out:
      "ERROR: (gcloud.container.node-pools.list) NOT_FOUND: The project 'missing' was \
       not found.\n"
    ~nats_out:""
    ~list_exit:1
    (fun ~log:_ ~observations ->
       match only observations "GKE node pool" with
       | Sol_cli_absence.Unobservable u ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the provider's NOT_FOUND text is kept as the unknown's reason"
           true
           (Sol_cli_string.contains ~needle:"NOT_FOUND" u.reason)
       | Sol_cli_absence.Absent _ ->
         Windtrap.fail
           "a failed enumeration containing 'not found' must not become absence"
       | _ -> Windtrap.fail "a failed enumeration must be Unobservable")
;;

let%test "location-scoped inventory: a not-found list failure is Unobservable" =
  test_a_not_found_list_failure_is_unobservable ()
;;

let test_a_scope_warning_on_a_successful_list_is_unobservable () =
  with_calls
    ~node_pools_out:""
    ~node_pools_err:
      "WARNING: Some requests did not succeed.\n\
      \ - The resource 'projects/missing-project' was not found\n"
    ~nats_out:""
    ~list_exit:0
    (fun ~log:_ ~observations ->
       match only observations "GKE node pool" with
       | Sol_cli_absence.Unobservable u ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the provider's missing-scope warning is kept as the reason"
           true
           (Sol_cli_string.contains ~needle:"was not found" u.reason)
       | Sol_cli_absence.Absent _ ->
         Windtrap.fail
           "a successful empty list with a missing-project warning is not absence"
       | _ -> Windtrap.fail "a scope warning must be Unobservable")
;;

let test_the_benign_empty_filter_warning_is_still_absence () =
  with_calls
    ~node_pools_out:""
    ~node_pools_err:
      "WARNING: The following filter keys were not present in any resource : name, region\n"
    ~nats_out:""
    ~list_exit:0
    (fun ~log:_ ~observations ->
       match only observations "GKE node pool" with
       | Sol_cli_absence.Absent _ -> ()
       | Sol_cli_absence.Unobservable u ->
         Windtrap.failf
           "the benign empty-result warning was treated as unknown: %s"
           u.reason
       | _ -> Windtrap.fail "an empty successful list with a benign warning is absence")
;;

let%test "GCP scope: a missing-project warning on a successful list is Unobservable" =
  test_a_scope_warning_on_a_successful_list_is_unobservable ()
;;

let%test "GCP scope: the benign empty-result filter warning is still absence" =
  test_the_benign_empty_filter_warning_is_still_absence ()
;;

let test_custom_roles_are_normalized_to_the_target_project () =
  with_calls
    ~node_pools_out:""
    ~nats_out:""
    ~roles_out:
      "sol_acme_prod_cluster_access\n\
       projects/other-project/roles/sol_acme_prod_cluster_access\n"
    ~list_exit:0
    (fun ~log:_ ~observations ->
       match only observations "custom role" with
       | Sol_cli_absence.Present p ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"a bare role id is normalized into the target project"
           true
           (List.mem "projects/acme-project/roles/sol_acme_prod_cluster_access" p.found);
         Windtrap.equal
           Windtrap.bool
           ~msg:"a role from another project is not attributed to this target"
           false
           (List.exists
              (fun line -> Sol_cli_string.contains ~needle:"other-project" line)
              p.found)
       | Sol_cli_absence.Absent _ ->
         Windtrap.fail "the target's custom roles must be Present"
       | _ -> Windtrap.fail "the custom-role observation must be Present")
;;

let test_an_incomplete_enumeration_with_matches_is_unobservable () =
  with_calls
    ~node_pools_out:"acme-prod-pool-1\n"
    ~node_pools_err:
      "WARNING: Some requests did not succeed.\n\
      \ - The resource 'projects/acme-project' was not found\n"
    ~nats_out:""
    ~list_exit:0
    (fun ~log:_ ~observations ->
       match only observations "GKE node pool" with
       | Sol_cli_absence.Unobservable u ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the incomplete collection keeps the provider's warning"
           true
           (Sol_cli_string.contains ~needle:"did not succeed" u.reason)
       | Sol_cli_absence.Present _ ->
         Windtrap.fail
           "matching output from an incomplete enumeration must not be Present"
       | _ -> Windtrap.fail "an incomplete enumeration must be Unobservable")
;;

let%test "GCP roles: custom roles are normalized to the target project" =
  test_custom_roles_are_normalized_to_the_target_project ()
;;

let%test "GCP scope: an incomplete enumeration with matches is Unobservable" =
  test_an_incomplete_enumeration_with_matches_is_unobservable ()
;;

let test_attributable_pvc_disks_are_present () =
  with_calls
    ~node_pools_out:""
    ~nats_out:""
    ~disks_out:
      "pvc-2120bdaa\tacme-prod\n\
       pvc-other\tother-cluster\n\
       gke-acme-prod-node-1\tacme-prod\n\
       pvc-unlabelled\n\
       gke-acme-prod-node-2\n"
    ~list_exit:0
    (fun ~log:_ ~observations ->
       match only observations "persistent disk" with
       | Sol_cli_absence.Present p ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:
             "the cluster label attributes the PVC and labelled node disks; an unrelated \
              label, no label, or an unlabelled gke-* name is not attributed"
           [ "gke-acme-prod-node-1"; "pvc-2120bdaa" ]
           p.found
       | Sol_cli_absence.Absent _ ->
         Windtrap.fail "an attributable pvc-* disk must be Present"
       | _ -> Windtrap.fail "the disk observation must be Present")
;;

let%test "GCP disks: a previously attributed disk survives label loss" =
  with_calls
    ~disks_out:"pvc-2120bdaa\n"
    ~previously_attributed:[ "persistent disk", [ "pvc-2120bdaa" ] ]
    ~node_pools_out:""
    ~nats_out:""
    ~list_exit:0
    (fun ~log:_ ~observations ->
       match only observations "persistent disk" with
       | Sol_cli_absence.Present present ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"the pre-destroy identity keeps the label-less disk attributable"
           [ "pvc-2120bdaa" ]
           present.found
       | _ ->
         Windtrap.fail
           "a disk known before destruction must not become Absent when its label changes")
;;

let test_a_present_pvc_disk_prevents_verified_absence () =
  with_calls
    ~node_pools_out:""
    ~nats_out:""
    ~disks_out:"pvc-2120bdaa\tacme-prod\n"
    ~list_exit:0
    (fun ~log:_ ~observations ->
       let disk = only observations "persistent disk" in
       match Sol_cli_absence.to_sweep [ disk ] with
       | Sol_cli_destroy_verification.Sweep_ran { residues; indeterminate = [] } ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the destroy sweep names the PVC disk and refuses verified absence"
           true
           (List.exists
              (fun residue ->
                 Sol_cli_string.contains ~needle:"persistent disk" residue
                 && Sol_cli_string.contains ~needle:"pvc-2120bdaa" residue)
              residues)
       | _ ->
         Windtrap.fail "a present disk must produce a residue, not an inconclusive probe")
;;

let%test "GCP disks: the cluster label, not the disk name, is the attribution" =
  test_attributable_pvc_disks_are_present ()
;;

let%test "GCP disks: an attributable PVC disk prevents verified absence" =
  test_a_present_pvc_disk_prevents_verified_absence ()
;;

let with_fake_regional_addresses ?(rule_exit = 0) ?(rule_err = "") ~addresses ~network f =
  let dir = Filename.temp_file "sol-fake-regional-addresses-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "gcloud" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$*" in
  *"compute addresses list"*) printf '%%s' %s ;;
  *"compute forwarding-rules describe"*)
    if [ %d -ne 0 ]; then printf '%%s' %s >&2; exit %d; fi
    printf '%%s\n' %s
    ;;
esac
exit 0
|}
      (Filename.quote log)
      (Filename.quote addresses)
      rule_exit
      (Filename.quote rule_err)
      rule_exit
      (Filename.quote network)
  in
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
    f
;;

let regional_address observations =
  List.find
    (fun observation -> String.equal (class_of observation) "regional address")
    observations
;;

let%test
    "GCP regional addresses: a forwarding rule in the target VPC attributes the address"
  =
  let addresses =
    {|[{"name":"k8s2-abc","address":"1.2.3.4","users":["https://www.googleapis.com/compute/v1/projects/acme-project/regions/us-central1/forwardingRules/rule-1"]}]|}
  in
  let network =
    "https://www.googleapis.com/compute/v1/projects/acme-project/global/networks/acme-prod"
  in
  with_fake_regional_addresses ~addresses ~network (fun () ->
    let observations =
      Sol_cli_gcp_absence.observations target ~cluster_name:"acme-prod"
    in
    match regional_address observations with
    | Sol_cli_absence.Present present ->
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"the address used by the target's forwarding rule is reported"
        [ "k8s2-abc" ]
        present.found
    | _ -> Windtrap.fail (Sol_cli_absence.report observations))
;;

let%test "GCP regional addresses: a prior identity survives when the users are gone" =
  let addresses = {|[{"name":"k8s2-abc","address":"1.2.3.4","users":[]}]|} in
  with_fake_regional_addresses
    ~addresses
    ~network:
      "https://www.googleapis.com/compute/v1/projects/acme-project/global/networks/acme-prod"
    (fun () ->
       let observations =
         Sol_cli_gcp_absence.observations
           ~previously_attributed:[ "regional address", [ "k8s2-abc" ] ]
           target
           ~cluster_name:"acme-prod"
       in
       match regional_address observations with
       | Sol_cli_absence.Present present ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"the pre-destroy identity keeps the address attributable"
           [ "k8s2-abc" ]
           present.found
       | _ -> Windtrap.fail "a prior regional address identity must remain Present")
;;

let%test "GCP regional addresses: a different VPC is not attributed" =
  let addresses =
    {|[{"name":"other-address","address":"5.6.7.8","users":["https://www.googleapis.com/compute/v1/projects/acme-project/regions/us-central1/forwardingRules/rule-2"]}]|}
  in
  with_fake_regional_addresses
    ~addresses
    ~network:
      "https://www.googleapis.com/compute/v1/projects/acme-project/global/networks/other"
    (fun () ->
       let observations =
         Sol_cli_gcp_absence.observations target ~cluster_name:"acme-prod"
       in
       match regional_address observations with
       | Sol_cli_absence.Absent _ -> ()
       | _ -> Windtrap.fail "a regional address in another VPC must not be attributed")
;;

let%test "GCP regional addresses: an absent users field is a genuine empty relationship" =
  let addresses = {|[{"name":"k8s2-abc","address":"1.2.3.4"}]|} in
  with_fake_regional_addresses
    ~addresses
    ~network:
      "https://www.googleapis.com/compute/v1/projects/acme-project/global/networks/acme-prod"
    (fun () ->
       let observations =
         Sol_cli_gcp_absence.observations
           ~previously_attributed:[ "regional address", [ "k8s2-abc" ] ]
           target
           ~cluster_name:"acme-prod"
       in
       match regional_address observations with
       | Sol_cli_absence.Present present ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"the prior identity is preserved when users is absent"
           [ "k8s2-abc" ]
           present.found
       | _ ->
         Windtrap.fail
           "an absent users field is the provider's empty repeated-field encoding")
;;

let%test "GCP regional addresses: a malformed users field is unknown" =
  let addresses = {|[{"name":"k8s2-abc","address":"1.2.3.4","users":"not-a-list"}]|} in
  with_fake_regional_addresses
    ~addresses
    ~network:
      "https://www.googleapis.com/compute/v1/projects/acme-project/global/networks/acme-prod"
    (fun () ->
       let observations =
         Sol_cli_gcp_absence.observations target ~cluster_name:"acme-prod"
       in
       match regional_address observations with
       | Sol_cli_absence.Unobservable _ -> ()
       | _ -> Windtrap.fail "a non-list users field must not become an empty relationship")
;;

let%test "GCP regional addresses: a non-string user is unknown" =
  let addresses = {|[{"name":"k8s2-abc","address":"1.2.3.4","users":[123]}]|} in
  with_fake_regional_addresses
    ~addresses
    ~network:
      "https://www.googleapis.com/compute/v1/projects/acme-project/global/networks/acme-prod"
    (fun () ->
       let observations =
         Sol_cli_gcp_absence.observations target ~cluster_name:"acme-prod"
       in
       match regional_address observations with
       | Sol_cli_absence.Unobservable _ -> ()
       | _ -> Windtrap.fail "a non-string user must not be silently discarded")
;;

let%test "GCP regional addresses: a failed forwarding-rule read is unknown" =
  let addresses =
    {|[{"name":"k8s2-abc","address":"1.2.3.4","users":["https://www.googleapis.com/compute/v1/projects/acme-project/regions/us-central1/forwardingRules/rule-1"]}]|}
  in
  with_fake_regional_addresses
    ~addresses
    ~network:""
    ~rule_exit:254
    ~rule_err:"permission denied"
    (fun () ->
       let observations =
         Sol_cli_gcp_absence.observations target ~cluster_name:"acme-prod"
       in
       match regional_address observations with
       | Sol_cli_absence.Unobservable u ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the provider's forwarding-rule error is preserved"
           true
           (Sol_cli_string.contains ~needle:"permission denied" u.reason)
       | _ -> Windtrap.fail "a failed forwarding-rule read must be unknown")
;;

let with_failed_regional_address_list f =
  let dir = Filename.temp_file "sol-fake-regional-address-list-fail-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "gcloud" in
  let script =
    {|#!/bin/sh
case "$*" in
  *"compute addresses list"*) printf 'permission denied\n' >&2; exit 254 ;;
esac
exit 0
|}
  in
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

let%test "GCP regional addresses: a failed address listing is unknown" =
  with_failed_regional_address_list (fun () ->
    let observations =
      Sol_cli_gcp_absence.observations target ~cluster_name:"acme-prod"
    in
    match regional_address observations with
    | Sol_cli_absence.Unobservable u ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the provider's address-list error is preserved"
        true
        (Sol_cli_string.contains ~needle:"permission denied" u.reason)
    | _ -> Windtrap.fail "a failed address listing must be unknown")
;;
