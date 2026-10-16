open Result.Syntax
module J = Sol_cli_json

type t =
  { principal : string
  ; cluster : string
  ; endpoint : string
  ; configuration : string
  }

type error =
  | Command of string * Sol_cli_process.error
  | Invalid of string

let invalid message = Error (Invalid message)

let command ~ctx args =
  Sol_cli_kubectl.run ~timeout_s:10. ~ctx args
  |> Result.map_error (fun e -> Command (List.hd args, e))
;;

let json text =
  let* json =
    J.decode ~what:"Kubernetes identity" text
    |> Result.map_error (fun _ -> Invalid "malformed identity JSON")
  in
  Sol_cli_database_contract_data.canonical json
  |> Result.map_error (fun _ -> Invalid "noncanonical identity JSON")
;;

let text path json =
  J.require ~what:"Kubernetes identity" path J.string json
  |> Result.map_error (fun _ -> Invalid "missing identity field")
;;

let singleton name json =
  match J.field [ name ] json with
  | `List [ value ] -> Ok value
  | _ -> invalid "identity configuration is not a single selected context"
;;

let configuration ~ctx =
  let* output = command ~ctx [ "config"; "view"; "--minify"; "-o"; "json" ] in
  let* document = json output.stdout in
  let* cluster = singleton "clusters" document in
  let* context = singleton "contexts" document in
  let* user = singleton "users" document in
  let* selected = text [ "current-context" ] document in
  let* name = text [ "name" ] context in
  let* cluster_name = text [ "name" ] cluster in
  let* user_name = text [ "name" ] user in
  let* chosen_cluster = text [ "context"; "cluster" ] context in
  let* chosen_user = text [ "context"; "user" ] context in
  let* endpoint = text [ "cluster"; "server" ] cluster in
  if
    selected <> ctx.Sol_cli_kube_destination.destination.context
    || name <> selected
    || cluster_name <> chosen_cluster
    || user_name <> chosen_user
    || (not (String.starts_with ~prefix:"https://" endpoint))
    ||
    match J.field [ "cluster"; "insecure-skip-tls-verify" ] cluster with
    | `Null | `Bool false -> false
    | _ -> true
  then invalid "untrusted selected Kubernetes context or TLS endpoint"
  else
    Ok
      (endpoint, Digestif.SHA256.(to_hex (digest_string (Yojson.Safe.to_string document))))
;;

let principal ~ctx =
  let* output = command ~ctx [ "auth"; "whoami"; "-o"; "json" ] in
  let* document = json output.stdout in
  if
    J.field [ "kind" ] document <> `String "SelfSubjectReview"
    || J.field [ "apiVersion" ] document <> `String "authentication.k8s.io/v1"
  then invalid "unsupported authenticated identity response"
  else
    (* Kubernetes owns this authenticated username. AWS-specific ARN/role
       interpretation remains in Sol_cli_aws_cluster and is a different decision. *)
    let* username = text [ "status"; "userInfo"; "username" ] document in
    if String.trim username = ""
    then invalid "empty authenticated principal"
    else Ok username
;;

let observe ~ctx =
  let* endpoint, configuration = configuration ~ctx in
  let* principal = principal ~ctx in
  let* namespace = command ~ctx [ "get"; "namespace"; "kube-system"; "-o"; "json" ] in
  let* namespace = json namespace.stdout in
  if
    J.field [ "apiVersion" ] namespace <> `String "v1"
    || J.field [ "kind" ] namespace <> `String "Namespace"
    || J.field [ "metadata"; "name" ] namespace <> `String "kube-system"
  then invalid "unestablished Kubernetes cluster identity"
  else
    let* cluster = text [ "metadata"; "uid" ] namespace in
    if String.trim cluster = ""
    then invalid "empty Kubernetes cluster identity"
    else Ok { principal; cluster; endpoint; configuration }
;;

let same (a : t) (b : t) = a = b

(* Ordinary diagnostics are bounded classifications, not raw authentication output.
   A caller may retain [error] in an explicitly controlled operator channel. *)
let diagnostic = function
  | Invalid message -> message
  | Command (stage, Sol_cli_process.Non_zero f) ->
    Printf.sprintf "%s exited %d" stage f.exit_code
  | Command (stage, Timeout _) -> stage ^ " timed out"
  | Command (stage, Spawn_failed _) -> stage ^ " could not start"
;;
