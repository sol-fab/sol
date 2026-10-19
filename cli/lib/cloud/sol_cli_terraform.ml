(* Saved plans contain sensitive state. Keep them outside workspaces, run logs,
   caches and caller-supplied TMPDIR locations. Abandoned files remain private after an uncatchable
   termination; host temporary-file retention or operator cleanup must remove them. *)
type private_plan_file =
  { path : string
  ; directory : string
  ; mutable released : bool
  }

let discard_private_plan file =
  if not file.released
  then (
    match Sol_cli_fs.remove_tree file.directory with
    | Ok () -> file.released <- true
    | Error message ->
      Sol_cli_report.warn "warning: private Terraform plan cleanup failed: %s" message)
;;

let private_plan_path file = file.path

let create_private_plan () =
  try
    let marker = Filename.temp_file ~temp_dir:"/tmp" "sol-terraform-plan-" ".private" in
    let directory = marker ^ ".d" in
    let cleanup_marker () = Sol_cli_fs.remove_reporting marker in
    Fun.protect ~finally:cleanup_marker (fun () ->
      (* mkdir never follows an existing path. Failure does not authorize deleting
         somebody else's directory. No sensitive data has been written yet. *)
      Unix.mkdir directory 0o700;
      let file =
        { directory
        ; path = Filename.concat directory "execution.tfplan"
        ; released = false
        }
      in
      try
        Unix.chmod directory 0o700;
        let fd =
          Unix.openfile file.path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
        in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fchmod fd 0o600);
        at_exit (fun () -> discard_private_plan file);
        Ok file
      with
      | Unix.Unix_error (error, _, _) ->
        discard_private_plan file;
        Error ("cannot allocate private Terraform plan: " ^ Unix.error_message error)
      | Sys_error message ->
        discard_private_plan file;
        Error ("cannot allocate private Terraform plan: " ^ message))
  with
  | Unix.Unix_error (error, _, _) ->
    Error ("cannot allocate private Terraform plan: " ^ Unix.error_message error)
  | Sys_error message -> Error ("cannot allocate private Terraform plan: " ^ message)
;;

let run = Sol_cli_process.run
let cmd = Sol_cli_process.cmd

let operation_key ~chdir ~backend_config =
  let digest =
    Digest.to_hex
      (Digest.string
         (String.concat "\x00" (chdir :: List.sort String.compare backend_config)))
  in
  Printf.sprintf
    "%s-%s-%s"
    (Filename.basename (Filename.dirname chdir))
    (Filename.basename chdir)
    (String.sub digest 0 16)
;;

let configured : (string, string) Hashtbl.t = Hashtbl.create 4

let key_for chdir =
  match Hashtbl.find_opt configured chdir with
  | Some key -> key
  | None -> operation_key ~chdir ~backend_config:[]
;;

let previous_operation ~chdir ~backend_config =
  Sol_cli_supervised.latest ~key:(operation_key ~chdir ~backend_config)
;;

let acknowledge_previous_operation ~chdir ~backend_config =
  Sol_cli_supervised.acknowledge ~key:(operation_key ~chdir ~backend_config)
;;

let supervised ~chdir c =
  let result = Sol_cli_supervised.run ~echo:true ~key:(key_for chdir) ~root:chdir c in
  (match result with
   | Error (Sol_cli_process.Non_zero _) ->
     let errored = Filename.concat chdir "errored.tfstate" in
     if Sys.file_exists errored
     then
       Sol_cli_report.err
         "\n\
          error: Terraform could not persist state to its backend and wrote it to %s.\n\
         \  That file is now the only record of what this run changed. Inspect it and \
          push it deliberately (terraform state push); Sol never pushes it for you, and \
          the next constructive command is refused until it is resolved."
         errored
   | _ -> ());
  result
;;

let which_check () = Result.is_ok (Sol_cli_process.run (cmd [ "which"; "terraform" ]))

type scope =
  | Whole_root
  | Targets of string * string list

let whole_root = Whole_root

let targets first rest =
  if Sol_cli_string.is_blank first then invalid_arg "Terraform target must not be empty";
  Targets (first, rest)
