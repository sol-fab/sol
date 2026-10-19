module T = Sol_cli_terraform

let require = function
  | Ok value -> value
  | Error message -> Windtrap.fail message
;;

let read path = In_channel.with_open_bin path In_channel.input_all

let write path value =
  Out_channel.with_open_bin path (fun channel -> output_string channel value)
;;

let check message condition = Windtrap.equal Windtrap.bool ~msg:message true condition

let temp_dir () =
  let file = Filename.temp_file "sol-private-plan-test-" "" in
  Sys.remove file;
  Unix.mkdir file 0o700;
  file
;;

let rec files root =
  Sys.readdir root
  |> Array.to_list
  |> List.concat_map (fun name ->
    let path = Filename.concat root name in
    if Sys.is_directory path then files path else [ path ])
;;

let fake =
  {|#!/usr/bin/env python3
import json, os, signal, sys, time
args = sys.argv[1:]
root = next(arg.split('=', 1)[1] for arg in args if arg.startswith('-chdir='))
mode = open(root + '/mode').read()
if 'plan' in args:
    path = next(arg.split('=', 1)[1] for arg in args if arg.startswith('-out='))
    with open(root + '/observed.json', 'w') as output:
        json.dump({'path': path, 'file_mode': os.stat(path).st_mode & 0o777,
                   'dir_mode': os.stat(os.path.dirname(path)).st_mode & 0o777}, output)
    with open(path, 'w') as output:
        output.write('credentialCanaryPrivatePlan')
    with open(path + '.args', 'w') as output:
        output.write('private companion')
    if mode == 'interrupt':
        signal.signal(signal.SIGINT, lambda *_: sys.exit(1))
        open(root + '/ready', 'w').close()
        time.sleep(30)
    if mode == 'plan-failure':
        sys.stderr.write('OriginalPlanFailure: refused\n')
        sys.exit(1)
elif 'show' in args:
    print(json.dumps({'variables': {'password': {'value': 'credentialCanaryPrivatePlan'}},
                      'resource_changes': []}))
elif 'apply' in args and mode == 'apply-failure':
    sys.stderr.write('OriginalApplyFailure: refused\n')
    sys.exit(1)
|}
;;

let run_case mode =
  let root = temp_dir () in
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       let executable = Filename.concat root "terraform" in
       write executable fake;
       Unix.chmod executable 0o700;
       write (Filename.concat root "mode") mode;
       match Unix.fork () with
       | 0 ->
         ignore (Unix.setsid ());
         Unix.putenv "PATH" (root ^ ":" ^ Option.value (Sys.getenv_opt "PATH") ~default:"");
         (* A caller-supplied TMPDIR may be a CI cache or artifact directory. *)
         Unix.putenv "TMPDIR" root;
         let run_log =
           Sol_cli_run_log.create ~base:(Filename.concat root "logs") ~prefix:"private" ()
         in
         let result =
           Sol_cli_terraform_steps.apply_asserted
             ~run_log
             ~phase_name:"test"
             ~policy:{ Sol_cli_terraform_plan.phase = "test"; rules = [] }
             ~scope:T.whole_root
             ~chdir:root
             ~var_files:[]
             ~vars:[]
             ()
         in
         write
           (Filename.concat root "result")
           (match result with
            | Ok () -> "OK"
            | Error message -> message);
         exit 0
       | child ->
         let wait_until test =
           let deadline = Unix.gettimeofday () +. 15. in
           let rec wait () =
             if test ()
             then ()
             else if Unix.gettimeofday () > deadline
             then (
               (try Unix.kill (-child) Sys.sigkill with
                | Unix.Unix_error _ -> ());
               ignore (Unix.waitpid [] child);
               Windtrap.fail "private-plan child did not finish")
             else (
               Unix.sleepf 0.02;
               wait ())
           in
           wait ()
         in
         if mode = "interrupt"
         then (
           wait_until (fun () -> Sys.file_exists (Filename.concat root "ready"));
           Unix.kill child Sys.sigterm);
         let status = ref None in
         wait_until (fun () ->
           match Unix.waitpid [ Unix.WNOHANG ] child with
           | 0, _ -> false
           | _, value ->
             status := Some value;
             true);
         check "test child completed normally" (!status = Some (Unix.WEXITED 0));
         let observed =
           Yojson.Safe.from_string (read (Filename.concat root "observed.json"))
         in
         let integer name = Sol_cli_json.field [ name ] observed |> Sol_cli_json.int in
         check "plan begins at 0600" (integer "file_mode" = Some 0o600);
         check "plan directory is 0700" (integer "dir_mode" = Some 0o700);
         let path =
           Sol_cli_json.require
             ~what:"observed plan"
             [ "path" ]
             Sol_cli_json.string
             observed
           |> require
         in
         check
           "plan ignores artifact/cache TMPDIR"
           (not (String.starts_with ~prefix:(root ^ "/") path));
         check "binary removed" (not (Sys.file_exists path));
         check "companion removed" (not (Sys.file_exists (path ^ ".args")));
         check "private directory removed" (not (Sys.file_exists (Filename.dirname path)));
         let result = read (Filename.concat root "result") in
         check "failure/success preserved" (result = "OK" = (mode = "success"));
         if mode = "plan-failure"
         then
           check
             "plan diagnostic preserved"
             (Sol_cli_string.contains ~needle:"OriginalPlanFailure" result);
         if mode = "apply-failure"
         then
           check
             "apply diagnostic preserved"
             (Sol_cli_string.contains ~needle:"OriginalApplyFailure" result);
         files (Filename.concat root "logs")
         |> List.iter (fun file ->
           check
             "run logs omit private plan values"
             (not
                (Sol_cli_string.contains
                   ~needle:"credentialCanaryPrivatePlan"
                   (read file)))))
