open Result.Syntax

let terraform_outcome (r : (Sol_cli_process.output, Sol_cli_process.error) result)
  : (unit, string) result
  =
  match r with
  | Ok _ -> Ok ()
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim r.stderr in
    Error
      (Printf.sprintf
         "terraform exited %d%s"
         r.exit_code
         (if detail = "" then "." else ":\n" ^ detail))
  | Error error ->
    Error
      (Printf.sprintf
         "could not run terraform: %s"
         (Sol_cli_process.error_to_string error))
;;

let terraform_stdout (r : (Sol_cli_process.output, Sol_cli_process.error) result)
  : (string, string) result
  =
  match r with
  | Ok r -> Ok r.stdout
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim r.stderr in
    Error
      (Printf.sprintf
         "terraform exited %d%s"
         r.exit_code
         (if detail = "" then "." else ":\n" ^ detail))
  | Error error ->
    Error
      (Printf.sprintf
         "could not run terraform: %s"
         (Sol_cli_process.error_to_string error))
;;

let apply_asserted ~run_log ~phase_name ~policy ~scope ~chdir ~var_files ~vars ()
  : (unit, string) result
  =
  let* private_plan = Sol_cli_terraform.create_private_plan () in
  let plan_file = Sol_cli_terraform.private_plan_path private_plan in
  Fun.protect
    ~finally:(fun () -> Sol_cli_terraform.discard_private_plan private_plan)
    (fun () ->
       match
         Sol_cli_terraform_plan.guarded_apply
           ~policy
           ~plan:(fun () ->
             terraform_stdout
               (Sol_cli_run_log.run_phase run_log ~name:(phase_name ^ "-plan") (fun () ->
                  Sol_cli_terraform.plan_saved
                    ~scope
                    ~chdir
                    ~var_files
                    ~vars
                    ~out:plan_file
                    ()))
             |> Result.map (fun _ -> plan_file))
           ~show_plan:(fun file ->
             Sol_cli_terraform.show_saved_plan
               ~run_log
               ~phase:(phase_name ^ "-show")
               ~chdir
               ~plan_file:file
               ()
             |> Result.map fst)
           ~apply_plan:(fun file ->
             terraform_outcome
               (Sol_cli_run_log.run_phase run_log ~name:phase_name (fun () ->
                  Sol_cli_terraform.apply_saved ~chdir ~plan_file:file ())))
           ()
       with
       | Ok () -> Ok ()
       | Error failure -> Error (Sol_cli_terraform_plan.apply_failure_to_string failure))
;;
