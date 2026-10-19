let check msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual
let check_str msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let ok_result = function
  | Ok r -> r
  | Error e -> Windtrap.fail ("unexpected error: " ^ Sol_cli_process.error_to_string e)
;;

let err_result = function
  | Error e -> e
  | Ok _ -> Windtrap.fail "expected error but got Ok"
;;

let test_successful_run () =
  let r = ok_result (Sol_cli_process.run (Sol_cli_process.cmd [ "echo"; "hello" ])) in
  check_str "stdout" "hello" r.stdout
;;

let test_non_zero_exit () =
  match err_result (Sol_cli_process.run (Sol_cli_process.cmd [ "false" ])) with
  | Sol_cli_process.Non_zero { exit_code; _ } ->
    check_bool "exit_code non-zero" true (exit_code <> 0)
  | e -> Windtrap.fail ("wrong error: " ^ Sol_cli_process.error_to_string e)
;;

let test_captured_stderr () =
  match
    err_result
      (Sol_cli_process.run
         (Sol_cli_process.cmd [ "sh"; "-c"; "echo out; echo oops >&2; exit 3" ]))
  with
  | Sol_cli_process.Non_zero { exit_code; stdout; stderr } ->
    check "exit code" 3 exit_code;
    check_str "stdout kept" "out" stdout;
    check_str "stderr captured" "oops" stderr
  | e -> Windtrap.fail ("wrong error: " ^ Sol_cli_process.error_to_string e)
;;

let test_stdout_and_stderr_separate () =
  let r =
    ok_result
      (Sol_cli_process.run (Sol_cli_process.cmd [ "sh"; "-c"; "echo out; echo err >&2" ]))
  in
  check_str "stdout" "out" r.stdout;
  check_str "stderr" "err" r.stderr
;;

let test_process_can_start_with_an_explicit_environment_only () =
  let original = Sys.getenv_opt "SOL_TEST_PRIVATE_ENV" in
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some value -> Unix.putenv "SOL_TEST_PRIVATE_ENV" value
      | None -> Unix.putenv "SOL_TEST_PRIVATE_ENV" "")
    (fun () ->
       Unix.putenv "SOL_TEST_PRIVATE_ENV" "ambient-secret";
       let output =
         ok_result
           (Sol_cli_process.run
              (Sol_cli_process.cmd
                 ~env:[ "SOL_TEST_EXPLICIT_ENV", "visible" ]
                 ~inherit_env:false
                 [ "sh"
                 ; "-c"
                 ; "printf '%s:%s' \"${SOL_TEST_PRIVATE_ENV-unset}\" \
                    \"$SOL_TEST_EXPLICIT_ENV\""
                 ]))
       in
       check_str
         "the child gets only the explicit environment"
         "unset:visible"
         output.stdout)
;;

let test_detached_process_honors_explicit_environment_only () =
  let path = Filename.temp_file "sol-process-env-" ".txt" in
  Sys.remove path;
  let original = Sys.getenv_opt "SOL_TEST_PRIVATE_ENV" in
  Fun.protect
    ~finally:(fun () ->
      (match original with
       | Some value -> Unix.putenv "SOL_TEST_PRIVATE_ENV" value
       | None -> Unix.putenv "SOL_TEST_PRIVATE_ENV" "");
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
       Unix.putenv "SOL_TEST_PRIVATE_ENV" "ambient-secret";
       let child =
         ok_result
           (Sol_cli_process.spawn_detached
              (Sol_cli_process.cmd
                 ~env:[ "SOL_TEST_EXPLICIT_ENV", "visible"; "SOL_TEST_OUTPUT", path ]
                 ~inherit_env:false
                 [ "sh"
                 ; "-c"
                 ; "printf '%s:%s' \"${SOL_TEST_PRIVATE_ENV-unset}\" \
                    \"$SOL_TEST_EXPLICIT_ENV\" > \"$SOL_TEST_OUTPUT\""
                 ]))
       in
       (* [>] creates the file before the child writes it; polling existence can
          observe an empty file. Wait for the expected content instead. *)
       let expected = "unset:visible" in
       let rec await attempts =
         if Sys.file_exists path
         then (
           let output = In_channel.with_open_bin path In_channel.input_all in
           if String.equal output expected || attempts = 0
           then output
           else (
             Unix.sleepf 0.01;
             await (attempts - 1)))
         else if attempts = 0
         then (
           Sol_cli_process.stop child;
           Windtrap.fail "detached child did not write its result")
         else (
           Unix.sleepf 0.01;
           await (attempts - 1))
       in
       let output = await 100 in
       Sol_cli_process.join child;
       check_str "detached child gets only explicit environment" expected output)
