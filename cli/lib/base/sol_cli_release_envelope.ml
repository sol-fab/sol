type component_kind =
  | Svc
  | Worker
  | Fn
  | Task

type execution =
  | Kubernetes_deployment
  | Kubernetes_cronjob
  | Aws_lambda_alias
  | Gcp_cloud_run_service
  | Gcp_cloud_run_job
  | Queue_task

type t =
  { component_kind : component_kind
  ; component_name : string
  ; image : string
  ; execution : execution
  ; runtime_identity : string option
  ; provider : string
  ; provider_detail : Yojson.Safe.t
  ; rollback_identity : string option
  }

let component_kind_to_string = function
  | Svc -> "svc"
  | Worker -> "worker"
  | Fn -> "fn"
  | Task -> "task"
;;

let component_kind_of_string = function
  | "svc" -> Some Svc
  | "worker" -> Some Worker
  | "fn" -> Some Fn
  | "task" -> Some Task
  | _ -> None
;;

let execution_to_string = function
  | Kubernetes_deployment -> "kubernetes_deployment"
  | Kubernetes_cronjob -> "kubernetes_cronjob"
  | Aws_lambda_alias -> "aws_lambda_alias"
  | Gcp_cloud_run_service -> "gcp_cloud_run_service"
  | Gcp_cloud_run_job -> "gcp_cloud_run_job"
  | Queue_task -> "queue_task"
;;

let execution_of_string = function
  | "kubernetes_deployment" -> Some Kubernetes_deployment
  | "kubernetes_cronjob" -> Some Kubernetes_cronjob
  | "aws_lambda_alias" -> Some Aws_lambda_alias
  | "gcp_cloud_run_service" -> Some Gcp_cloud_run_service
  | "gcp_cloud_run_job" -> Some Gcp_cloud_run_job
  | "queue_task" -> Some Queue_task
  | _ -> None
;;

let to_json (t : t) =
  `Assoc
    [ "schema", `Int 1
    ; ( "component"
      , `Assoc
          [ "kind", `String (component_kind_to_string t.component_kind)
          ; "name", `String t.component_name
          ] )
    ; "artifact", `Assoc [ "image", `String t.image ]
    ; "execution", `String (execution_to_string t.execution)
    ; ( "identity"
      , `Assoc
          [ ( "runtime"
            , match t.runtime_identity with
              | Some value -> `String value
              | None -> `Null )
          ; "provider", `String t.provider
          ] )
    ; "provider_detail", t.provider_detail
    ; ( "rollback"
      , `Assoc
          [ ( "identity"
            , match t.rollback_identity with
              | Some value -> `String value
              | None -> `Null )
          ] )
    ]
;;

let of_json json =
  let string path =
    Sol_cli_json.string (Sol_cli_json.field path json)
    |> Option.to_result ~none:(String.concat "." path ^ " is missing")
  in
  let optional_string path =
    match Sol_cli_json.field path json with
    | `Null -> Ok None
    | `String value -> Ok (Some value)
    | _ -> Error (String.concat "." path ^ " must be a string or null")
  in
  let open Result.Syntax in
  let* schema =
    Sol_cli_json.int (Sol_cli_json.field [ "schema" ] json)
    |> Option.to_result ~none:"schema is missing"
  in
  let* () =
    if schema = 1
    then Ok ()
    else Error (Printf.sprintf "unsupported release schema %d" schema)
  in
  let* kind_string = string [ "component"; "kind" ] in
  let* component_kind =
    component_kind_of_string kind_string
    |> Option.to_result ~none:(Printf.sprintf "unknown component kind %S" kind_string)
  in
  let* component_name = string [ "component"; "name" ] in
  let* image = string [ "artifact"; "image" ] in
  let* execution_string = string [ "execution" ] in
  let* execution =
    execution_of_string execution_string
    |> Option.to_result ~none:(Printf.sprintf "unknown execution %S" execution_string)
  in
  let* runtime_identity = optional_string [ "identity"; "runtime" ] in
  let* provider = string [ "identity"; "provider" ] in
  let* rollback_identity = optional_string [ "rollback"; "identity" ] in
  Ok
    { component_kind
    ; component_name
    ; image
    ; execution
    ; runtime_identity
    ; provider
    ; provider_detail = Sol_cli_json.field [ "provider_detail" ] json
    ; rollback_identity
    }
;;
