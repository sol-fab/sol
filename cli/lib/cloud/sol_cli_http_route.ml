open Result.Syntax

type t =
  { service : string
  ; path : string
  ; backend : string
  }

let gateway_name ~target_name =
  let workspace = Sol_cli_workspace.current_name () in
  Sol_cli_kubernetes_name.sanitize_name
    (Printf.sprintf "%s-%s-http" workspace target_name)
;;

let validate_routes routes =
  let seen = Hashtbl.create (List.length routes) in
  let rec loop = function
    | [] -> Ok ()
    | (route : t) :: rest ->
      if String.trim route.service = ""
      then Error "an HTTP gateway route has no service"
      else if String.trim route.backend = ""
      then Error (Printf.sprintf "HTTP gateway route %s has no backend" route.path)
      else if String.length route.path = 0 || route.path.[0] <> '/'
      then
        Error
          (Printf.sprintf
             "HTTP gateway route %S for %s must start with \"/\""
             route.path
             route.service)
      else if Hashtbl.mem seen route.path
      then
        Error
          (Printf.sprintf
             "two public HTTP functions declare the same route %S; a shared API needs \
              one owner per path"
             route.path)
      else (
        Hashtbl.add seen route.path ();
        loop rest)
  in
  loop routes
;;

let string_field json name =
  Sol_cli_json.string (Sol_cli_json.field [ name ] json)
  |> Option.to_result ~none:(Printf.sprintf "release record has no %s" name)
;;

let of_record ~(target : Sol_cli_config.target) json =
  let field name = string_field json name in
  let* kind = field "kind" in
  let* () =
    if kind = "fn_http"
    then Ok ()
    else
      Error (Printf.sprintf "release record kind %S is not an HTTP function record" kind)
  in
  let* exposure = field "http_exposure" in
  let* exposure =
    Sol_cli_toml.http_exposure_of_string exposure
    |> Result.map_error (fun message -> "release record: " ^ message)
  in
  match exposure with
  | Sol_cli_toml.Http_internal -> Ok None
  | Sol_cli_toml.Http_public ->
    let* service = field "service" in
    let* path = field "http_path" in
    let* backend =
      match target.provider with
      | Sol_cli_provider.Aws -> field "function_name"
      | Sol_cli_provider.Gcp -> field "url"
      | Sol_cli_provider.Byo ->
        Error "target-scoped serverless dispatch supports AWS and GCP only"
    in
    Ok (Some { service; path; backend })
;;

let of_release ~(target : Sol_cli_config.target) (http : Sol_cli_toml.http_trigger) json =
  match http.exposure with
  | Sol_cli_toml.Http_internal -> Ok None
  | Sol_cli_toml.Http_public ->
    let* service = string_field json "service" in
    let* backend =
      match target.provider with
      | Sol_cli_provider.Aws -> string_field json "function_name"
      | Sol_cli_provider.Gcp -> string_field json "url"
      | Sol_cli_provider.Byo ->
        Error "target-scoped serverless dispatch supports AWS and GCP only"
    in
    Ok (Some { service; path = http.path; backend })
;;
