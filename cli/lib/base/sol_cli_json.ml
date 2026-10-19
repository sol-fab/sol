type t = Yojson.Safe.t

let decode ~what text =
  match Yojson.Safe.from_string text with
  | json -> Ok json
  | exception Yojson.Json_error message ->
    Error (Printf.sprintf "%s: not JSON (%s)" what message)
;;

(* Yojson's diagnostic quotes input bytes around a malformed token. State,
   output and plan JSON can contain credentials, including on parse failure. *)
let decode_sensitive ~what text =
  match Yojson.Safe.from_string text with
  | json -> Ok json
  | exception Yojson.Json_error _ ->
    Error
      (Printf.sprintf
         "%s: invalid JSON (input omitted because it may contain credentials)"
         what)
;;

let rec field path (j : t) : t =
  match path, j with
  | [], j -> j
  | key :: rest, `Assoc fields ->
    field rest (Option.value (List.assoc_opt key fields) ~default:`Null)
  | _ :: _, _ -> `Null
;;

let string = function
  | `String s -> Some s
  | _ -> None
;;

let int = function
  | `Int i -> Some i
  | _ -> None
;;

let float = function
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None
;;

let bool = function
  | `Bool b -> Some b
  | _ -> None
;;

let list = function
  | `List items -> Some items
  | _ -> None
;;

let assoc = function
  | `Assoc fields -> Some fields
  | _ -> None
;;

let dotted path = String.concat "." path

let require ~what path convert j =
  match field path j with
  | `Null -> Error (Printf.sprintf "%s: %s is missing" what (dotted path))
  | value ->
    convert value
    |> Option.to_result
         ~none:(Printf.sprintf "%s: %s has an unexpected type" what (dotted path))
;;

let optional ~what path convert j =
  match field path j with
  | `Null -> Ok None
  | value ->
    (match convert value with
     | Some v -> Ok (Some v)
     | None -> Error (Printf.sprintf "%s: %s has an unexpected type" what (dotted path)))
;;

let items ~what text =
  let open Result.Syntax in
  let* json = decode ~what text in
  match field [ "items" ] json with
  | `List items ->
    items
    |> Sol_cli_result.map_list (function
      | `Assoc _ as item -> Ok item
      | _ -> Error (Printf.sprintf "%s: an item is not an object" what))
  | _ -> Error (Printf.sprintf "%s: the response has no items list" what)
;;
