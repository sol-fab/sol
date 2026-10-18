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
        , [ "provisioner_role_arn", "arn:aws:iam::111122223333:role/sol-provisioner" ] )
      ]
  ; secret_authorities = []
  }
;;

let fake_aws ~log ~sts_out ~list_out ~list_exit ~tags_out ~tags_exit =
  Printf.sprintf
    {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$1 $2" in
  "sts get-caller-identity")
    printf '%%s' %s
    exit 0
    ;;
  "elbv2 describe-load-balancers")
    printf '%%s' %s%s
    exit %d
    ;;
  "elbv2 describe-tags")
    printf '%%s' %s%s
    exit %d
    ;;
esac
exit 0
|}
    log
    (Filename.quote sts_out)
    (Filename.quote list_out)
    (if list_exit = 0 then "" else " >&2")
    list_exit
    (Filename.quote tags_out)
    (if tags_exit = 0 then "" else " >&2")
    tags_exit
;;

let with_fake_aws ~sts_out ~list_out ~list_exit ~tags_out ~tags_exit f =
  let dir = Filename.temp_file "sol-fake-aws-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "aws" in
  let oc = open_out bin in
  output_string oc (fake_aws ~log ~sts_out ~list_out ~list_exit ~tags_out ~tags_exit);
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

let load_balancer observations =
  List.find (fun o -> String.equal (class_of o) "load balancer") observations
;;

let with_calls
      ?(sts_out = "111122223333\n")
      ?(list_exit = 0)
      ~list_out
      ~tags_out
      ~tags_exit
      f
  =
  with_fake_aws ~sts_out ~list_out ~list_exit ~tags_out ~tags_exit (fun () ->
    let observations =
      Sol_cli_aws_absence.observations target ~cluster_name:"acme-prod"
    in
    let log =
      match Sys.getenv_opt "PATH" with
      | Some path -> Filename.concat (List.hd (String.split_on_char ':' path)) "calls.log"
      | None -> Windtrap.fail "PATH is unset"
    in
    f ~log ~observations)
;;

let observation_of class_name observations =
  List.find
    (fun observation -> String.equal (class_of observation) class_name)
    observations
;;

(* ECR repositories are named `<workspace>/<service>` by the cluster root from
   the `workspace_name` variable. The target's registry is optional and may name
   another registry entirely, so the workspace name must be the attribution
   prefix. *)
let with_ecr_inventory ~workspace ~repositories f =
  let root = Filename.temp_file "sol-ecr-workspace-" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  let ws = Filename.concat root workspace in
  Unix.mkdir ws 0o755;
  let sol_yml = Filename.concat ws "sol.yml" in
  Out_channel.with_open_text sol_yml (fun _ -> ());
  let bin_dir = Filename.concat root "bin" in
  Unix.mkdir bin_dir 0o755;
  let log = Filename.concat bin_dir "calls.log" in
  let bin = Filename.concat bin_dir "aws" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$1 $2" in
  "sts get-caller-identity") printf '111122223333\n' ;;
  "ecr describe-repositories") printf '%%s' %s ;;
esac
exit 0
|}
      (Filename.quote log)
      (Filename.quote repositories)
  in
  Out_channel.with_open_text bin (fun oc -> output_string oc script);
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  let old_cwd = Sys.getcwd () in
  Unix.putenv "PATH" (bin_dir ^ ":" ^ old_path);
  Sys.chdir ws;
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir old_cwd;
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      (try Sys.remove sol_yml with
       | _ -> ());
      (try Unix.rmdir ws with
       | _ -> ());
      (try Unix.rmdir bin_dir with
       | _ -> ());
      try Unix.rmdir root with
      | _ -> ())
    (fun () ->
       let observations =
         Sol_cli_aws_absence.observations target ~cluster_name:"acme-prod"
       in
       f ~log ~observations)
;;

