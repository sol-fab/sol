type error = [ `Config of string ]

let error_to_string (`Config msg) = "sol-svc peer: config error: " ^ msg

type t =
  { unit_id : string
  ; service_name : string
  }

module For_codegen = struct
  let declared ~unit_id ~service_name = { unit_id; service_name }
end

let env_var source_name =
  source_name
  |> String.map (function
    | 'a' .. 'z' as c -> Char.uppercase_ascii c
    | ('A' .. 'Z' | '0' .. '9') as c -> c
    | _ -> '_')
  |> fun s -> s ^ "_URL"
;;

(* Deployed Sol-to-Sol calls authenticate with the projected ServiceAccount
   token named by <CALLEE>_TOKEN_FILE (DEC-063). The shared key survives only as
   a deliberate, development-only affordance; a missing projection is an
   authentication failure, never a reason to downgrade. *)
let plaintext_auth_opt_in = "SOL_ALLOW_PLAINTEXT_PEER_AUTH"

let token_file_env_var source_name =
  let url = env_var source_name in
  let suffix = "_URL" in
  let n = String.length url - String.length suffix in
  String.sub url 0 n ^ "_TOKEN_FILE"
;;

let url peer =
  let name = env_var peer.service_name in
  match Sol_runtime.setting name with
  | Some value ->
    let uri = Uri.of_string value in
    (match Uri.scheme uri, Uri.host uri with
     | Some ("http" | "https"), Some _ -> Ok uri
     | _ -> Error (`Config (name ^ " must be an absolute http(s) URL")))
  | None -> Error (`Config (name ^ " is not set"))
;;

let header_name_equal a b = String.lowercase_ascii a = String.lowercase_ascii b

let put_header name value headers =
  (name, value) :: List.filter (fun (k, _) -> not (header_name_equal k name)) headers
;;

let load_trimmed_file ~env path =
  try Ok (String.trim (Eio.Path.load Eio.Path.(env#fs / path))) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let api_key ~env =
  match Sol_runtime.secret_file ~name:"SOL_API_KEY" with
  | Some path ->
    (match load_trimmed_file ~env path with
     | Ok "" -> Error (`Config ("API key file is empty: " ^ path))
     | Ok key -> Ok key
     | Error msg -> Error (`Config ("could not read API key file " ^ path ^ ": " ^ msg)))
  | None ->
    (match Sol_runtime.setting "SOL_API_KEY" with
     | Some key -> Ok key
     | None -> Error (`Config "SOL_API_KEY is not set"))
;;

(* [Some token] when the declaration projected one for this peer, [None] when no
   projection was declared, and an error when a declared projection cannot be
   read: an unreadable token is a failure, not an absence. *)
let projected_token ~env peer =
  let name = token_file_env_var peer.service_name in
  match Sol_runtime.setting name with
  | None -> Ok None
  | Some path ->
    (match load_trimmed_file ~env path with
     | Ok "" -> Error (`Config ("projected identity token file is empty: " ^ path))
     | Ok token -> Ok (Some token)
     | Error msg -> Error (`Config ("could not read " ^ name ^ " (" ^ path ^ "): " ^ msg)))
;;

let missing_projection_error peer =
  `Config
    (Printf.sprintf
       "%s is not set, so this unit has no projected identity for %s. A deployed \
        Sol-to-Sol call authenticates with the projected ServiceAccount token; set %s=1 \
        only for local development to use SOL_API_KEY instead."
       (token_file_env_var peer.service_name)
       peer.unit_id
       plaintext_auth_opt_in)
;;

let headers ~env ~peer ?trace_ctx ?(headers = []) () =
  let authenticated =
    match projected_token ~env peer with
    | Error _ as err -> err
    | Ok (Some token) -> Ok [ "authorization", "Bearer " ^ token ]
    | Ok None ->
      if Sol_runtime.setting plaintext_auth_opt_in = Some "1"
      then (
        match api_key ~env with
        | Error _ as err -> err
        | Ok key -> Ok [ "x-api-key", key ])
      else Error (missing_projection_error peer)
  in
  match authenticated with
  | Error _ as err -> err
  | Ok auth ->
    let headers =
      List.fold_left (fun acc (name, value) -> put_header name value acc) headers auth
    in
    (match trace_ctx with
     | None -> Ok headers
     | Some ctx -> Ok (Obs_trace.inject_to_headers ctx headers))
;;
