let abbreviate ?(limit = 400) text =
  let text = String.trim text in
  if String.length text <= limit then text else String.sub text 0 limit ^ "..."
;;

let state_name pre_destroy kind =
  Sol_cli_cloud_destroy.resources pre_destroy
  |> List.find_map (fun (resource : Sol_cli_cloud_destroy.resource) ->
    if String.equal resource.kind kind then resource.name else None)
;;

let residue_cluster_name ~kind ~pre_destroy ~cluster ~(target_cfg : Sol_cli_config.target)
  =
  match state_name pre_destroy kind with
  | Some _ as name -> name
  | None ->
    (match Option.map (fun (cluster : Sol_cli_cluster.t) -> cluster.name) cluster with
     | Some _ as name -> name
     | None -> target_cfg.cluster_name)
;;

let run_provider_query argv : Sol_cli_destroy_verification.lookup_result =
  match Sol_cli_process.run (Sol_cli_process.cmd argv) with
  | Ok { stdout; stderr } ->
    Sol_cli_destroy_verification.Answered { status = 0; stdout; stderr }
  | Error (Sol_cli_process.Non_zero { exit_code; stdout; stderr }) ->
    Answered { status = exit_code; stdout; stderr }
  | Error error -> Unavailable (Sol_cli_process.error_to_string error)
;;

let read_cloud_state infra_dir : (Sol_cli_cloud_destroy.state_read, string) result =
  match Sol_cli_terraform.show_json ~chdir:infra_dir () with
  | Ok result -> Ok (Sol_cli_cloud_destroy.inventory_of_show_json result.stdout)
  | Error (Sol_cli_process.Non_zero result) ->
    Error
      (Printf.sprintf
         "terraform show failed with exit %d%s"
         result.exit_code
         (let detail = String.trim result.stderr in
          if detail = "" then "" else ": " ^ detail))
  | Error error ->
    Error ("could not read terraform state: " ^ Sol_cli_process.error_to_string error)
;;

type context =
  { run_log : Sol_cli_run_log.t
  ; infra_dir : string
  ; var_files : string list
  ; vars : string list
  ; target : Sol_cli_config.target
  ; resolved_var : string -> string option
  }

type t =
  { prepare :
      retention:Sol_cli_cloud_lifecycle.destroy_retention
      -> cluster_name:string
      -> state:Sol_cli_cloud_destroy.state_read
      -> Sol_cli_cloud_destroy.preparation Sol_cli_cloud_lifecycle.preparation_outcome
  ; retention :
      retention:Sol_cli_cloud_lifecycle.destroy_retention
      -> pre_destroy:Sol_cli_cloud_destroy.state_read
      -> preparation:Sol_cli_cloud_destroy.preparation
      -> Sol_cli_destroy_verification.retention
  ; residue :
      ?previously_attributed:(string * string list) list
      -> ?authorization_identities:(string * string list) list
      -> pre_destroy:Sol_cli_cloud_destroy.state_read
      -> cluster:Sol_cli_cluster.t option
      -> unit
      -> Sol_cli_absence.observation list
  ; before_substrate_destroy : unit -> unit
  }
