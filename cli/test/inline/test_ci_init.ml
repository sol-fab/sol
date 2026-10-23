let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let assert_contains label haystack needle =
  check_bool
    (Printf.sprintf "%s: contains %S" label needle)
    true
    (Sol_cli_string.contains ~needle haystack)
;;

let read_file path =
  let ic = open_in path in
  let s = In_channel.input_all ic in
  close_in ic;
  s
;;

let write_file path content =
  Result.get_ok (Sol_cli_fs.mkdir_p (Filename.dirname path));
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let in_temp_dir f =
  let orig = Sys.getcwd () in
  let dir = Filename.temp_file "sol-ci-init-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir orig) f
;;

let seed_workspace () = write_file "sol.yml" "project: testapp\n"
let init ~force () = Sol_cli_ci.init_github ~force ~cwd:(Sys.getcwd ())

let test_writes_an_oidc_workflow () =
  in_temp_dir (fun () ->
    seed_workspace ();
    match init ~force:false () with
    | Error message -> Windtrap.fail message
    | Ok outcome ->
      check_bool "written" true outcome.written;
      check_bool
        "landed at the conventional path"
        true
        (Sys.file_exists Sol_cli_ci.target_rel);
      let content = read_file Sol_cli_ci.target_rel in
      assert_contains "OIDC id-token permission" content "id-token: write";
      assert_contains "AWS OIDC assumption" content "role-to-assume";
      assert_contains "GCP Workload Identity" content "workload_identity_provider";
      assert_contains "explicit target" content {|deploy "$SOL_TARGET"|};
      assert_contains
        "migrate runs the same lifecycle"
        content
        {|migrate apply "$SOL_TARGET"|};
      assert_contains "the releases are named" content "SOL_VERSION";
      assert_contains
        "the workflow installs the release"
        content
        "sol-${SOL_VERSION}-linux-x86_64.tar.gz";
      check_bool
        "the workflow does not build sol from the workspace"
        false
        (Sol_cli_string.contains ~needle:"cli/bin/main.exe" content);
      assert_contains "gated authorization job" content "environment: sol-authorization";
      assert_contains
        "authorization runs grants apply"
        content
        {|grants apply "$SOL_TARGET"|};
      check_bool
        "the deploy waits for authorization"
        true
        (Sol_cli_string.contains ~needle:"needs: authorize" content);
      check_bool
        "no kubeconfig credential"
        false
        (Sol_cli_string.contains ~needle:"KUBECONFIG" content))
;;

let test_rerun_is_idempotent () =
  in_temp_dir (fun () ->
    seed_workspace ();
    let first = init ~force:false () |> Result.get_ok in
    check_bool "first run writes" true first.written;
    let before = read_file Sol_cli_ci.target_rel in
    let second = init ~force:false () |> Result.get_ok in
    check_bool "second run is a no-op" false second.written;
    check_bool
      "content unchanged"
      true
      (String.equal before (read_file Sol_cli_ci.target_rel)))
;;

let test_refuses_to_clobber_an_edited_workflow () =
  in_temp_dir (fun () ->
    seed_workspace ();
    write_file Sol_cli_ci.target_rel "# hand-edited\n";
    match init ~force:false () with
    | Ok _ -> Windtrap.fail "a differing workflow was overwritten without --force"
    | Error message ->
      assert_contains "the refusal names the file" message Sol_cli_ci.target_rel;
      check_bool
        "the edited file is untouched"
        true
        (String.equal "# hand-edited\n" (read_file Sol_cli_ci.target_rel)))
;;

let test_force_overwrites () =
  in_temp_dir (fun () ->
    seed_workspace ();
    write_file Sol_cli_ci.target_rel "# hand-edited\n";
    match init ~force:true () with
    | Error message -> Windtrap.fail message
    | Ok outcome ->
      check_bool "written" true outcome.written;
      assert_contains
        "regenerated as the supported workflow"
        (read_file Sol_cli_ci.target_rel)
        "id-token: write")
;;

let test_an_unreadable_workflow_refuses_without_force () =
  in_temp_dir (fun () ->
    seed_workspace ();
    write_file (Sol_cli_ci.target_rel ^ "/filler") "not the workflow\n";
    check_bool
      "the target path is a directory, so reading it as a file fails"
      true
      (Sys.is_directory Sol_cli_ci.target_rel);
    (match init ~force:false () with
     | Ok _ -> Windtrap.fail "an unreadable workflow was treated as absent and written"
     | Error message ->
       assert_contains
         "the refusal says the file could not be read"
         message
         "could not read";
       assert_contains "the refusal names the file" message Sol_cli_ci.target_rel);
    check_bool
      "the unreadable path is untouched"
      true
      (Sys.is_directory Sol_cli_ci.target_rel);
    let leftovers =
      Sys.readdir (Filename.dirname Sol_cli_ci.target_rel)
      |> Array.to_list
      |> List.filter (fun name -> Sol_cli_string.contains ~needle:".tmp-" name)
    in
    check_bool "no temporary file was left behind" true (leftovers = []))
;;

let test_an_unreadable_workflow_refuses_even_with_force () =
  in_temp_dir (fun () ->
    seed_workspace ();
    write_file (Sol_cli_ci.target_rel ^ "/filler") "not the workflow\n";
    match init ~force:true () with
    | Ok _ -> Windtrap.fail "an unreadable workflow was overwritten under --force"
    | Error message ->
      assert_contains
        "the refusal says the file could not be read"
        message
        "could not read";
      check_bool
        "the unreadable path is untouched"
        true
        (Sys.is_directory Sol_cli_ci.target_rel))
;;

let test_an_unreadable_workflow_is_not_overwritten () =
  in_temp_dir (fun () ->
    seed_workspace ();
    write_file Sol_cli_ci.target_rel "# hand-edited\n";
    Unix.chmod Sol_cli_ci.target_rel 0o000;
    let outcome = init ~force:false () in
    Unix.chmod Sol_cli_ci.target_rel 0o644;
    check_bool
      "the file the process could not read is left exactly as it was"
      true
      (String.equal "# hand-edited\n" (read_file Sol_cli_ci.target_rel));
    match outcome with
    | Ok _ -> Windtrap.fail "a file that could not be read was written"
    | Error _ -> ())
;;

let%test "ci init: writes an OIDC workflow into an existing workspace" =
  test_writes_an_oidc_workflow ()
;;

let%test "ci init: a re-run is idempotent" = test_rerun_is_idempotent ()

let%test "ci init: refuses to clobber an edited workflow" =
  test_refuses_to_clobber_an_edited_workflow ()
;;

let%test "ci init: --force overwrites" = test_force_overwrites ()

let%test "ci init: an unreadable workflow refuses even without --force" =
  test_an_unreadable_workflow_refuses_without_force ()
;;

let%test "ci init: an unreadable workflow refuses under --force too" =
  test_an_unreadable_workflow_refuses_even_with_force ()
;;

let%test "ci init: a workflow that cannot be read is never overwritten" =
  test_an_unreadable_workflow_is_not_overwritten ()
;;