;;

let scope_args = function
  | Whole_root -> []
  | Targets (first, rest) -> List.map (fun target -> "-target=" ^ target) (first :: rest)
;;

let init ?(echo = true) ?(env = []) ~chdir ~backend_config () =
  Hashtbl.replace configured chdir (operation_key ~chdir ~backend_config);
  run
    ~echo
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "init"; "-reconfigure" ]
        @ List.map (fun value -> "-backend-config=" ^ value) backend_config))
;;

let kv_args pairs = List.map (fun (k, v) -> k ^ "=" ^ v) pairs

let var_args ~var_files ~vars =
  let varfile_args = List.map (fun f -> "-var-file=" ^ f) var_files in
  let var_args = List.map (fun v -> "-var=" ^ v) vars in
  varfile_args @ var_args
;;

let plan ?(env = []) ~scope ~chdir ~var_files ~vars () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan" ]
        @ scope_args scope
        @ var_args ~var_files ~vars))
;;

let plan_refresh_only ?(env = []) ~chdir ~var_files ~vars () =
  run
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan"; "-refresh-only"; "-detailed-exitcode" ]
        @ var_args ~var_files ~vars))
;;

let plan_saved ?(env = []) ~scope ~chdir ~var_files ~vars ~out () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan" ]
        @ scope_args scope
        @ var_args ~var_files ~vars
        @ [ "-out=" ^ out ]))
;;

let plan_destroy ?(env = []) ~chdir ~var_files ~vars () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "plan"; "-destroy" ] @ var_args ~var_files ~vars))
;;

let apply ?(env = []) ~scope ~chdir ~var_files ~vars () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "apply"; "-auto-approve" ]
        @ scope_args scope
        @ var_args ~var_files ~vars))
;;

let destroy ?(env = []) ~chdir ~var_files ~vars () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "destroy"; "-auto-approve" ]
        @ var_args ~var_files ~vars))
;;

let import_ ?(env = []) ~chdir ~var_files ~vars ~address ~import_identity () =
  supervised
    ~chdir
    (cmd
       ~env
       ([ "terraform"; "-chdir=" ^ chdir; "import"; "-input=false"; "-no-color" ]
        @ var_args ~var_files ~vars
        @ [ address; import_identity ]))
;;

let state_rm ?(env = []) ~chdir ~address () =
  supervised ~chdir (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "state"; "rm"; address ])
;;

let output_json ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "output"; "-json" ])
;;

let state_list ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "state"; "list" ])
;;

let state_pull ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "state"; "pull" ])
;;

let addresses_of_stdout stdout =
  stdout
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun address -> address <> "")
;;

let state_addresses ?(env = []) ~chdir () =
  match state_list ~env ~chdir () with
  | Ok result -> Ok (addresses_of_stdout result.stdout)
  | Error _ as error ->
    (match state_pull ~env ~chdir () with
     | Ok _ -> Ok []
     | Error _ -> error)
;;

let show_json ?(env = []) ~chdir () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "show"; "-json" ])
;;

let show_json_plan ?(env = []) ~chdir ~plan_file () =
  run (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "show"; "-json"; plan_file ])
;;

let saved_plan_json ?env ~chdir ~plan_file () =
  match show_json_plan ?env ~chdir ~plan_file () with
  | Ok r -> Ok r.stdout
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim r.stderr in
    Error
      (Printf.sprintf
         "terraform show exited %d%s"
         r.exit_code
         (if detail = "" then "." else ":\n" ^ detail))
  | Error e -> Error ("could not run terraform show: " ^ Sol_cli_process.error_to_string e)
;;

let show_saved_plan ?env ~run_log ~phase ~chdir ~plan_file () =
  Sol_cli_terraform_plan.show_and_record ~run_log ~phase ~show:(fun () ->
    saved_plan_json ?env ~chdir ~plan_file ())
;;

let apply_saved ?(env = []) ~chdir ~plan_file () =
  supervised ~chdir (cmd ~env [ "terraform"; "-chdir=" ^ chdir; "apply"; plan_file ])
;;
