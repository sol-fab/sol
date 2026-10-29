(** AWS SQS + Lambda lifecycle for a durable task handler.

    The application image contains a [Sol_task.TASK] handler and selects
    [Sol_task_lambda] with [SOL_TASK_RUNTIME=lambda]. This adapter owns the
    provider resources around it: an SQS source queue with a dead-letter queue,
    the Lambda function/version/alias, and the event source mapping that
    delivers batches with [ReportBatchItemFailures].

    The queues and function are tagged as this adapter's; destroy refuses a
    resource without those tags. The execution role is supplied by the operator
    and must grant the Lambda function permission to receive from the source
    queue, publish to the dead-letter queue, and write its logs. *)

type request =
  { profile : string option
  ; region : string
  ; service : string
  ; image : string
  ; role_arn : string
  ; max_attempts : int
  ; visibility_timeout_s : int
  ; dlq_retention_s : int
  ; concurrency : int
  ; record : string option
  ; run : string list -> (Sol_cli_aws_lambda_common.output, string) result
  }

type release =
  { region : string
  ; service : string
  ; function_name : string
  ; version : string
  ; alias : string
  ; image : string
  ; role_arn : string
  ; queue_name : string
  ; queue_url : string
  ; queue_arn : string
  ; dlq_name : string
  ; dlq_url : string
  ; dlq_arn : string
  ; mapping_uuid : string
  ; max_attempts : int
  ; visibility_timeout_s : int
  ; dlq_retention_s : int
  ; concurrency : int
  }

(** [(function_name, queue_name, dlq_name)] derived once from the Sol service. *)
val provider_names
  :  service:string
  -> (string * string * string, Sol_cli_aws_lambda_common.failure) result

val deploy : request -> (release, Sol_cli_aws_lambda_common.failure) result

val verify
  :  request
  -> record:string
  -> (release, Sol_cli_aws_lambda_common.failure) result

(** Send one encoded task envelope; returns the provider message id. *)
val enqueue
  :  request
  -> record:string
  -> body:string
  -> (string, Sol_cli_aws_lambda_common.failure) result

val rollback
  :  request
  -> record:string
  -> version:string
  -> (release, Sol_cli_aws_lambda_common.failure) result

val destroy : request -> record:string -> (unit, Sol_cli_aws_lambda_common.failure) result
val release_json : release -> Yojson.Safe.t
val read_record : path:string -> (release, string) result
val write_record : path:string -> release -> (unit, string) result
