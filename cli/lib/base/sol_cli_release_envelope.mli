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

val component_kind_to_string : component_kind -> string
val component_kind_of_string : string -> component_kind option
val execution_to_string : execution -> string
val execution_of_string : string -> execution option
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
