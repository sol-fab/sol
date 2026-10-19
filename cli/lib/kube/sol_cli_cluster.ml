type platform_vars_context =
  | Install
  | Destruction

type platform_vars =
  { fixed : string list
  ; optional : (string * string option) list
  }

type window =
  { gate : unit -> (unit, string) result
  ; observe : unit -> (unit, string) result
  ; deescalated : unit -> (unit, string) result
  ; successor : unit -> (unit, string) result
  ; principal : string
  }

type bootstrap_window =
  | Verified of window
  | No_role_declared
  | Closed_by_platform_root

type t =
  { name : string
  ; check_identity : cluster_access_role_arn:string option -> (unit, string) result
  ; platform_vars :
      platform_vars_context
      -> cluster_issuer:string option
      -> region:string
      -> (platform_vars, string) result
  ; with_access :
      'a. (env:(string * string) list -> ('a, string) result) -> ('a, string) result
  ; ready : unit -> bool
  ; bootstrap_window : bootstrap_window
  ; deploy_access : unit -> (Sol_cli_kube_destination.t option, string) result
  }

let provisioner_kube_env path =
  [ "KUBECONFIG", path; "KUBE_CONFIG_PATH", path; "KUBE_CONFIG_PATHS", path ]
;;

let outputs_reader ~provider text =
  let open Result.Syntax in
  let* json =
    Sol_cli_json.decode_sensitive
      ~what:(Printf.sprintf "invalid %s Terraform output JSON" provider)
      text
  in
  let value name = Sol_cli_json.field [ name; "value" ] json in
  let string name =
    match value name with
    | `String s when not (Sol_cli_string.is_blank s) -> Ok s
    | _ ->
      Error
        (Printf.sprintf "%s Terraform output %S is missing or not a string" provider name)
  in
  let optional_string name =
    match value name with
    | `Null -> Ok None
    | `String s -> Ok (Sol_cli_string.non_blank s)
    | _ ->
      Error
        (Printf.sprintf "%s Terraform output %S is not a string or null" provider name)
  in
  Ok (value, string, optional_string)
;;

let process_ok ?(env = []) argv =
  Result.is_ok (Sol_cli_process.run (Sol_cli_process.cmd ~env argv))
;;

let process_output ?(env = []) argv =
  match Sol_cli_process.run (Sol_cli_process.cmd ~env argv) with
  | Ok result -> Some result.stdout
  | _ -> None
;;

(* A probe that keeps the tool's own failure instead of collapsing it to
   [None]. Readiness uses this so a refused, timed-out or unlaunchable probe is
   an unobservable check with its evidence, never a confirmed unmet one. *)
let process_output_result ?(env = []) argv : (string, string) result =
  match Sol_cli_process.run (Sol_cli_process.cmd ~env argv) with
  | Ok result -> Ok result.stdout
  | Error error -> Error (Sol_cli_process.error_to_string error)
;;
