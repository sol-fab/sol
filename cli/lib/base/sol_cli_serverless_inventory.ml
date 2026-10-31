type entry =
  { service : string
  ; record : string
  }

let path ~target =
  let directory = Filename.concat (Sys.getcwd ()) (Filename.concat ".sol" "serverless") in
  let name = Digestif.SHA256.(to_hex (digest_string target)) in
  Filename.concat directory (name ^ ".json")
;;

let decode path text =
  match Yojson.Safe.from_string text with
  | `List entries ->
    let one = function
      | `Assoc fields ->
        (match List.assoc_opt "service" fields, List.assoc_opt "record" fields with
         | Some (`String service), Some (`String record) -> Ok { service; record }
         | _ ->
           Error (Printf.sprintf "%s: inventory entry is not a service/record pair" path))
      | _ -> Error (Printf.sprintf "%s: inventory entry is not an object" path)
    in
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | entry :: rest ->
        (match one entry with
         | Ok entry -> collect (entry :: acc) rest
         | Error _ as error -> error)
    in
    collect [] entries
  | _ -> Error (Printf.sprintf "%s: inventory is not a JSON list" path)
  | exception Yojson.Json_error message ->
    Error (Printf.sprintf "%s: inventory is invalid JSON: %s" path message)
;;

let load ~target =
  let path = path ~target in
  match Sol_cli_fs.read_file_opt path with
  | None -> Ok []
  | Some text ->
    (match decode path text with
     | Ok entries -> Ok entries
     | Error _ as error -> error)
;;

let write ~target entries =
  let open Result.Syntax in
  let path = path ~target in
  let json =
    `List
      (List.map
         (fun { service; record } ->
            `Assoc [ "service", `String service; "record", `String record ])
         entries)
    |> Yojson.Safe.pretty_to_string
  in
  let* () = Sol_cli_fs.mkdir_p (Filename.dirname path) in
  Sol_cli_fs.write_atomic ~perm:0o600 path (json ^ "\n")
;;

let add ~target ~service ~record =
  let open Result.Syntax in
  let* entries = load ~target in
  let entries =
    { service; record }
    :: List.filter (fun (entry : entry) -> entry.service <> service) entries
  in
  write ~target entries
;;

let remove ~target ~service =
  let open Result.Syntax in
  let* entries = load ~target in
  write ~target (List.filter (fun (entry : entry) -> entry.service <> service) entries)
;;
