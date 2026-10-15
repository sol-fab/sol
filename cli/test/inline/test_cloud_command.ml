let temp_dir () =
  let dir = Filename.temp_file "sol-cloud-command-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let write path content =
  Out_channel.with_open_text path (fun oc -> output_string oc content)
;;

let check_opt msg expected actual =
  Windtrap.equal (Windtrap.option Windtrap.string) ~msg expected actual
;;

let test_last_flag_wins () =
  check_opt
    "last --var"
    (Some "b")
    (Sol_cli_terraform_vars.resolved
       "cluster_name"
       ~var_files:[]
       ~vars:[ "cluster_name=a"; "region=x"; "cluster_name = \"b\"" ])
;;

let test_flag_beats_var_file () =
  let dir = temp_dir () in
  let file = Filename.concat dir "t.tfvars" in
  write file "cluster_name = \"from-file\"\n";
  check_opt
    "flag"
    (Some "flag")
    (Sol_cli_terraform_vars.resolved
       "cluster_name"
       ~var_files:[ file ]
       ~vars:[ "cluster_name=flag" ])
;;

let test_var_file_skips_comments_and_other_keys () =
  let dir = temp_dir () in
  let file = Filename.concat dir "t.tfvars" in
  write
    file
    "# cluster_name = \"commented\"\n\ncluster_names = \"x\"\ncluster_name = \"real\"\n";
  check_opt
    "file"
    (Some "real")
    (Sol_cli_terraform_vars.resolved "cluster_name" ~var_files:[ file ] ~vars:[])
;;

let test_unreadable_var_file_assigns_nothing () =
  check_opt
    "absent"
    None
    (Sol_cli_terraform_vars.resolved
       "cluster_name"
       ~var_files:[ "/nonexistent/sol.tfvars" ]
       ~vars:[])
;;

let with_workspace ~declared f =
  let dir = temp_dir () in
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       write "sol.yml" "project: pluto\n";
       if declared
       then
         Targets_fixture.write
           ~target:"dev/aws/us-east-1"
           "target:\n  cluster_name: sol-dev\n";
       f ())
;;

let test_strict_refuses_undeclared_target () =
  with_workspace ~declared:false (fun () ->
    match
      Sol_cli_terraform_vars.of_target ~strict:true ~workspace:"pluto" "dev/aws/us-east-1"
    with
    | Ok _ -> Windtrap.fail "expected an undeclared target to be refused"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"names the reason"
        true
        (Sol_cli_string.contains ~needle:"is not declared" message))
;;

let test_preview_accepts_undeclared_target () =
  with_workspace ~declared:false (fun () ->
    match
      Sol_cli_terraform_vars.of_target
        ~strict:false
        ~workspace:"pluto"
        "dev/aws/us-east-1"
    with
    | Ok (_, config) ->
      Windtrap.equal
        Windtrap.string
        ~msg:"region"
        "us-east-1"
        config.Sol_cli_config.target.region
    | Error message -> Windtrap.fail message)
;;

let test_strict_accepts_declared_target () =
  with_workspace ~declared:true (fun () ->
    match
      Sol_cli_terraform_vars.of_target ~strict:true ~workspace:"pluto" "dev/aws/us-east-1"
    with
    | Ok (vars, _) ->
      Windtrap.equal
        (Windtrap.option Windtrap.string)
        ~msg:"the target's field is a variable"
        (Some "sol-dev")
        (List.assoc_opt "cluster_name" vars)
    | Error message -> Windtrap.fail message)
;;

let running =
  Sol_cli_supervised.Running { pid = 1; host = "h"; started_at = 0.; dir = "/d" }
;;

let unresolved = Sol_cli_supervised.Unresolved { reason = "killed"; dir = "/d" }

let resolved =
  Sol_cli_supervised.Resolved { outcome = Sol_cli_supervised.Exited 1; dir = "/d" }
;;

let verdict_name = function
  | Sol_cli_state_guard.Proceed -> "proceed"
  | Warn _ -> "warn"
  | Acknowledge _ -> "acknowledge"
  | Refuse _ -> "refuse"
;;

let check_verdict label expected ~constructive ~accept_unresolved status =
  Windtrap.equal
    Windtrap.string
    ~msg:label
    expected
    (verdict_name (Sol_cli_state_guard.verdict ~constructive ~accept_unresolved status))
