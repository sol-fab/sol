let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let context_name (ctx : Sol_cli_kube_destination.context) = ctx.destination.context

let write path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/"
  then ()
  else if Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let with_temp_dir f =
  let dir = Filename.temp_file "sol-destination-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir cwd)
    (fun () ->
       Sys.chdir dir;
       f ())
;;

let write_base () = write "sol.yml" "project: pluto\n"

let write_target kube_context =
  mkdir_p "sol/prod/aws";
  Targets_fixture.write
    ~target:"prod/aws/us-east-1"
    (Printf.sprintf
       "target:\n  cluster_name: prod-cluster\n%s"
       (match kube_context with
        | Some c -> Printf.sprintf "  kube_context: %s\n" c
        | None -> ""))
;;

let ok_or_fail = function
  | Ok value -> value
  | Error message -> Windtrap.fail ("unexpected error: " ^ message)
;;

let error_or_fail = function
  | Error message -> message
  | Ok _ -> Windtrap.fail "expected the resolution to fail closed"
;;

let test_local_entry_point_is_the_literal_local_cluster () =
  let ctx =
    ok_or_fail (Sol_cli_destination.resolve ~command:"rollback" ~local:true ~target:None)
  in
  check_string "local destination" "k3d-sol-local" (context_name ctx)
;;

let test_local_wins_even_if_a_target_is_supplied () =
  let ctx =
    ok_or_fail
      (Sol_cli_destination.resolve
         ~command:"rollback"
         ~local:true
         ~target:(Some "prod/aws/us-east-1"))
  in
  check_string "local destination" "k3d-sol-local" (context_name ctx)
;;

let test_top_level_without_target_fails_closed_naming_local_form () =
  let message =
    error_or_fail
      (Sol_cli_destination.resolve ~command:"rollback" ~local:false ~target:None)
  in
  check_bool "names --target" true (Sol_cli_string.contains ~needle:"--target" message);
  check_bool
    "names the local rollback spelling"
    true
    (Sol_cli_string.contains ~needle:"sol local rollback" message)
;;

let test_local_form_message_is_command_specific () =
  let message =
    error_or_fail
      (Sol_cli_destination.resolve ~command:"rollback" ~local:false ~target:None)
  in
  check_bool
    "names rollback's local spelling, not status's"
    true
    (Sol_cli_string.contains ~needle:"sol local rollback" message)
;;

let test_top_level_target_supplies_the_destination () =
  with_temp_dir (fun () ->
    write_base ();
    write_target (Some "prod-cluster");
    let ctx =
      ok_or_fail
        (Sol_cli_destination.resolve
           ~command:"rollback"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_string "target's destination" "prod-cluster" (context_name ctx))
;;

let test_target_without_context_fails_closed () =
  with_temp_dir (fun () ->
    write_base ();
    write_target None;
    let message =
      error_or_fail
        (Sol_cli_destination.resolve
           ~command:"rollback"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_bool
      "the message says what to add"
      true
      (Sol_cli_string.contains ~needle:"kube_context" message))
;;

let test_reserved_local_target_points_at_local_form () =
  with_temp_dir (fun () ->
    write_base ();
    write_target (Some "k3d-sol-local");
    let message =
      error_or_fail
        (Sol_cli_destination.resolve
           ~command:"rollback"
           ~local:false
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_bool
      "redirects to the local spelling"
      true
      (Sol_cli_string.contains ~needle:"sol local <command>" message))
;;

let test_resolution_is_deterministic () =
  let resolve () =
    Sol_cli_destination.resolve ~command:"rollback" ~local:false ~target:None
  in
  match resolve (), resolve () with
  | Error a, Error b -> check_string "same error twice" a b
  | Ok a, Ok b -> check_string "same context twice" (context_name a) (context_name b)
  | _ -> Windtrap.fail "resolution disagreed with itself"
;;

(* 2b: rollback needs both the cluster and the target config to derive its database
   bindings. `resolve_with_config` reads once, and the refusal a remote command shows for a
   missing target is the same one `resolve` shows, so the command layer and the library
   cannot disagree about a targetless rollback. *)
let test_resolve_with_config_shares_the_refusal_and_returns_the_config () =
  with_temp_dir (fun () ->
    write_base ();
    write_target (Some "prod-cluster");
    let ctx, config =
      ok_or_fail
        (Sol_cli_destination.resolve_with_config
           ~command:"rollback"
           ~target:(Some "prod/aws/us-east-1"))
    in
    check_string "target's destination" "prod-cluster" (context_name ctx);
    check_string
      "the target config comes back with the cluster"
      "pluto"
      (Option.value ~default:"" config.Sol_cli_config.project));
  let missing_target =
    error_or_fail
      (Sol_cli_destination.resolve_with_config ~command:"rollback" ~target:None)
  in
  let resolve_refused =
    error_or_fail
      (Sol_cli_destination.resolve ~command:"rollback" ~local:false ~target:None)
  in
  check_string "one refusal for both entry points" resolve_refused missing_target
;;

let%test "seam: local entry point is the literal local cluster" =
  test_local_entry_point_is_the_literal_local_cluster ()
;;

let%test "seam: local wins even if a target is supplied" =
  test_local_wins_even_if_a_target_is_supplied ()
;;

let%test "seam: top-level without target fails closed naming local form" =
  test_top_level_without_target_fails_closed_naming_local_form ()
;;

let%test "seam: the local spelling in the message is command-specific" =
  test_local_form_message_is_command_specific ()
;;

let%test "seam: top-level target supplies the destination" =
  test_top_level_target_supplies_the_destination ()
;;

let%test "seam: target without a kube_context fails closed" =
  test_target_without_context_fails_closed ()
;;

let%test "seam: a reserved-local target points at the local form" =
  test_reserved_local_target_points_at_local_form ()
;;

let%test "seam: resolution is deterministic" = test_resolution_is_deterministic ()

let%test "2b: resolve_with_config returns the config and shares the refusal" =
  test_resolve_with_config_shares_the_refusal_and_returns_the_config ()
;;