let%test "AWS ECR inventory: workspace repositories are attributable without a registry" =
  with_ecr_inventory
    ~workspace:"acme"
    ~repositories:"acme/charge-svc\nacme/old-service\nother/charge-svc\n"
    (fun ~log:_ ~observations ->
       match observation_of "ECR repository" observations with
       | Sol_cli_absence.Present present ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"the workspace's current and historical repositories are reported"
           [ "acme/charge-svc"; "acme/old-service" ]
           present.found
       | _ ->
         Windtrap.fail
           "the workspace's ECR repositories must be attributable without a registry")
;;

let%test "AWS ECR inventory: another workspace's repository is not attributed" =
  with_ecr_inventory
    ~workspace:"acme"
    ~repositories:"other/charge-svc\n"
    (fun ~log:_ ~observations ->
       match observation_of "ECR repository" observations with
       | Sol_cli_absence.Absent _ -> ()
       | _ -> Windtrap.fail "another workspace's ECR repository must not be attributed")
;;

let test_load_balancers_use_a_supported_command () =
  with_calls ~list_out:"" ~tags_out:"" ~tags_exit:0 (fun ~log ~observations:_ ->
    let list_calls = arguments_of ~log ~contains:"describe-load-balancers" in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the load balancers were listed"
      true
      (list_calls <> []);
    List.iter
      (fun call ->
         Windtrap.equal
           Windtrap.bool
           ~msg:(Printf.sprintf "no --filters in %S" call)
           false
           (Sol_cli_string.contains ~needle:"--filters" call))
      list_calls;
    let ec2_calls = arguments_of ~log ~contains:"describe-vpcs" in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the volumes/vpcs still filter by tag"
      true
      (ec2_calls <> []);
    List.iter
      (fun call ->
         Windtrap.equal
           Windtrap.bool
           ~msg:(Printf.sprintf "ec2 filters remain in %S" call)
           true
           (Sol_cli_string.contains ~needle:"--filters" call))
      ec2_calls)
;;

let test_tagged_load_balancer_is_present () =
  let arn = "arn:aws:elasticloadbalancing:us-east-1:1:loadbalancer/app/acme/1" in
  with_calls
    ~list_out:(arn ^ "\n")
    ~tags_out:"owned\n"
    ~tags_exit:0
    (fun ~log:_ ~observations ->
       match load_balancer observations with
       | Sol_cli_absence.Present p ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"the tagged load balancer is reported"
           [ arn ]
           p.found
       | _ -> Windtrap.fail "a tagged load balancer must be Present")
;;

let test_untagged_inventory_is_absent () =
  let arn = "arn:aws:elasticloadbalancing:us-east-1:1:loadbalancer/app/other/1" in
  with_calls ~list_out:(arn ^ "\n") ~tags_out:"" ~tags_exit:0 (fun ~log:_ ~observations ->
    match load_balancer observations with
    | Sol_cli_absence.Absent a ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the check names both steps"
        true
        (Sol_cli_string.contains ~needle:"describe-tags" a.checked_with)
    | _ -> Windtrap.fail "an untagged inventory must be Absent")
;;

let test_failed_tag_read_is_unobservable () =
  let arn = "arn:aws:elasticloadbalancing:us-east-1:1:loadbalancer/app/acme/1" in
  with_calls
    ~list_out:(arn ^ "\n")
    ~tags_out:"AccessDenied: not authorized\n"
    ~tags_exit:254
    (fun ~log:_ ~observations ->
       match load_balancer observations with
       | Sol_cli_absence.Unobservable u ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the reason is the provider's"
           true
           (Sol_cli_string.contains ~needle:"AccessDenied" u.reason)
       | _ -> Windtrap.fail "a failed tag read must be Unobservable")
;;

let%test "load balancer inventory: uses only supported AWS commands" =
  test_load_balancers_use_a_supported_command ()
;;

let%test "load balancer inventory: a tagged load balancer is Present" =
  test_tagged_load_balancer_is_present ()
;;

let%test "load balancer inventory: an untagged inventory is Absent" =
  test_untagged_inventory_is_absent ()
;;

