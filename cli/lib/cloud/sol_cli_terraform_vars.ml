let add_opt k = function
  | None -> Fun.id
  | Some v -> fun xs -> (k, v) :: xs
;;

let ecr_repositories_var () =
  match Sol_cli_workspace_model.load_cwd () with
  | Error e -> Error ("cannot determine the workspace's ECR repositories: " ^ e)
  | Ok facts ->
    Ok
      (Sol_cli_workspace_model.services facts
       |> List.filter_map (fun s ->
         match Sol_cli_kubernetes_name.k8s_name_of_source s.Sol_cli_manifest.name with
         | Ok name -> Some (Sol_cli_kubernetes_name.k8s_name_to_string name)
         | Error _ -> None)
       |> List.map (Printf.sprintf "%S")
       |> String.concat ","
       |> Printf.sprintf "[%s]")
;;

let of_config ~workspace cfg =
  let (target : Sol_cli_config.target) = cfg.Sol_cli_config.target in
  let capabilities = Sol_cli_provider_capabilities.capabilities_of target.provider in
  let shared =
    []
    |> add_opt "region" (Some target.region)
    |> add_opt "cluster_name" target.cluster_name
    |> add_opt "base_domain" target.base_domain
    |> add_opt "alert_receiver_type" target.alert_receiver_type
    |> add_opt "alert_receiver_url" target.alert_receiver_url
    |> add_opt "alert_owner" target.alert_owner
    |> add_opt "alert_runbook_url" target.alert_runbook_url
  in
  let provider_own = capabilities.own_vars target ~workspace shared in
  let vars =
    List.assoc_opt (Sol_cli_provider.to_string target.provider) target.provider_fields
    |> Option.value ~default:[]
    |> List.filter (fun (key, _) ->
      not (List.mem key (Sol_cli_provider.sol_keys target.provider)))
    |> List.rev_append provider_own
  in
  (* Provisioning follows the resolved ownership, not the bare presence of a postgres
     resource: an externally bound database must not also be provisioned, and every
     provider derives the decision from the same resolution. *)
  match Sol_cli_resource_binding.resolve_postgres cfg with
  | Error message -> Error message
  | Ok database ->
    let has_postgres = Sol_cli_resource_binding.postgres_is_managed database in
    let production = target.profile = Some Sol_cli_profile.Production_single_region in
    let production_postgres = has_postgres && production in
    let vars = capabilities.profile_vars ~production ~production_postgres @ vars in
    Result.map
      (fun declared -> declared @ vars)
      (capabilities.root_declared_vars
         ~has_postgres
         ~production_postgres
         ~ecr_repositories:ecr_repositories_var)
;;

let var_file ~cwd ~workspace_root ~flag ~target =
  let absolute base path =
    if Filename.is_relative path then Filename.concat base path else path
  in
  match flag, target with
  | Some path, _ -> Some (absolute cwd path)
  | None, Some path -> Some (absolute workspace_root path)
  | None, None -> None
;;

let of_target ~strict ~workspace target_path =
  let open Result.Syntax in
  let* cfg =
    Sol_cli_config.load_for_target ~target:target_path
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let* () =
    if strict && not (Sol_cli_config.target_declared cfg.target)
    then
      Error
        (Printf.sprintf
           "target %S is not declared in %s -- terraform apply/destroy require an \
            explicit target, even an empty one, so a typo'd or unintended target can't \
            silently inherit sol.yml's shared defaults and mutate infrastructure anyway."
           target_path
           (Sol_cli_config.target_source cfg.target))
    else Ok ()
  in
  let* vars = of_config ~workspace cfg in
  Ok (vars, cfg)
;;

let trim_quotes s =
  let s = String.trim s in
  let len = String.length s in
  if len >= 2 && s.[0] = '"' && s.[len - 1] = '"' then String.sub s 1 (len - 2) else s
;;

let assignment key line =
  match String.index_opt line '=' with
  | Some i when String.equal (String.trim (String.sub line 0 i)) key ->
    Some (trim_quotes (String.sub line (i + 1) (String.length line - i - 1)))
  | _ -> None
;;

let var_file_value key path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception Sys_error _ -> None
  | text ->
    String.split_on_char '\n' text
    |> List.find_map (fun line ->
      let line = String.trim line in
      if line = "" || line.[0] = '#' then None else assignment key line)
;;

let resolved key ~var_files ~vars =
  match List.rev vars |> List.find_map (assignment key) with
  | Some _ as value -> value
  | None -> List.find_map (var_file_value key) var_files
;;