;;

let test_guard_matrix () =
  check_verdict
    "nothing before"
    "proceed"
    ~constructive:true
    ~accept_unresolved:false
    Sol_cli_supervised.No_previous;
  check_verdict
    "a graceful exit"
    "proceed"
    ~constructive:true
    ~accept_unresolved:false
    resolved;
  check_verdict
    "running, even for a plan"
    "refuse"
    ~constructive:false
    ~accept_unresolved:true
    running;
  check_verdict
    "unresolved, plan or destroy"
    "warn"
    ~constructive:false
    ~accept_unresolved:false
    unresolved;
  check_verdict
    "unresolved, apply"
    "refuse"
    ~constructive:true
    ~accept_unresolved:false
    unresolved;
  check_verdict
    "unresolved, apply, reconciled"
    "acknowledge"
    ~constructive:true
    ~accept_unresolved:true
    unresolved
;;

let test_kinds_are_the_last_column () =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"kinds"
    [ "ClusterIssuer"; "ConfigMap"; "Pod" ]
    (Sol_cli_platform_teardown.kinds_of_api_resources
       "configmaps       cm    v1                   true   ConfigMap\n\
        pods             po    v1                   true   Pod\n\
        clusterissuers         cert-manager.io/v1   false  ClusterIssuer\n\
        pods             po    v1                   true   Pod\n\n")
;;

let show_json =
  {|{"values":{"root_module":{"resources":[
     {"address":"kubernetes_manifest.issuer","type":"kubernetes_manifest",
      "values":{"manifest":{"kind":"ClusterIssuer"}}},
     {"address":"kubernetes_manifest.cm","type":"kubernetes_manifest",
      "values":{"manifest":null,"object":{"kind":"ConfigMap"}}},
     {"address":"kubernetes_namespace.ns","type":"kubernetes_namespace",
      "values":{"metadata":[{"name":"x"}]}}
   ]}}}|}
;;

let test_only_unserved_manifests_are_forgotten () =
  match
    Sol_cli_platform_teardown.unserved_of_show_json ~served:[ "ConfigMap" ] show_json
  with
  | Error message -> Windtrap.fail message
  | Ok unserved ->
    Windtrap.equal
      (Windtrap.list (Windtrap.pair Windtrap.string Windtrap.string))
      ~msg:"the unserved manifest, with its proof"
      [ "kubernetes_manifest.issuer", "ClusterIssuer" ]
      unserved
;;

let test_served_kinds_forget_nothing () =
  match
    Sol_cli_platform_teardown.unserved_of_show_json
      ~served:[ "ClusterIssuer"; "ConfigMap" ]
      show_json
  with
  | Error message -> Windtrap.fail message
  | Ok unserved -> Windtrap.equal Windtrap.int ~msg:"nothing" 0 (List.length unserved)
;;

let test_unreadable_state_is_an_error () =
  (match Sol_cli_platform_teardown.unserved_of_show_json ~served:[] "not json" with
   | Ok _ -> Windtrap.fail "expected invalid JSON to be an error"
   | Error _ -> ());
  match Sol_cli_platform_teardown.unserved_of_show_json ~served:[] {|{"values":{}}|} with
  | Ok _ -> Windtrap.fail "expected a state with no resources list to be an error"
  | Error _ -> ()
;;

let%test "terraform vars: last flag wins" = test_last_flag_wins ()
let%test "terraform vars: flag beats var file" = test_flag_beats_var_file ()

let%test "terraform vars: var file comments and keys" =
  test_var_file_skips_comments_and_other_keys ()
;;

let%test "terraform vars: unreadable var file" =
  test_unreadable_var_file_assigns_nothing ()
;;

let%test "target: strict refuses undeclared" = test_strict_refuses_undeclared_target ()
let%test "target: preview accepts undeclared" = test_preview_accepts_undeclared_target ()
let%test "target: strict accepts declared" = test_strict_accepts_declared_target ()
let%test "target: verdicts" = test_guard_matrix ()
let%test "platform teardown: kinds" = test_kinds_are_the_last_column ()

let%test "platform teardown: unserved manifests" =
  test_only_unserved_manifests_are_forgotten ()
;;

let%test "platform teardown: served kinds" = test_served_kinds_forget_nothing ()
let%test "platform teardown: unreadable state" = test_unreadable_state_is_an_error ()