let%test "load balancer inventory: a failed tag read is Unobservable" =
  test_failed_tag_read_is_unobservable ()
;;

let aws_not_found_needles = [ "notfound"; "not found"; "does not exist"; "no such" ]
let gcp_not_found_needles = [ "not found"; "notfound"; "does not exist"; "was not found" ]

let test_not_found_wording_is_provider_specific () =
  let classified needles reason = Sol_cli_absence.not_found ~needles reason in
  let agrees needles message =
    classified aws_not_found_needles message = classified needles message
  in
  let same message =
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "aws and gcp agree on %S" message)
      true
      (agrees gcp_not_found_needles message)
  in
  same
    "An error occurred (ResourceNotFoundException) when calling the ListClusters \
     operation";
  same "ERROR: (gcloud.container.clusters.list) NOT_FOUND: the resource was not found";
  same "the resource was not found";
  same "does not exist";
  same "AccessDenied: not authorized";
  same "";
  Windtrap.equal
    Windtrap.bool
    ~msg:"aws treats 'no such ...' as not-found"
    true
    (classified aws_not_found_needles "no such file or directory");
  Windtrap.equal
    Windtrap.bool
    ~msg:"gcp is fail-closed on 'no such ...' -- the two copies really do diverge"
    false
    (classified gcp_not_found_needles "no such file or directory")
;;

let%test "absence scan: both providers agree except on 'no such'" =
  test_not_found_wording_is_provider_specific ()
;;

let test_a_not_found_list_failure_is_unobservable () =
  with_calls
    ~list_out:
      "An error occurred (ResourceNotFoundException): the load balancer could not be found\n"
    ~list_exit:1
    ~tags_out:""
    ~tags_exit:0
    (fun ~log:_ ~observations ->
       match load_balancer observations with
       | Sol_cli_absence.Unobservable u ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the provider's not-found text is kept as the unknown's reason"
           true
           (Sol_cli_string.contains ~needle:"not be found" u.reason)
       | Sol_cli_absence.Absent _ ->
         Windtrap.fail
           "a failed enumeration containing 'not found' must not become absence"
       | _ -> Windtrap.fail "a failed enumeration must be Unobservable")
;;

let%test "load balancer inventory: a not-found list failure is Unobservable" =
  test_a_not_found_list_failure_is_unobservable ()
;;

let test_mismatched_aws_account_is_unobservable () =
  with_fake_aws
    ~sts_out:"999999999999\n"
    ~list_out:""
    ~list_exit:0
    ~tags_out:""
    ~tags_exit:0
    (fun () ->
       match Sol_cli_aws_absence.substrate_absence target ~cluster_name:"acme-prod" with
       | Sol_cli_absence.Unobservable u ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"the mismatch names the caller's account"
           true
           (Sol_cli_string.contains ~needle:"999999999999" u.reason);
         Windtrap.equal
           Windtrap.bool
           ~msg:"and the account the target declares"
           true
           (Sol_cli_string.contains ~needle:"111122223333" u.reason)
       | Sol_cli_absence.Absent _ ->
         Windtrap.fail "another account's empty listing is not this target's absence"
       | _ -> Windtrap.fail "an account mismatch must be Unobservable")
;;

let test_matching_aws_account_can_establish_absence () =
  with_fake_aws
    ~sts_out:"111122223333\n"
    ~list_out:""
    ~list_exit:0
    ~tags_out:""
    ~tags_exit:0
    (fun () ->
       match Sol_cli_aws_absence.substrate_absence target ~cluster_name:"acme-prod" with
       | Sol_cli_absence.Absent _ -> ()
       | Sol_cli_absence.Unobservable u ->
         Windtrap.failf "the target's own account was refused: %s" u.reason
       | _ -> Windtrap.fail "an empty listing in the target's account is absence")
;;

let%test "EKS absence: a caller in another account is Unobservable" =
  test_mismatched_aws_account_is_unobservable ()
;;

let%test "EKS absence: an empty listing in the target's account is Absent" =
  test_matching_aws_account_can_establish_absence ()
;;
