type container_state =
  | Waiting of
      { reason : string
      ; message : string option
      }
  | Running
  | Terminated of
      { reason : string
      ; exit_code : int
      ; message : string option
      }
  | Unknown_state

type pod_status =
  { name : string
  ; phase : string
  ; ready : bool
  ; restarts : int
  ; image : string option
  ; state : container_state
  ; last_terminated_reason : string option
  }

type event =
  { ev_type : string
  ; reason : string
  ; message : string
  ; count : int
  ; last_timestamp : string option
  ; involved_name : string
  }

type confirmed_pods

val pod_list : confirmed_pods -> pod_status list
val parse_pods_json : string -> (confirmed_pods, string) result
val parse_events_json : string -> (event list, string) result
val events_for_pod : ?limit:int -> pod_name:string -> event list -> event list
val is_healthy : pod_status -> bool

type pod_expectation =
  | Continuous
  | Ephemeral

type events_fetch_result =
  | Events of event list
  | Events_unavailable of string

val format_pod_diagnosis : pod_status -> events_fetch_result -> string

type diagnosis =
  | Healthy
  | Unhealthy of string
  | Undetermined of string

val format_service_diagnosis
  :  service_name:string
  -> confirmed_pods
  -> events_fetch_result
  -> diagnosis

val format_release_diagnosis
  :  release:string
  -> namespace:string
  -> confirmed_pods
  -> events_fetch_result
  -> diagnosis

type cronjob_status =
  { last_schedule_time : string option
  ; last_successful_time : string option
  ; active_job_names : string list
  }

val parse_cronjob_status : string -> (cronjob_status, string) result

type cronjob_fetch_result =
  | Found of cronjob_status
  | Missing
  | Unavailable of string

val format_cronjob_diagnosis : service_name:string -> cronjob_fetch_result -> diagnosis

val format_active_run_diagnosis
  :  service_name:string
  -> confirmed_pods
  -> events_fetch_result
  -> diagnosis

val diagnose_service_live
  :  ctx:Sol_cli_kube_destination.context
  -> pod_expectation:pod_expectation
  -> ns:string
  -> service_name:string
  -> k8s_name:string
  -> unit
  -> diagnosis

val diagnose_release_live
  :  ctx:Sol_cli_kube_destination.context
  -> ns:string
  -> release:string
  -> unit
  -> diagnosis