;;

let test_spawn_failed () =
  match
    err_result (Sol_cli_process.run (Sol_cli_process.cmd [ "/nonexistent-binary-xyz" ]))
  with
  | Sol_cli_process.Spawn_failed _ -> ()
  | e -> Windtrap.fail ("expected Spawn_failed, got: " ^ Sol_cli_process.error_to_string e)
;;

let test_chdir_failed () =
  match
    err_result
      (Sol_cli_process.run (Sol_cli_process.cmd ~cwd:"/nonexistent-dir-xyz" [ "pwd" ]))
  with
  | Sol_cli_process.Spawn_failed msg ->
    check_bool "mentions chdir" true (Sol_cli_string.contains msg ~needle:"chdir")
  | e -> Windtrap.fail ("expected Spawn_failed, got: " ^ Sol_cli_process.error_to_string e)
;;

let test_redaction_in_echo () =
  let secret = "s3cr3t-p4ss" in
  let (), reported =
    Sol_cli_report.collect (fun () ->
      ignore
        (Sol_cli_process.run
           ~echo:true
           (Sol_cli_process.cmd ~redact:[ secret ] [ "echo"; secret ])))
  in
  let output = reported |> List.map snd |> String.concat "\n" in
  check_bool "secret not in echo" false (Sol_cli_string.contains output ~needle:secret);
  check_bool
    "redaction marker present"
    true
    (Sol_cli_string.contains output ~needle:"***")
;;

let test_no_shell_expansion () =
  let r = ok_result (Sol_cli_process.run (Sol_cli_process.cmd [ "echo"; "$HOME" ])) in
  check_str "no shell expansion" "$HOME" r.stdout
;;

let test_run_shell_success () =
  let r = ok_result (Sol_cli_process.run_shell "echo hello-shell") in
  check_str "shell stdout" "hello-shell" r.stdout
;;

let test_run_shell_nonzero () =
  match err_result (Sol_cli_process.run_shell "exit 42") with
  | Sol_cli_process.Non_zero { exit_code; _ } -> check "shell exit 42" 42 exit_code
  | e -> Windtrap.fail ("wrong error: " ^ Sol_cli_process.error_to_string e)
;;

let with_alarm seconds f =
  let previous = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Exit)) in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = seconds });
  let outcome =
    match f () with
    | value -> Ok value
    | exception Exit -> Error `Timed_out
  in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0. });
  Sys.set_signal Sys.sigalrm previous;
  outcome
;;

let fd_count () = Array.length (Sys.readdir "/proc/self/fd")

let check_drained label runner =
  match with_alarm 5.0 runner with
  | Error `Timed_out -> Windtrap.fail (label ^ " stalled on a full stderr pipe")
  | Ok (Ok ({ stdout; stderr } : Sol_cli_process.output)) ->
    check_str (label ^ " stdout intact") "done" stdout;
    check (label ^ " stderr drained") 262144 (String.length stderr)
  | Ok (Error e) -> Windtrap.fail (label ^ ": " ^ Sol_cli_process.error_to_string e)
;;

let test_shell_drains_both_streams () =
  check_drained "run_shell" (fun () ->
    Sol_cli_process.run_shell "head -c 262144 /dev/zero >&2; echo done")
;;

let test_argv_drains_both_streams () =
  check_drained "run" (fun () ->
    Sol_cli_process.run
      (Sol_cli_process.cmd [ "sh"; "-c"; "head -c 262144 /dev/zero >&2; echo done" ]))
