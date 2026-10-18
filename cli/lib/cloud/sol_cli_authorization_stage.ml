type outcome =
  | Established
  | Not_declared

let outcome_to_string = function
  | Established -> "the authorization reconciler identity and its fence are established"
  | Not_declared ->
    "the target declares no authorization reconciler trust principal, so no reconciler \
     identity or fence is created"
;;

let capabilities (target : Sol_cli_config.target) =
  Sol_cli_provider_capabilities.capabilities_of target.provider
;;

let declared_trust = Sol_cli_provider_capabilities.authorization_trust
let root_vars target = (capabilities target).authorization_root_vars target

let prepare ~assets (target : Sol_cli_config.target) =
  let open Result.Syntax in
  let provider = target.provider in
  let* backend = Sol_cli_cloud_lifecycle.authorization_backend target in
  let* vars = root_vars target in
  let dir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:backend
  in
  let* _ =
    Sol_cli_terraform_workdir.materialize
      ~assets
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:backend
  in
  let* () =
    Sol_cli_terraform.init ~chdir:dir ~backend_config:backend ()
    |> Result.map ignore
    |> Result.map_error Sol_cli_process.error_to_string
  in
  Ok (dir, Sol_cli_terraform.kv_args vars)
;;

let fence ~assets ~run_log ~target =
  match declared_trust target with
  | None -> Ok Not_declared
  | Some _ ->
    let open Result.Syntax in
    let* dir, vars = prepare ~assets target in
    let addresses = (capabilities target).authorization_fence_addresses in
    let* () =
      Sol_cli_run_log.run_phase run_log ~name:"authorization-fence-apply" (fun () ->
        match addresses with
        | first :: rest ->
          Sol_cli_terraform.apply
            ~scope:(Sol_cli_terraform.targets first rest)
            ~chdir:dir
            ~var_files:[]
            ~vars
            ()
        | [] -> Sol_cli_process.completed ~exit_code:0 ~stdout:"" ~stderr:"")
      |> Result.map ignore
      |> Result.map_error Sol_cli_process.error_to_string
    in
    Ok Established
;;

let verify_destroyed_state json =
  match Sol_cli_cloud_destroy.inventory_of_show_json json with
  | Sol_cli_cloud_destroy.State_empty -> Ok ()
  | State_represented resources ->
    Error
      (Printf.sprintf
         "the authorization root's state still represents %d resource(s) after \
          `terraform destroy`: %s. Terraform's exit status is not evidence that the \
          authorization identities are gone."
         (List.length resources)
         (String.concat
            ", "
            (List.map (fun (r : Sol_cli_cloud_destroy.resource) -> r.address) resources)))
  | State_unreadable reason ->
    Error
      (Printf.sprintf
         "the authorization root's state could not be read after `terraform destroy` \
          (%s), so its absence is not established"
         reason)
;;

let destroy ~assets ~run_log ~target =
  match declared_trust target with
  | None -> Ok Not_declared
  | Some _ ->
    let open Result.Syntax in
    let* dir, vars = prepare ~assets target in
    let* () =
      Sol_cli_run_log.run_phase run_log ~name:"authorization-destroy" (fun () ->
        Sol_cli_terraform.destroy ~chdir:dir ~var_files:[] ~vars ())
      |> Result.map ignore
      |> Result.map_error Sol_cli_process.error_to_string
    in
    let* () =
      match Sol_cli_terraform.show_json ~chdir:dir () with
      | Ok output -> verify_destroyed_state output.stdout
      | Error (Sol_cli_process.Non_zero result) ->
        Error
          (Printf.sprintf
             "`terraform show -json` failed after destroying the authorization root \
              (exit %d): %s"
             result.exit_code
             (String.trim result.stderr))
      | Error error ->
        Error
          (Printf.sprintf
             "`terraform show -json` could not run after destroying the authorization \
              root: %s"
             (Sol_cli_process.error_to_string error))
    in
    Ok Established
;;
