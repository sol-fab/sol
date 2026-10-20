type execution_mode =
  | Dry_run
  | Apply

type deploy_action =
  | Deploy_dry_run of { emit_to : string option }
  | Deploy_emit_to of string
  | Deploy_apply

type local_deploy_request =
  { scope : string option
  ; mode : execution_mode
  ; image_tag : string
  ; image_tag_warning : string option
  ; confirm_group_change : bool
  ; keep_releases : int
  }

type deploy_request =
  { target : string
  ; action : deploy_action
  ; emit_plan_to : string option
  ; image_tag : string
  ; image_refs : (string option * string) list
  ; registry : string option
  ; confirm_group_change : bool
  ; confirm_ecr_removal : bool
  ; accept_unresolved : bool
  ; loki_push_url : string option
  ; keep_releases : int
  ; await_delegation : int option
  }

let git_sha () =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "git"; "rev-parse"; "--short"; "HEAD" ])
  with
  | Ok { stdout = sha; _ } ->
    Option.to_result
      ~none:"git rev-parse printed no commit"
      (Sol_cli_string.non_blank sha)
  | Error (Sol_cli_process.Non_zero r) ->
    Error
      (match String.trim r.stderr with
       | "" -> Printf.sprintf "git rev-parse exited %d" r.exit_code
       | reason -> reason)
  | Error e -> Error (Sol_cli_process.error_to_string e)
;;

let local_fallback_tag = "dev"

let make_local_deploy_request
      ~scope
      ~dry_run
      ~tag
      ~confirm_group_change
      ~keep_releases
      ~git_sha
  =
  if keep_releases < 1
  then
    Error
      "keep-releases must be at least 1 (the current and previous release are always \
       kept)"
  else (
    let image_tag, image_tag_warning =
      match tag with
      | Some t -> t, None
      | None ->
        (match git_sha () with
         | Ok sha -> sha, None
         | Error reason ->
           ( local_fallback_tag
           , Some
               (Printf.sprintf
                  "could not resolve the git commit for the image tag (%s); tagging \
                   images %S. Pass --image-tag to choose a tag."
                  reason
                  local_fallback_tag) ))
    in
    let mode = if dry_run then Dry_run else Apply in
    Ok { scope; mode; image_tag; image_tag_warning; confirm_group_change; keep_releases })
;;

let invalid_image_ref refs =
  List.find_opt (fun (_, ref) -> not (Sol_cli_image_ref.is_digest ref)) refs
;;

let make_deploy_request
      ~target
      ~dry_run
      ~emit_to
      ~emit_plan_to
      ~image_tag
      ~image_refs
      ~registry
      ~confirm_group_change
      ~confirm_ecr_removal
      ~loki_push_url
      ~keep_releases
      ~await_delegation
      ~accept_unresolved
      ~git_sha
  =
  match invalid_image_ref image_refs with
  | Some (_, bad) ->
    Error
      (Printf.sprintf
         "--image-ref %S is not an immutable reference; expected <repo>@sha256:<64 \
          hexadecimal digits>"
         bad)
  | None ->
    if String.length (String.trim target) = 0
    then Error "target must not be empty (expected <env>/<provider>/<region>)"
    else if keep_releases < 1
    then
      Error
        "keep-releases must be at least 1 (the current and previous release are always \
         kept)"
    else (
      let image_tag =
        match image_tag with
        | Some t -> Ok t
        | None ->
          Result.map_error
            (fun reason ->
               Printf.sprintf
                 "could not resolve the git commit to tag images with (%s); pass \
                  --image-tag <tag> to deploy"
                 reason)
            (git_sha ())
      in
      match image_tag with
      | Error _ as e -> e
      | Ok image_tag ->
        let action =
          if dry_run
          then Deploy_dry_run { emit_to }
          else (
            match emit_to with
            | Some dir -> Deploy_emit_to dir
            | None -> Deploy_apply)
        in
        Ok
          { target
          ; action
          ; emit_plan_to
          ; image_tag
          ; image_refs
          ; registry
          ; confirm_group_change
          ; confirm_ecr_removal
          ; accept_unresolved
          ; loki_push_url
          ; keep_releases
          ; await_delegation
          })
;;
