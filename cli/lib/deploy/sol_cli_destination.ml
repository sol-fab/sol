(** The one message for a command that needs a target but was given none. Shared with the
    command's own error so the two layers cannot disagree about what is wrong. *)
let missing_target_message ~command =
  Printf.sprintf
    "`sol %s` needs --target <env>/<provider>/<region> to know which cluster to reach; \
     for Sol's own local cluster use `sol local %s`"
    command
    command
;;

(** [resolve_with_config] is [resolve] for a remote command that also needs the loaded
    target config, so the target is resolved and the config read once. *)
let resolve_with_config ~command ~target =
  let open Result.Syntax in
  match target with
  | Some path ->
    let* cfg =
      Sol_cli_config.load_for_target ~target:path
      |> Result.map_error Sol_cli_config.error_to_string
    in
    let* ctx =
      Sol_cli_config.destination_of_target cfg.target
      |> Result.map Sol_cli_kube_destination.context_of_destination
    in
    Ok (ctx, cfg)
  | None -> Error (missing_target_message ~command)
;;

let resolve ~command ~local ~target =
  if local
  then Ok Sol_cli_kube_destination.local_context
  else resolve_with_config ~command ~target |> Result.map fst
;;
