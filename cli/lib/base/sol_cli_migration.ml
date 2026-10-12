type prerequisite =
  { version : int
  ; name : string
  }

let default_dir = "db/migrations"
let postgres_identifier_max_bytes = 63
let table_prefix = "sol_"
let table_suffix = "_schema_migrations"
let distinct_suffix_hex_length = 12

let sanitize_workspace workspace =
  let buf = Buffer.create (String.length workspace) in
  workspace
  |> String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
    then Buffer.add_char buf c
    else if c >= 'A' && c <= 'Z'
    then Buffer.add_char buf (Char.lowercase_ascii c)
    else Buffer.add_char buf '_');
  Buffer.contents buf
;;

let table_name ~workspace =
  let sanitized = sanitize_workspace workspace in
  let readable = table_prefix ^ sanitized ^ table_suffix in
  if String.length readable <= postgres_identifier_max_bytes
  then readable
  else (
    let distinct =
      String.sub (Digest.to_hex (Digest.string workspace)) 0 distinct_suffix_hex_length
    in
    let room =
      postgres_identifier_max_bytes
      - String.length table_prefix
      - String.length table_suffix
      - distinct_suffix_hex_length
      - 1
    in
    Printf.sprintf
      "%s%s_%s%s"
      table_prefix
      (String.sub sanitized 0 (min room (String.length sanitized)))
      distinct
      table_suffix)
;;

let table_length_error ~table =
  let length = String.length table in
  if length <= postgres_identifier_max_bytes
  then None
  else
    Some
      (Printf.sprintf
         "%s is %d bytes; PostgreSQL truncates identifiers to %d bytes, which can leave \
          two workspaces sharing one migration table"
         table
         length
         postgres_identifier_max_bytes)
;;

let parse_version = Migration.parse_filename

type directory_contents =
  | Absent
  | Entries of string list
  | Uninspectable of string

let inspect_directory dir =
  match Unix.stat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Absent
  | exception Unix.Unix_error (error, _, _) ->
    Uninspectable (Printf.sprintf "cannot inspect %s: %s" dir (Unix.error_message error))
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    (match Sys.readdir dir with
     | entries -> Entries (Array.to_list entries)
     | exception Sys_error message ->
       Uninspectable (Printf.sprintf "cannot read %s: %s" dir message))
  | _ -> Uninspectable (Printf.sprintf "%s exists but is not a directory" dir)
;;

let required ~dir =
  match inspect_directory dir with
  | Absent ->
    Error
      (Printf.sprintf
         "cannot read migrations dir: %s: %s"
         dir
         (Unix.error_message Unix.ENOENT))
  | Uninspectable message -> Error message
  | Entries _ ->
    Eio_main.run (fun env ->
      Migration.migrations ~fs:env#fs ~dir
      |> Result.map_error Pg_error.to_string
      |> Result.map (List.map (fun (version, name, _) -> { version; name })))
;;

let required_if_present ~dir =
  match inspect_directory dir with
  | Absent -> Ok []
  | Uninspectable _ | Entries _ -> required ~dir
;;

let to_string (p : prerequisite) = Printf.sprintf "%03d_%s" p.version p.name

(** [pending_files ~applied files] keeps the [(filename, content)] entries whose migration
    version is absent from [applied]. [files] is a directory listing as
    {!Sol_cli_migration_gate.migration_files} returns it. The version comes from
    {!parse_version}, the same filename authority [Migration] uses, so a project's digit
    convention is respected rather than reconstructed. *)
let pending_files ~applied files =
  List.filter
    (fun (fname, _) ->
       match parse_version fname with
       | Some (version, _) -> not (List.mem version applied)
       | None -> false)
    files
;;

type status_row =
  { version : int
  ; name : string
  ; applied : bool
  ; applied_at : string option
  ; recorded_checksum : string option
  ; content_checksum : string option
  }

type drift =
  { version : int
  ; name : string
  ; recorded_checksum : string
  ; content_checksum : string
  }

type applied_status =
  { applied : int list
  ; drifted : drift list
  }

let drift_of_row (row : status_row) : drift option =
  match row.applied, row.recorded_checksum, row.content_checksum with
  | true, Some recorded, Some content when not (String.equal recorded content) ->
    Some
      { version = row.version
      ; name = row.name
      ; recorded_checksum = recorded
      ; content_checksum = content
      }
  | _ -> None
;;

let parse_status_json text =
  let open Result.Syntax in
  let what = "migration status" in
  let parse_row item =
    let* version = Sol_cli_json.require ~what [ "version" ] Sol_cli_json.int item in
    let* name = Sol_cli_json.require ~what [ "name" ] Sol_cli_json.string item in
    let* applied = Sol_cli_json.require ~what [ "applied" ] Sol_cli_json.bool item in
    let optional_string key =
      match Sol_cli_json.field [ key ] item with
      | `String s -> Some s
      | _ -> None
    in
    Ok
      { version
      ; name
      ; applied
      ; applied_at = optional_string "applied_at"
      ; recorded_checksum = optional_string "recorded_checksum"
      ; content_checksum = optional_string "content_checksum"
      }
  in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error msg -> Error (Printf.sprintf "invalid JSON: %s" msg)
  | json ->
    (match Sol_cli_json.field [ "migrations" ] json with
     | `List items ->
       let* rows = Sol_cli_result.map_list parse_row items in
       Ok
         { applied =
             List.filter_map
               (fun (row : status_row) -> if row.applied then Some row.version else None)
               rows
         ; drifted = List.filter_map drift_of_row rows
         }
     | _ -> Error "missing \"migrations\" array")
;;

let unsatisfied ~(required : prerequisite list) ~applied =
  List.filter (fun (p : prerequisite) -> not (List.mem p.version applied)) required
;;

let drift_message (d : drift) =
  Printf.sprintf
    "migration %03d_%s was applied with checksum %s, but the migration file now reads as \
     %s"
    d.version
    d.name
    d.recorded_checksum
    d.content_checksum
;;

let status_json ~table rows =
  `Assoc
    [ "table", `String table
    ; ( "migrations"
      , `List
          (rows
           |> List.map (fun (row : status_row) ->
             `Assoc
               [ "version", `Int row.version
               ; "name", `String row.name
               ; "applied", `Bool row.applied
               ; ( "applied_at"
                 , match row.applied_at with
                   | Some s -> `String s
                   | None -> `Null )
               ; ( "recorded_checksum"
                 , match row.recorded_checksum with
                   | Some s -> `String s
                   | None -> `Null )
               ; ( "content_checksum"
                 , match row.content_checksum with
                   | Some s -> `String s
                   | None -> `Null )
               ])) )
    ]
  |> Yojson.Safe.to_string
;;

let evidence_report ~waiting ~logs =
  let waiting_line (reason, detail) =
    Printf.sprintf
      "container waiting: %s%s"
      reason
      (Option.fold detail ~none:"" ~some:(fun d -> " -- " ^ d))
  in
  match Option.map waiting_line waiting, Option.map (fun l -> "job logs:\n" ^ l) logs with
  | None, None -> None
  | waiting, logs ->
    Some (String.concat "\n\n" (Option.to_list waiting @ Option.to_list logs))
;;
