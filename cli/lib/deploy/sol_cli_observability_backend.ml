open Result.Syntax

type backend =
  | Local
  | Self_hosted_durable
  | External

let backend_of_string = function
  | "local" -> Some Local
  | "self_hosted_durable" -> Some Self_hosted_durable
  | "external" -> Some External
  | _ -> None
;;

let backend_to_string = function
  | Local -> "local"
  | Self_hosted_durable -> "self_hosted_durable"
  | External -> "external"
;;

let valid_url value =
  let value = String.trim value in
  String.starts_with ~prefix:"https://" value
  || String.starts_with ~prefix:"http://" value
;;

let validate_external ~logs_url ~metrics_url ~traces_url =
  let required name = function
    | Some value when valid_url value -> Ok ()
    | Some value when String.trim value = "" ->
      Error (Printf.sprintf "%s is required when observability_backend = external" name)
    | Some _ -> Error (Printf.sprintf "%s must be an http(s) URL" name)
    | None ->
      Error (Printf.sprintf "%s is required when observability_backend = external" name)
  in
  let* () = required "observability_logs_url" logs_url in
  let* () = required "observability_metrics_url" metrics_url in
  match traces_url with
  | None -> Ok ()
  | Some value when valid_url value -> Ok ()
  | Some value when String.trim value = "" -> Ok ()
  | Some _ -> Error "observability_traces_url must be an http(s) URL or empty"
;;

let validate_target (target : Sol_cli_config.target) =
  match Sol_cli_config.execution_of_target target with
  | Sol_cli_config.Serverless -> Ok ()
  | Sol_cli_config.Kubernetes ->
    (match target.observability_backend with
     | None -> Ok ()
     | Some value ->
       (match backend_of_string value with
        | Some External ->
          validate_external
            ~logs_url:target.observability_logs_url
            ~metrics_url:target.observability_metrics_url
            ~traces_url:target.observability_traces_url
        | Some (Local | Self_hosted_durable) -> Ok ()
        | None ->
          Error
            (Printf.sprintf
               "observability_backend %S is not one of local, external, \
                self_hosted_durable"
               value)))
;;