;;

let test_deadline_covers_child_exit () =
  let start = Unix.gettimeofday () in
  let result =
    Sol_cli_process.run
      (Sol_cli_process.cmd ~timeout_s:0.05 [ "sh"; "-c"; "exec 1>&- 2>&-; sleep 0.5" ])
  in
  let elapsed = Unix.gettimeofday () -. start in
  (match result with
   | Error (Sol_cli_process.Timeout _) -> ()
   | Error e ->
     Windtrap.fail ("expected Timeout, got " ^ Sol_cli_process.error_to_string e)
   | Ok _ -> Windtrap.fail "expected Timeout once the child outlives its pipes");
  check_bool "prompt timeout" true (elapsed < 0.4)
;;

let test_deadline_while_capturing () =
  let start = Unix.gettimeofday () in
  let result =
    Sol_cli_process.run (Sol_cli_process.cmd ~timeout_s:0.05 [ "sh"; "-c"; "sleep 0.5" ])
  in
  let elapsed = Unix.gettimeofday () -. start in
  (match result with
   | Error (Sol_cli_process.Timeout _) -> ()
   | Error e ->
     Windtrap.fail ("expected Timeout, got " ^ Sol_cli_process.error_to_string e)
   | Ok _ -> Windtrap.fail "expected Timeout while the pipes stay open");
  check_bool "prompt timeout" true (elapsed < 0.4)
;;

let test_deadline_preserves_short_commands () =
  let r =
    ok_result
      (Sol_cli_process.run (Sol_cli_process.cmd ~timeout_s:5.0 [ "sh"; "-c"; "echo ok" ]))
  in
  check_str "stdout" "ok" r.stdout
;;

let test_handled_signal_completes_capture () =
  let previous = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> ())) in
  let before = fd_count () in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0.05 });
  let result =
    Sol_cli_process.run (Sol_cli_process.cmd [ "sh"; "-c"; "sleep 0.2; echo done" ])
  in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0. });
  Sys.set_signal Sys.sigalrm previous;
  (match result with
   | Ok { stdout; _ } -> check_str "completed despite a handled signal" "done" stdout
   | Error e ->
     Windtrap.fail
       ("handled signal aborted the command: " ^ Sol_cli_process.error_to_string e));
  check "no descriptor leak" before (fd_count ())
;;

let test_interrupted_capture_cleans_up () =
  let previous = Sys.signal Sys.sigalrm (Sys.Signal_handle (fun _ -> raise Exit)) in
  let before = fd_count () in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0.05 });
  let raised =
    match Sol_cli_process.run (Sol_cli_process.cmd [ "sleep"; "5" ]) with
    | _ -> false
    | exception Exit -> true
  in
  ignore (Unix.setitimer Unix.ITIMER_REAL { Unix.it_interval = 0.; it_value = 0. });
  Sys.set_signal Sys.sigalrm previous;
  check_bool "interruption propagates" true raised;
  check "no descriptor leak on interruption" before (fd_count ());
  let unreaped =
    match Unix.waitpid [ Unix.WNOHANG ] (-1) with
    | 0, _ -> 0
    | pid, _ -> pid
    | exception Unix.Unix_error _ -> 0
  in
  check "no unreaped child" 0 unreaped
;;

let test_error_to_string_spawn () =
  let s = Sol_cli_process.error_to_string (Sol_cli_process.Spawn_failed "oops") in
  check_bool
    "Sol_cli_string.contains spawn"
    true
    (Sol_cli_string.contains s ~needle:"spawn")
;;

let test_error_to_string_nonzero () =
  let s =
    Sol_cli_process.error_to_string
      (Sol_cli_process.Non_zero { exit_code = 5; stdout = ""; stderr = "bad" })
  in
  check_bool "Sol_cli_string.contains 5" true (Sol_cli_string.contains s ~needle:"5")
;;

