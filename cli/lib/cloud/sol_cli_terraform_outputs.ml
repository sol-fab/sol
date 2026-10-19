type value =
  | Text of string
  | Texts of string list
  | Null

let shown (name, output) =
  match output with
  | `Assoc fields ->
    let sensitive =
      match List.assoc_opt "sensitive" fields with
      | Some (`Bool b) -> b
      | _ -> true
    in
    if sensitive
    then None
    else (
      match List.assoc_opt "value" fields with
      | Some (`String v) -> Some (name, Text v)
      | Some (`List items) ->
        (match
           List.filter_map
             (function
               | `String s -> Some s
               | _ -> None)
             items
         with
         | [] -> None
         | strings -> Some (name, Texts strings))
      | Some `Null -> Some (name, Null)
      | _ -> None)
  | _ -> None
;;

let displayable json =
  match Sol_cli_json.decode_sensitive ~what:"Terraform outputs" json with
  | Ok (`Assoc outputs) -> Ok (List.filter_map shown outputs)
  | Ok _ -> Error "terraform output -json is not an object of outputs"
  | Error message -> Error message
;;

let line (name, value) =
  match value with
  | Text v -> Printf.sprintf "  %-28s  %s" name v
  | Texts vs -> Printf.sprintf "  %-28s  [%s]" name (String.concat ", " vs)
  | Null -> Printf.sprintf "  %-28s  (none)" name
;;

let raw json ~name =
  match Sol_cli_json.decode_sensitive ~what:"Terraform outputs" json with
  | Ok (`Assoc outputs) ->
    (match List.assoc_opt name outputs with
     | None -> Ok None
     | Some (`Assoc fields) ->
       (match List.assoc_opt "value" fields with
        | None | Some `Null -> Ok None
        | Some value -> Ok (Some (Yojson.Safe.pretty_to_string value)))
     | Some _ -> Error (Printf.sprintf "terraform output %S is not an output object" name))
  | Ok _ -> Error "terraform output -json is not an object of outputs"
  | Error message -> Error message
;;

let text json ~name =
  match Sol_cli_json.decode_sensitive ~what:"Terraform outputs" json with
  | Ok (`Assoc outputs) ->
    (match List.assoc_opt name outputs with
     | None -> Ok None
     | Some (`Assoc fields) ->
       (match List.assoc_opt "value" fields with
        | None | Some `Null -> Ok None
        | Some (`String value) -> Ok (Some value)
        | Some _ ->
          Error (Printf.sprintf "terraform output %S is not text (value omitted)" name))
     | Some _ -> Error (Printf.sprintf "terraform output %S is not an output object" name))
  | Ok _ -> Error "terraform output -json is not an object of outputs"
  | Error message -> Error message
;;
