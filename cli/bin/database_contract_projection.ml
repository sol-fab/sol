(* Internal product declaration producer. Never produces qualification verdicts. *)
open Result.Syntax
module C = Sol_cli_database_contract

let load path =
  try Ok (Yojson.Safe.from_file path) with
  | Sys_error message | Yojson.Json_error message -> Error message
;;

let run = function
  | [ _; "definition"; revision ] ->
    let* definition = C.definition ~revision in
    Ok (C.definition_json definition)
  | [ _; "specimen"; definition_file; target ] ->
    let* json = load definition_file in
    let* definition = C.read_definition json in
    let* config =
      Sol_cli_config.load_for_target ~target
      |> Result.map_error Sol_cli_config.error_to_string
    in
    let* facts = Sol_cli_workspace_model.load_cwd () in
    let* projection = C.project ~definition ~requested_target:target ~config ~facts in
    Ok (C.projection_json projection)
  | _ ->
    Error "usage: sol-database-contract definition REVISION | specimen DEFINITION TARGET"
;;

let () =
  match run (Array.to_list Sys.argv) with
  | Ok json -> print_endline (Yojson.Safe.to_string json)
  | Error message ->
    prerr_endline ("database contract: " ^ message);
    exit 2
;;