;;

let test_cleanup_failure () =
  let file = T.create_private_plan () |> require in
  let path = T.private_plan_path file in
  let directory = Filename.dirname path in
  write path "credentialCanaryPrivatePlan";
  Fun.protect
    ~finally:(fun () ->
      Unix.chmod directory 0o700;
      T.discard_private_plan file)
    (fun () ->
       Unix.chmod directory 0;
       let input, output = Unix.pipe () in
       match Unix.fork () with
       | 0 ->
         Unix.close input;
         if Unix.geteuid () = 0 then Unix.setuid 65534;
         let (), messages =
           Sol_cli_report.collect (fun () -> T.discard_private_plan file)
         in
         let text = String.concat "\n" (List.map snd messages) in
         let valid =
           Sol_cli_string.contains ~needle:"plan cleanup failed" text
           && not (Sol_cli_string.contains ~needle:"credentialCanary" text)
         in
         ignore
           (Unix.write_substring
              output
              (if valid then "ok" else "bad")
              0
              (if valid then 2 else 3));
         Unix.close output;
         Unix._exit 0
       | child ->
         Unix.close output;
         let channel = Unix.in_channel_of_descr input in
         let result = In_channel.input_all channel in
         close_in channel;
         ignore (Unix.waitpid [] child);
         check "cleanup failure reported without reading contents" (result = "ok"))
;;

let test_released_path () =
  let root = temp_dir () in
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       match Unix.fork () with
       | 0 ->
         let file = require (T.create_private_plan ()) in
         let directory = Filename.dirname (T.private_plan_path file) in
         write (Filename.concat root "directory") directory;
         T.discard_private_plan file;
         Unix.mkdir directory 0o700;
         write (Filename.concat directory "foreign-sentinel") "replacement";
         T.discard_private_plan file;
         exit 0
       | child ->
         ignore (Unix.waitpid [] child);
         let directory = read (Filename.concat root "directory") in
         Fun.protect
           ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree directory))
           (fun () ->
              check
                "released path survives repeated cleanup and exit backstop"
                (Sys.file_exists (Filename.concat directory "foreign-sentinel"))))
;;

let test_restrictive_umask () =
  let previous = Unix.umask 0o777 in
  let result =
    Fun.protect ~finally:(fun () -> ignore (Unix.umask previous)) T.create_private_plan
  in
  let file = require result in
  Fun.protect
    ~finally:(fun () -> T.discard_private_plan file)
    (fun () ->
       check
         "directory is usable and private under a restrictive umask"
         ((Unix.stat (Filename.dirname (T.private_plan_path file))).Unix.st_perm = 0o700);
       check
         "plan mode remains 0600 under a restrictive umask"
         ((Unix.stat (T.private_plan_path file)).Unix.st_perm = 0o600))
;;

let () =
  Sol_cli_supervised.dispatch_if_supervisor ();
  Windtrap.run
    "private Terraform plans"
    [ Windtrap.group
        "lifecycle"
        (List.map
           (fun mode -> Windtrap.test mode (fun () -> run_case mode))
           [ "success"; "plan-failure"; "apply-failure"; "interrupt" ])
    ; Windtrap.group
        "diagnostics"
        [ Windtrap.test "cleanup failure" test_cleanup_failure
        ; Windtrap.test "restrictive umask" test_restrictive_umask
        ; Windtrap.test "released path" test_released_path
        ]
    ]
;;
