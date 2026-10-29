(** GCP Pub/Sub push + Cloud Run lifecycle for a durable task handler.

    The application image contains a [Sol_task.TASK] handler and selects
    [Sol_task_pubsub] with [SOL_TASK_RUNTIME=pubsub]. This adapter owns the
    provider resources around it: a Pub/Sub topic, a push subscription with a
    dead-letter topic and delivery budget, a private Cloud Run service, and a
    dedicated Pub/Sub push service account with only the invoker and token
    creator grants it needs.

    The service and Pub/Sub resources are labeled as this adapter's; destroy
    refuses a resource without those labels. *)

type request =
  { project : string
  ; region : string
  ; service : string
  ; image : string
  ; max_attempts : int
  ; ack_deadline_s : int
  ; dlq_retention_s : int
  ; concurrency : int
  ; record : string option
  ; run : string list -> (Sol_cli_cloud_run.output, string) result
  }

type release =
  { project : string
  ; region : string
  ; service : string
  ; image : string
  ; cloud_run_service : string
  ; cloud_run_url : string
  ; revision : string
  ; topic : string
  ; subscription : string
  ; dlq_topic : string
  ; push_service_account : string
  ; max_attempts : int
  ; ack_deadline_s : int
  ; dlq_retention_s : int
  ; concurrency : int
  }

(** [(cloud_run_service, topic, subscription, dlq_topic, push_service_account_name)]. *)
val provider_names
  :  service:string
  -> (string * string * string * string * string, Sol_cli_cloud_run.failure) result

val deploy : request -> (release, Sol_cli_cloud_run.failure) result
val verify : request -> record:string -> (release, Sol_cli_cloud_run.failure) result

val enqueue
  :  request
  -> record:string
  -> body:string
  -> (string, Sol_cli_cloud_run.failure) result

val rollback
  :  request
  -> record:string
  -> revision:string
  -> (release, Sol_cli_cloud_run.failure) result

val destroy : request -> record:string -> (unit, Sol_cli_cloud_run.failure) result
val release_json : release -> Yojson.Safe.t
val read_record : path:string -> (release, string) result
val write_record : path:string -> release -> (unit, string) result