let test_error_to_string_keeps_stdout () =
  let s =
    Sol_cli_process.error_to_string
      (Sol_cli_process.Non_zero { exit_code = 1; stdout = "said on stdout"; stderr = "" })
  in
  check_bool "stdout kept" true (Sol_cli_string.contains s ~needle:"said on stdout")
;;

let test_run_is_success () =
  let open Sol_cli_process in
  (match run (cmd [ "sh"; "-c"; "echo hi" ]) with
   | Ok { stdout; _ } ->
     Windtrap.equal Windtrap.string ~msg:"stdout (trimmed)" "hi" stdout
   | Error e -> Windtrap.fail (error_to_string e));
  match run (cmd [ "/nonexistent-zxqw" ]) with
  | Error (Spawn_failed _) -> ()
  | _ -> Windtrap.fail "a missing binary is Spawn_failed"
;;

let test_completed () =
  let open Sol_cli_process in
  (match completed ~exit_code:0 ~stdout:"o" ~stderr:"e" with
   | Ok { stdout = "o"; stderr = "e" } -> ()
   | _ -> Windtrap.fail "exit 0 is Ok with both streams");
  match completed ~exit_code:2 ~stdout:"o" ~stderr:"e" with
  | Error (Non_zero { exit_code = 2; stdout = "o"; stderr = "e" }) -> ()
  | _ -> Windtrap.fail "exit 2 is Non_zero with the code and both streams"
;;

let test_failure_message () =
  let f stdout stderr =
    Sol_cli_process.failure_message { exit_code = 4; stdout; stderr }
  in
  Windtrap.equal Windtrap.string ~msg:"stderr first" "boom" (f "out" " boom\n");
  Windtrap.equal Windtrap.string ~msg:"stdout when stderr is blank" "out" (f "out\n" "  ");
  Windtrap.equal
    Windtrap.string
    ~msg:"the code when both are blank"
    "exited with code 4"
    (f "" " ")
;;

let%test "run: successful run" = test_successful_run ()
let%test "run: non-zero exit" = test_non_zero_exit ()
let%test "run: run is Ok only on success (REFAC-124)" = test_run_is_success ()
let%test "run: completed shares run's contract" = test_completed ()
let%test "run: failure_message" = test_failure_message ()
let%test "run: error_to_string keeps stdout" = test_error_to_string_keeps_stdout ()
let%test "run: captured stderr" = test_captured_stderr ()
let%test "run: stdout stderr separate" = test_stdout_and_stderr_separate ()

let%test "run: explicit env excludes inherited values" =
  test_process_can_start_with_an_explicit_environment_only ()
;;

let%test "spawn_detached: explicit env excludes inherited values" =
  test_detached_process_honors_explicit_environment_only ()
;;

let%test "run: spawn failed" = test_spawn_failed ()
let%test "run: chdir failed" = test_chdir_failed ()
let%test "run: no shell expansion" = test_no_shell_expansion ()
let%test "echo_redaction: secret redacted in echo" = test_redaction_in_echo ()
let%test "run_shell: shell success" = test_run_shell_success ()
let%test "run_shell: shell non-zero" = test_run_shell_nonzero ()

let%test "run_shell: shell drains both streams (CODE_LAYER-023)" =
  test_shell_drains_both_streams ()
;;

let%test "deadline: argv drains both streams (CODE_LAYER-023)" =
  test_argv_drains_both_streams ()
;;

let%test "deadline: deadline covers child exit (BUG-068)" =
  test_deadline_covers_child_exit ()
;;

let%test "deadline: deadline covers pipe capture (BUG-068)" =
  test_deadline_while_capturing ()
;;

let%test "deadline: short commands keep output (BUG-068)" =
  test_deadline_preserves_short_commands ()
;;

let%test "ownership: handled signal completes capture (CODE_LAYER-025)" =
  test_handled_signal_completes_capture ()
;;

let%test "ownership: interrupted capture cleans up (CODE_LAYER-025)" =
  test_interrupted_capture_cleans_up ()
;;

let%test "error_to_string: spawn error" = test_error_to_string_spawn ()
let%test "error_to_string: non-zero error" = test_error_to_string_nonzero ()
