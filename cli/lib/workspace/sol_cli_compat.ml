type language =
  | Ocaml
  | Typescript

let all = [ Ocaml; Typescript ]

let to_string = function
  | Ocaml -> "ocaml"
  | Typescript -> "typescript"
;;

let of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "ocaml" -> Ok Ocaml
  | "typescript" -> Ok Typescript
  | other ->
    Error
      (Printf.sprintf
         "unknown language %S (supported: %s)"
         other
         (all |> List.map to_string |> String.concat ", "))
;;

let supported_by_profile (_ : Sol_cli_profile.t) = [ Ocaml; Typescript ]

let is_supported_by_profile profile language =
  List.mem language (supported_by_profile profile)
;;
