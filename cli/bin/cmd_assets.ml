open Cmdliner
open Result.Syntax
module A = Sol_cli_platform_assets

let form_to_string assets =
  match A.form assets with
  | A.Checkout -> "source checkout"
  | A.Installed { version } -> "installed release " ^ version
;;

type check =
  { label : string
  ; outcome : (string, string) result
  }

let check label outcome = { label; outcome }
let as_detail detail = Result.map (fun _ -> detail)

let terraform_root assets provider role =
  let dir = A.cloud_root assets provider role in
  let has_terraform =
    Sys.file_exists dir
    && Sys.is_directory dir
    && Array.exists (fun f -> Filename.check_suffix f ".tf") (Sys.readdir dir)
  in
  check
    "terraform"
    (if has_terraform
     then Ok (A.cloud_root_rel provider role)
     else Error ("no Terraform root at " ^ dir))
;;

let component_names assets =
  let path = A.components_json assets in
  match Yojson.Safe.from_file path with
  | `Assoc fields -> Ok (List.map fst fields)
  | _ -> Error (path ^ " is not a JSON object")
  | exception Yojson.Json_error msg -> Error (path ^ ": " ^ msg)
  | exception Sys_error msg -> Error msg
;;

let component_checks assets =
  match component_names assets with
  | Error reason -> [ check "components" (Error reason) ]
  | Ok names ->
    names
    |> List.map (fun component ->
      let outcome =
        [ "local"; "durable" ]
        |> Sol_cli_result.map_list (fun profile ->
          Sol_cli_platform_component.merged_values_yaml ~assets ~component ~profile)
        |> as_detail component
      in
      check "component" outcome)
;;

let runner_check () =
  check
    "migration runner"
    (let* assets = A.resolve () |> Result.map_error A.error_to_string in
     A.migration_runner_image assets)
;;

(** The database setup image is a release asset like the runner: a target that provisions its
    own database must be able to resolve it from the release, without an ambient variable. *)
let setup_image_check () =
  check
    "database setup image"
    (let* assets = A.resolve () |> Result.map_error A.error_to_string in
     A.setup_image assets)
;;

let template_checks assets =
  let root = A.templates_root assets in
  Sol_cli_scaffold_tree.kinds
  |> List.map (fun kind ->
    let outcome =
      let* rels = Sol_cli_scaffold_tree.plan ~root ~kind in
      match rels with
      | [] -> Error (Printf.sprintf "no templates under %s" (Filename.concat root kind))
      | rels -> Ok (Printf.sprintf "%d files" (List.length rels))
    in
    check (Printf.sprintf "templates %s" kind) outcome)
;;

let checks assets =
  let terraform_checks =
    Sol_cli_provider.all
    |> List.filter Sol_cli_provider_capabilities.owns_root
    |> List.concat_map (fun provider ->
      [ A.Cluster; A.Platform ] |> List.map (terraform_root assets provider))
  in
  let observability_checks =
    [ check
        "dashboards"
        (Sol_cli_dev_observability.dashboard_configmap_yaml
           ~assets
           ~namespace:Sol_cli_manifest.monitoring_namespace
         |> as_detail "")
    ; check "alloy" (Sol_cli_dev_observability.alloy_values_yaml ~assets |> as_detail "")
    ; runner_check ()
    ; setup_image_check ()
    ]
  in
  List.concat
    [ terraform_checks
    ; component_checks assets
    ; template_checks assets
    ; observability_checks
    ]
;;

let print_check { label; outcome } =
  match outcome with
  | Ok "" -> Printf.printf "  ok  %s\n" label
  | Ok detail -> Printf.printf "  ok  %s  %s\n" label detail
  | Error reason -> Printf.printf "  FAIL  %s  %s\n" label reason
;;

type outcome =
  | All_present
  | Missing_assets of
      { failed : int
      ; total : int
      }

type report =
  { assets : A.t
  ; checks : check list
  ; outcome : outcome
  }

let inspect () =
  let* assets = A.resolve () in
  let checks = checks assets in
  let failed =
    checks
    |> List.fold_left
         (fun count (c : check) -> if Result.is_error c.outcome then count + 1 else count)
         0
  in
  let outcome =
    if failed = 0
    then All_present
    else Missing_assets { failed; total = List.length checks }
  in
  Ok { assets; checks; outcome }
;;

let run () =
  let* report =
    inspect () |> Result.map_error (fun e -> Sol_cli_exit.error (A.error_to_string e))
  in
  Printf.printf
    "sol %s\nassets: %s\n  root: %s\n\n%!"
    (Option.value Sol_cli_build_info.release_version ~default:Version.v)
    (form_to_string report.assets)
    (A.dir report.assets);
  report.checks |> List.iter print_check;
  match report.outcome with
  | All_present ->
    Printf.printf "\nall assets present\n";
    Ok ()
  | Missing_assets { failed; total } ->
    Error
      (Sol_cli_exit.error (Printf.sprintf "%d of %d asset checks failed" failed total))
;;

let cmd =
  Cmd.v
    (Cmd.info
       "assets"
       ~doc:
         "Show where this sol's own assets come from (a source checkout, or an installed \
          release's bundle) and check every one its commands read: the cloud Terraform \
          roots, the local platform components' values, the observability dashboards and \
          Alloy config, and the migration runner. Needs no cluster or cloud account.")
    Term.(const (fun () -> Sol_cli_exit.exit_on (run ())) $ const ())
;;
