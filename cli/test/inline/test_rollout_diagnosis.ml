let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual

module D = Sol_cli_rollout_diagnosis

let ok what = function
  | Ok v -> v
  | Error e -> Windtrap.failf "%s: unexpected decode error: %s" what e
;;

let pods_of json = D.parse_pods_json json |> ok "pods" |> D.pod_list
let confirmed_of json = D.parse_pods_json json |> ok "pods"
let events_of json = D.parse_events_json json |> ok "events"

let reports_healthy = function
  | D.Healthy -> true
  | D.Unhealthy _ | D.Undetermined _ -> false
;;

let reports_a_problem = function
  | D.Healthy -> false
  | D.Unhealthy _ | D.Undetermined _ -> true
;;

let healthy_pod_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-abc"},
   "status": {"phase": "Running",
     "containerStatuses": [
       {"ready": true, "restartCount": 0, "image": "registry/charge-svc:sha1",
        "state": {"running": {"startedAt": "2026-09-01T00:00:00Z"}}}
     ]}}
]}
|}
;;

let succeeded_pod_json =
  {|
{"items": [
  {"metadata": {"name": "invoice-fn-abc"},
   "status": {"phase": "Succeeded",
     "containerStatuses": [
       {"ready": false, "restartCount": 0, "image": "registry/invoice-fn:sha1",
        "state": {"terminated": {"reason": "Completed", "exitCode": 0}}}
     ]}}
]}
|}
;;

let image_pull_backoff_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-xyz"},
   "status": {"phase": "Pending",
     "containerStatuses": [
       {"ready": false, "restartCount": 0, "image": "registry/charge-svc:bad-tag",
        "state": {"waiting": {"reason": "ImagePullBackOff",
                               "message": "Back-off pulling image \"registry/charge-svc:bad-tag\""}}}
     ]}}
]}
|}
;;

let crash_loop_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-crash"},
   "status": {"phase": "Running",
     "containerStatuses": [
       {"ready": false, "restartCount": 6, "image": "registry/charge-svc:sha2",
        "state": {"waiting": {"reason": "CrashLoopBackOff", "message": null}},
        "lastState": {"terminated": {"reason": "OOMKilled", "exitCode": 137}}}
     ]}}
]}
|}
;;

let pending_no_containers_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-pending"},
   "status": {"phase": "Pending"}}
]}
|}
;;

let container_creating_json =
  {|
{"items": [
  {"metadata": {"name": "invoice-fn-starting"},
   "status": {"phase": "Pending",
     "containerStatuses": [
       {"ready": false, "restartCount": 0, "image": "registry/invoice-fn:sha1",
        "state": {"waiting": {"reason": "ContainerCreating", "message": null}}}
     ]}}
]}
|}
;;

let container_creating_after_restart_json =
  {|
{"items": [
  {"metadata": {"name": "invoice-fn-retrying"},
   "status": {"phase": "Pending",
     "containerStatuses": [
       {"ready": false, "restartCount": 1, "image": "registry/invoice-fn:sha1",
        "state": {"waiting": {"reason": "ContainerCreating", "message": null}}}
     ]}}
]}
|}
;;

let missing_status_pod_json =
  {|
{"items": [
  {"metadata": {"name": "charge-svc-missing-status"}},
  {"metadata": {"name": "charge-svc-abc"},
   "status": {"phase": "Running",
     "containerStatuses": [
       {"ready": true, "restartCount": 0, "image": "registry/charge-svc:sha1",
        "state": {"running": {"startedAt": "2026-09-01T00:00:00Z"}}}
     ]}}
]}
|}
;;

let events_json =
  {|
{"items": [
  {"type": "Warning", "reason": "FailedPull", "message": "rpc error: pull access denied",
   "count": 3, "lastTimestamp": "2026-09-01T00:00:01Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-xyz"}},
  {"type": "Warning", "reason": "BackOff", "message": "Back-off pulling image",
   "count": 5, "lastTimestamp": "2026-09-01T00:00:05Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-xyz"}},
  {"type": "Warning", "reason": "FailedScheduling", "message": "0/2 nodes available",
   "count": 1, "lastTimestamp": "2026-09-01T00:00:00Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-pending"}},
  {"type": "Normal", "reason": "Scheduled", "message": "unrelated pod",
   "count": 1, "lastTimestamp": "2026-09-01T00:00:00Z",
   "involvedObject": {"kind": "Pod", "name": "other-svc-abc"}}
]}
|}
;;

let test_parse_healthy_pod () =
  match pods_of healthy_pod_json with
  | [ p ] ->
    check_string "name" "charge-svc-abc" p.name;
    check_string "phase" "Running" p.phase;
    check_bool "ready" true p.ready;
    check_int "restarts" 0 p.restarts;
    check_bool "is_healthy" true (D.is_healthy p)
  | _ -> Windtrap.fail "expected exactly one pod"
;;

let test_parse_image_pull_backoff () =
  match pods_of image_pull_backoff_json with
  | [ p ] ->
    check_bool "is_healthy" false (D.is_healthy p);
    (match p.state with
     | D.Waiting { reason; _ } -> check_string "reason" "ImagePullBackOff" reason
     | _ -> Windtrap.fail "expected Waiting state")
  | _ -> Windtrap.fail "expected exactly one pod"
;;

let test_parse_crash_loop_last_termination () =
  match pods_of crash_loop_json with
  | [ p ] ->
    check_int "restarts" 6 p.restarts;
    check_string
      "last_terminated_reason"
      "OOMKilled"
      (Option.value ~default:"none" p.last_terminated_reason)
  | _ -> Windtrap.fail "expected exactly one pod"
;;

let test_parse_pod_with_no_container_statuses () =
  match pods_of pending_no_containers_json with
  | [ p ] ->
    check_string "phase" "Pending" p.phase;
    check_bool "is_healthy" false (D.is_healthy p)
  | _ -> Windtrap.fail "expected exactly one pod"
;;

let test_parse_pod_with_missing_status_keeps_list () =
  match pods_of missing_status_pod_json with
  | [ missing; healthy ] ->
    check_string "missing name" "charge-svc-missing-status" missing.name;
    check_string "missing phase" "Unknown" missing.phase;
    check_bool "missing is unhealthy" false (D.is_healthy missing);
    check_string "healthy name" "charge-svc-abc" healthy.name;
    check_bool "healthy still parsed" true (D.is_healthy healthy)
  | pods -> Windtrap.failf "expected two pods, got %d" (List.length pods)
;;

let test_events_for_pod_filters_and_orders () =
  let events = events_of events_json in
  let for_xyz = D.events_for_pod ~pod_name:"charge-svc-xyz" events in
  check_int "two events for charge-svc-xyz" 2 (List.length for_xyz);
  check_string "most recent first" "BackOff" (List.hd for_xyz).D.reason
;;

let test_events_for_pod_excludes_other_pods () =
  let events = events_of events_json in
  let for_other = D.events_for_pod ~pod_name:"charge-svc-abc" events in
  check_int "no events for unrelated pod" 0 (List.length for_other)
;;

let test_format_service_diagnosis_none_when_healthy () =
  let pods = confirmed_of healthy_pod_json in
  check_bool
    "no diagnosis for healthy service"
    true
    (reports_healthy
       (D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events [])))
;;

let test_format_service_diagnosis_includes_events_and_reason () =
  let pods = confirmed_of image_pull_backoff_json in
  let events = events_of events_json in
  match D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events events) with
  | D.Healthy -> Windtrap.fail "expected a diagnosis"
  | D.Undetermined why ->
    Windtrap.fail ("the pod list was readable, so a verdict is expected: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (Sol_cli_string.contains ~needle:"charge-svc rollout failed" diagnosis);
    check_bool
      "mentions ImagePullBackOff"
      true
      (Sol_cli_string.contains ~needle:"ImagePullBackOff" diagnosis);
    check_bool
      "mentions FailedPull event"
      true
      (Sol_cli_string.contains ~needle:"FailedPull" diagnosis)
;;

let test_format_release_diagnosis_includes_events_and_reason () =
  let pods = confirmed_of image_pull_backoff_json in
  let events = events_of events_json in
  match
    D.format_release_diagnosis
      ~release:"loki"
      ~namespace:"monitoring"
      pods
      (D.Events events)
  with
  | D.Healthy -> Windtrap.fail "expected a diagnosis"
  | D.Undetermined why ->
    Windtrap.fail ("the pod list was readable, so a verdict is expected: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "names the release and namespace"
      true
      (Sol_cli_string.contains
         ~needle:"helm release loki in namespace monitoring did not become ready"
         diagnosis);
    check_bool
      "mentions ImagePullBackOff"
      true
      (Sol_cli_string.contains ~needle:"ImagePullBackOff" diagnosis);
    check_bool
      "mentions FailedPull event"
      true
      (Sol_cli_string.contains ~needle:"FailedPull" diagnosis)
;;

let test_format_release_diagnosis_includes_scheduling_events () =
  let pods = confirmed_of pending_no_containers_json in
  let events = events_of events_json in
  match
    D.format_release_diagnosis
      ~release:"loki"
      ~namespace:"monitoring"
      pods
      (D.Events events)
  with
  | D.Healthy -> Windtrap.fail "expected a diagnosis for an unscheduled pod"
  | D.Undetermined why ->
    Windtrap.fail ("the pod list was readable, so a verdict is expected: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "reports the pod phase"
      true
      (Sol_cli_string.contains ~needle:"Pod charge-svc-pending: Pending" diagnosis);
    check_bool
      "reports the scheduler's event"
      true
      (Sol_cli_string.contains ~needle:"FailedScheduling" diagnosis);
    check_bool
      "keeps the scheduler's message"
      true
      (Sol_cli_string.contains ~needle:"0/2 nodes available" diagnosis)
;;

let test_format_release_diagnosis_reports_a_missing_pod_list () =
  match
    D.format_release_diagnosis
      ~release:"loki"
      ~namespace:"monitoring"
      (confirmed_of {|{"items": []}|})
      (D.Events [])
  with
  | D.Healthy -> Windtrap.fail "expected a diagnosis for zero pods, not a healthy verdict"
  | D.Undetermined why ->
    Windtrap.fail ("the pod list was readable, so a verdict is expected: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "says no pods were found for the release"
      true
      (Sol_cli_string.contains ~needle:"No pods found for this release." diagnosis)
;;

let test_format_release_diagnosis_ignores_succeeded_hook_pods () =
  let pods = confirmed_of succeeded_pod_json in
  check_bool
    "a completed hook pod is not an install failure"
    true
    (reports_healthy
       (D.format_release_diagnosis
          ~release:"loki"
          ~namespace:"monitoring"
          pods
          (D.Events [])))
;;

let test_format_service_diagnosis_reports_empty_pod_list () =
  match
    D.format_service_diagnosis
      ~service_name:"charge-svc"
      (confirmed_of {|{"items": []}|})
      (D.Events [])
  with
  | D.Healthy -> Windtrap.fail "expected a diagnosis for zero pods, not a healthy verdict"
  | D.Undetermined why ->
    Windtrap.fail ("the pod list was readable, so a verdict is expected: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (Sol_cli_string.contains ~needle:"charge-svc rollout failed" diagnosis);
    check_bool
      "mentions no pods found"
      true
      (Sol_cli_string.contains ~needle:"No pods found" diagnosis)
;;

let test_format_service_diagnosis_succeeded_pod_still_flagged_when_continuous () =
  let pods = confirmed_of succeeded_pod_json in
  check_bool
    "a Succeeded pod is still a finding for Continuous (Svc/Worker)"
    true
    (reports_a_problem
       (D.format_service_diagnosis ~service_name:"charge-svc" pods (D.Events [])))
;;

let never_scheduled : D.cronjob_status =
  { last_schedule_time = None; last_successful_time = None; active_job_names = [] }
;;

let idle_last_run_succeeded : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-02T10:00:05Z"
  ; active_job_names = []
  }
;;

let idle_last_run_failed : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-01T10:00:05Z"
  ; active_job_names = []
  }
;;

let idle_success_at_schedule_boundary : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = Some "2026-09-02T10:00:00Z"
  ; active_job_names = []
  }
;;

let idle_never_succeeded : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = None
  ; active_job_names = []
  }
;;

let run_currently_active : D.cronjob_status =
  { last_schedule_time = Some "2026-09-02T10:00:00Z"
  ; last_successful_time = None
  ; active_job_names = [ "invoice-fn-29384710-abcde" ]
  }
;;

let test_format_cronjob_diagnosis_never_scheduled_is_ok () =
  check_bool
    "never scheduled -> no diagnosis"
    true
    (reports_healthy
       (D.format_cronjob_diagnosis ~service_name:"invoice-fn" (D.Found never_scheduled)))
;;

let test_format_cronjob_diagnosis_last_run_succeeded_is_ok () =
  check_bool
    "most recent run succeeded -> no diagnosis"
    true
    (reports_healthy
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_last_run_succeeded)))
;;

let test_format_cronjob_diagnosis_success_at_schedule_boundary_is_ok () =
  check_bool
    "success at the same instant as the schedule trigger -> no diagnosis"
    true
    (reports_healthy
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_success_at_schedule_boundary)))
;;

let test_format_cronjob_diagnosis_last_run_failed_is_flagged () =
  match
    D.format_cronjob_diagnosis ~service_name:"invoice-fn" (D.Found idle_last_run_failed)
  with
  | D.Healthy ->
    Windtrap.fail "expected a diagnosis for a most-recent-run failure, not healthy"
  | D.Undetermined why -> Windtrap.fail ("the CronJob was readable: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (Sol_cli_string.contains ~needle:"invoice-fn rollout failed" diagnosis);
    check_bool
      "mentions the schedule time"
      true
      (Sol_cli_string.contains ~needle:"2026-09-02T10:00:00Z" diagnosis)
;;

let test_format_cronjob_diagnosis_never_succeeded_is_flagged () =
  check_bool
    "scheduled but never once succeeded -> flagged"
    true
    (reports_a_problem
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found idle_never_succeeded)))
;;

let test_format_cronjob_diagnosis_active_run_is_ok () =
  check_bool
    "a currently-active run is not (yet) a diagnosis"
    true
    (reports_healthy
       (D.format_cronjob_diagnosis
          ~service_name:"invoice-fn"
          (D.Found run_currently_active)))
;;

let test_format_cronjob_diagnosis_missing_is_flagged () =
  match D.format_cronjob_diagnosis ~service_name:"invoice-fn" D.Missing with
  | D.Healthy -> Windtrap.fail "expected a diagnosis for a missing CronJob, not healthy"
  | D.Undetermined why -> Windtrap.fail ("the CronJob read succeeded: " ^ why)
  | D.Unhealthy diagnosis ->
    check_bool
      "mentions rollout failed"
      true
      (Sol_cli_string.contains ~needle:"invoice-fn rollout failed" diagnosis);
    check_bool
      "mentions not found"
      true
      (Sol_cli_string.contains ~needle:"not found" diagnosis)
;;

let test_format_cronjob_diagnosis_unavailable_is_undetermined () =
  match
    D.format_cronjob_diagnosis
      ~service_name:"invoice-fn"
      (D.Unavailable "the kubectl call failed")
  with
  | D.Undetermined why ->
    check_bool
      "the verdict carries why"
      true
      (Sol_cli_string.contains ~needle:"kubectl call failed" why)
  | D.Healthy -> Windtrap.fail "a failed read must not be reported as healthy"
  | D.Unhealthy _ -> Windtrap.fail "a failed read is not a rollout failure either"
;;

let test_format_active_run_diagnosis_running_pod_is_ok () =
  let pods = confirmed_of healthy_pod_json in
  check_bool
    "a Running, ready pod is not a finding"
    true
    (reports_healthy
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_succeeded_pod_is_ok () =
  let pods = confirmed_of succeeded_pod_json in
  check_bool
    "a Succeeded active-run pod is not a finding"
    true
    (reports_healthy
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_stuck_pod_is_flagged () =
  let pods = confirmed_of image_pull_backoff_json in
  check_bool
    "a stuck (ImagePullBackOff) active-run pod is a finding"
    true
    (reports_a_problem
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_pending_startup_is_ok () =
  let pods = confirmed_of pending_no_containers_json in
  check_bool
    "a freshly-scheduled pod with no container status yet is not a finding"
    true
    (reports_healthy
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_failed_scheduling_is_flagged () =
  let pods = confirmed_of pending_no_containers_json in
  let events = events_of events_json in
  check_bool
    "a FailedScheduling pod is still a finding despite looking like normal startup"
    true
    (reports_a_problem
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events events)))
;;

let test_format_active_run_diagnosis_container_creating_is_ok () =
  let pods = confirmed_of container_creating_json in
  check_bool
    "ContainerCreating with no restarts is not a finding"
    true
    (reports_healthy
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_format_active_run_diagnosis_container_creating_after_restart_is_flagged () =
  let pods = confirmed_of container_creating_after_restart_json in
  check_bool
    "ContainerCreating after a restart is still a finding"
    true
    (reports_a_problem
       (D.format_active_run_diagnosis ~service_name:"invoice-fn" pods (D.Events [])))
;;

let test_parse_cronjob_status () =
  let json =
    {|{"status": {"lastScheduleTime": "2026-09-02T10:00:00Z", "lastSuccessfulTime": "2026-09-02T10:00:05Z", "active": [{"name": "invoice-fn-1"}]}}|}
  in
  match D.parse_cronjob_status json with
  | Error e -> Windtrap.fail ("expected a cronjob_status: " ^ e)
  | Ok (status : D.cronjob_status) ->
    check_string
      "lastScheduleTime"
      "2026-09-02T10:00:00Z"
      (Option.value ~default:"" status.last_schedule_time);
    check_string
      "lastSuccessfulTime"
      "2026-09-02T10:00:05Z"
      (Option.value ~default:"" status.last_successful_time);
    check_string
      "active_job_names"
      "invoice-fn-1"
      (match status.active_job_names with
       | [ name ] -> name
       | _ -> "")
;;

let test_parse_cronjob_status_never_scheduled () =
  match D.parse_cronjob_status {|{"status": {}}|} with
  | Error e -> Windtrap.fail ("expected a cronjob_status: " ^ e)
  | Ok (status : D.cronjob_status) ->
    check_bool "no lastScheduleTime" true (status.last_schedule_time = None);
    check_int "no active jobs" 0 (List.length status.active_job_names)
;;

let test_parse_cronjob_status_status_key_absent () =
  match D.parse_cronjob_status {|{}|} with
  | Error e -> Windtrap.fail ("expected a cronjob_status, got Unavailable: " ^ e)
  | Ok (status : D.cronjob_status) ->
    check_bool "no lastScheduleTime" true (status.last_schedule_time = None);
    check_int "no active jobs" 0 (List.length status.active_job_names)
;;

let is_error = function
  | Ok _ -> false
  | Error _ -> true
;;

let test_malformed_reads_are_errors () =
  check_bool "pods: not JSON" true (is_error (D.parse_pods_json "not json"));
  check_bool "pods: no items" true (is_error (D.parse_pods_json {|{"kind": "Status"}|}));
  check_bool
    "pods: item not an object"
    true
    (is_error (D.parse_pods_json {|{"items": [1]}|}));
  check_bool "events: not JSON" true (is_error (D.parse_events_json "<html>"));
  check_bool
    "events: items not a list"
    true
    (is_error (D.parse_events_json {|{"items": {}}|}));
  check_bool "cronjob: not JSON" true (is_error (D.parse_cronjob_status ""));
  check_bool
    "cronjob: active not a list"
    true
    (is_error (D.parse_cronjob_status {|{"status": {"active": "x"}}|}));
  check_bool
    "cronjob: active job with no name"
    true
    (is_error (D.parse_cronjob_status {|{"status": {"active": [{}]}}|}))
;;

let test_empty_lists_are_answers () =
  check_int "no pods" 0 (List.length (pods_of {|{"items": []}|}));
  check_int "no events" 0 (List.length (events_of {|{"items": []}|}))
;;

let test_pod_without_metadata_parses () =
  match pods_of {|{"items": [{"status": {"phase": "Pending"}}]}|} with
  | [ p ] ->
    check_string "name defaults" "unknown" p.name;
    check_string "phase" "Pending" p.phase
  | _ -> Windtrap.fail "expected one pod"
;;

let test_unavailable_events_are_named_not_empty () =
  match
    D.format_service_diagnosis
      ~service_name:"charge-svc"
      (confirmed_of crash_loop_json)
      (D.Events_unavailable
         "Error from server (Forbidden): events is forbidden: cannot list resource \
          \"events\"")
  with
  | D.Healthy -> Windtrap.fail "an unhealthy pod must be diagnosed"
  | D.Undetermined why ->
    Windtrap.fail ("the pod list was readable, so this should be a diagnosis: " ^ why)
  | D.Unhealthy text ->
    check_bool
      "the block says the events read was unavailable"
      true
      (Sol_cli_string.contains ~needle:"Events unavailable:" text);
    check_bool
      "and carries the reason"
      true
      (Sol_cli_string.contains ~needle:"Forbidden" text);
    check_bool
      "and does not claim there were no events"
      false
      (Sol_cli_string.contains ~needle:"No events recorded" text)
;;

let test_zero_events_are_reported_as_zero () =
  match
    D.format_service_diagnosis
      ~service_name:"charge-svc"
      (confirmed_of crash_loop_json)
      (D.Events [])
  with
  | D.Healthy -> Windtrap.fail "an unhealthy pod must be diagnosed"
  | D.Undetermined why ->
    Windtrap.fail ("the pod list was readable, so this should be a diagnosis: " ^ why)
  | D.Unhealthy text ->
    check_bool
      "the block says there were no events"
      true
      (Sol_cli_string.contains ~needle:"No events recorded" text);
    check_bool
      "and does not claim the read was unavailable"
      false
      (Sol_cli_string.contains ~needle:"Events unavailable:" text)
;;

let with_fake_kubectl_script script f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let with_fake_kubectl ?(deny = "events") f =
  let script =
    Printf.sprintf
      {|#!/bin/sh
verb=""
deny='%s'
for a in "$@"; do
  case "$a" in get|create|apply|patch|delete) verb="$a"; break ;; esac
done
if [ "$verb" = "get" ]; then
  case "$*" in
    *pods*)
      if [ "$deny" = "pods" ]; then
        echo 'Error from server (Forbidden): pods is forbidden: User "arn:aws:sts::111122223333:assumed-role/sol-operator/EKSGetTokenAuth" cannot list resource "pods" in API group "" in the namespace "pluto-comms"' >&2
        exit 1
      fi
      cat <<'JSON'
%s
JSON
      exit 0 ;;
    *events*)
      if [ "$deny" = "events" ]; then
        echo 'Error from server (Forbidden): events is forbidden: cannot list resource "events" in API group "" in the namespace "pluto-checkout"' >&2
        exit 1
      fi
      echo '{"items":[]}'
      exit 0 ;;
  esac
fi
exit 0
|}
      deny
      crash_loop_json
  in
  with_fake_kubectl_script script f
;;

let with_fake_release_kubectl f =
  let script =
    Printf.sprintf
      {|#!/bin/sh
case "$*" in
  *"app.kubernetes.io/instance=loki"*)
    case "$*" in
      *pods*)
        cat <<'JSON'
%s
JSON
        exit 0 ;;
      *events*)
        cat <<'JSON'
%s
JSON
        exit 0 ;;
    esac ;;
esac
echo '{"items":[]}'
exit 0
|}
      image_pull_backoff_json
      events_json
  in
  with_fake_kubectl_script script f
;;

let test_the_fetch_distinguishes_a_denied_read () =
  with_fake_kubectl (fun () ->
    match
      D.diagnose_service_live
        ~ctx:Sol_cli_kube_destination.local_context
        ~pod_expectation:D.Continuous
        ~ns:"pluto-checkout"
        ~service_name:"charge-svc"
        ~k8s_name:"charge-svc"
        ()
    with
    | D.Healthy -> Windtrap.fail "the pod is unhealthy, so a diagnosis is expected"
    | D.Undetermined why ->
      Windtrap.fail ("the pod list was readable, so a verdict is expected: " ^ why)
    | D.Unhealthy text ->
      check_bool
        "the denied events read reaches the output as unavailable"
        true
        (Sol_cli_string.contains ~needle:"Events unavailable:" text);
      check_bool
        "and is not reported as an empty event set"
        false
        (Sol_cli_string.contains ~needle:"No events recorded" text))
;;

let test_an_unreadable_workload_is_undetermined_not_healthy () =
  with_fake_kubectl ~deny:"pods" (fun () ->
    match
      D.diagnose_service_live
        ~ctx:Sol_cli_kube_destination.local_context
        ~pod_expectation:D.Continuous
        ~ns:"pluto-comms"
        ~service_name:"notify-worker"
        ~k8s_name:"notify-worker"
        ()
    with
    | D.Undetermined why ->
      check_bool
        "the verdict says the workload could not be read"
        true
        (Sol_cli_string.contains ~needle:"could not be read" why);
      check_bool
        "and carries the server's reason"
        true
        (Sol_cli_string.contains ~needle:"Forbidden" why)
    | D.Healthy ->
      Windtrap.fail "an unreadable workload must never be reported healthy (FND-0019)"
    | D.Unhealthy _ ->
      Windtrap.fail "a read that did not happen is not a rollout failure either")
;;

let test_release_fetch_uses_the_release_selector () =
  with_fake_release_kubectl (fun () ->
    match
      D.diagnose_release_live
        ~ctx:Sol_cli_kube_destination.local_context
        ~ns:"monitoring"
        ~release:"loki"
        ()
    with
    | D.Healthy ->
      Windtrap.fail "the release has an unhealthy pod, so a diagnosis is expected"
    | D.Undetermined why ->
      Windtrap.fail ("the pod list was readable, so a verdict is expected: " ^ why)
    | D.Unhealthy text ->
      check_bool
        "queries the release's pods by its Helm instance label"
        true
        (Sol_cli_string.contains ~needle:"charge-svc-xyz" text);
      check_bool
        "reports the pod's own reason"
        true
        (Sol_cli_string.contains ~needle:"ImagePullBackOff" text))
;;

let%test "diagnose_release_live: queries the release's pods" =
  test_release_fetch_uses_the_release_selector ()
;;

let%test "parse_pods_json: healthy pod" = test_parse_healthy_pod ()
let%test "parse_pods_json: image pull backoff" = test_parse_image_pull_backoff ()

let%test "parse_pods_json: crash loop last termination" =
  test_parse_crash_loop_last_termination ()
;;

let%test "parse_pods_json: pod with no container statuses" =
  test_parse_pod_with_no_container_statuses ()
;;

let%test "parse_pods_json: pod with missing status keeps list" =
  test_parse_pod_with_missing_status_keeps_list ()
;;

let%test "events: filters and orders by pod" = test_events_for_pod_filters_and_orders ()
let%test "events: excludes other pods" = test_events_for_pod_excludes_other_pods ()

let%test "format_service_diagnosis: none when healthy" =
  test_format_service_diagnosis_none_when_healthy ()
;;

let%test "format_service_diagnosis: includes events and reason" =
  test_format_service_diagnosis_includes_events_and_reason ()
;;

let%test "format_service_diagnosis: reports empty pod list, not healthy" =
  test_format_service_diagnosis_reports_empty_pod_list ()
;;

let%test "format_service_diagnosis: succeeded pod still flagged when Continuous" =
  test_format_service_diagnosis_succeeded_pod_still_flagged_when_continuous ()
;;

let%test "format_release_diagnosis: includes events and reason" =
  test_format_release_diagnosis_includes_events_and_reason ()
;;

let%test "format_release_diagnosis: reports scheduling events" =
  test_format_release_diagnosis_includes_scheduling_events ()
;;

let%test "format_release_diagnosis: reports a missing pod list" =
  test_format_release_diagnosis_reports_a_missing_pod_list ()
;;

let%test "format_release_diagnosis: ignores succeeded hook pods" =
  test_format_release_diagnosis_ignores_succeeded_hook_pods ()
;;

let%test "format_cronjob_diagnosis: never scheduled -> OK" =
  test_format_cronjob_diagnosis_never_scheduled_is_ok ()
;;

let%test "format_cronjob_diagnosis: last run succeeded -> OK" =
  test_format_cronjob_diagnosis_last_run_succeeded_is_ok ()
;;

let%test "format_cronjob_diagnosis: success at schedule boundary -> OK" =
  test_format_cronjob_diagnosis_success_at_schedule_boundary_is_ok ()
;;

let%test "format_cronjob_diagnosis: last run failed -> flagged" =
  test_format_cronjob_diagnosis_last_run_failed_is_flagged ()
;;

let%test "format_cronjob_diagnosis: never succeeded -> flagged" =
  test_format_cronjob_diagnosis_never_succeeded_is_flagged ()
;;

let%test "format_cronjob_diagnosis: active run -> OK" =
  test_format_cronjob_diagnosis_active_run_is_ok ()
;;

let%test "format_cronjob_diagnosis: missing CronJob -> flagged" =
  test_format_cronjob_diagnosis_missing_is_flagged ()
;;

let%test "format_cronjob_diagnosis: an unavailable fetch is Undetermined, not healthy" =
  test_format_cronjob_diagnosis_unavailable_is_undetermined ()
;;

let%test "format_active_run_diagnosis: running pod -> OK" =
  test_format_active_run_diagnosis_running_pod_is_ok ()
;;

let%test "format_active_run_diagnosis: succeeded pod -> OK" =
  test_format_active_run_diagnosis_succeeded_pod_is_ok ()
;;

let%test "format_active_run_diagnosis: stuck pod -> flagged" =
  test_format_active_run_diagnosis_stuck_pod_is_flagged ()
;;

let%test "format_active_run_diagnosis: pending startup -> OK" =
  test_format_active_run_diagnosis_pending_startup_is_ok ()
;;

let%test "format_active_run_diagnosis: failed scheduling -> flagged" =
  test_format_active_run_diagnosis_failed_scheduling_is_flagged ()
;;

let%test "format_active_run_diagnosis: container creating -> OK" =
  test_format_active_run_diagnosis_container_creating_is_ok ()
;;

let%test "format_active_run_diagnosis: container creating after restart -> flagged" =
  test_format_active_run_diagnosis_container_creating_after_restart_is_flagged ()
;;

let%test "parse_cronjob_status: parses full status" = test_parse_cronjob_status ()

let%test "parse_cronjob_status: never scheduled defaults" =
  test_parse_cronjob_status_never_scheduled ()
;;

let%test "parse_cronjob_status: status key absent entirely" =
  test_parse_cronjob_status_status_key_absent ()
;;

let%test "malformed reads are errors (REFAC-127): malformed is Error" =
  test_malformed_reads_are_errors ()
;;

let%test "malformed reads are errors (REFAC-127): empty list is an answer" =
  test_empty_lists_are_answers ()
;;

let%test "malformed reads are errors (REFAC-127): pod without metadata parses" =
  test_pod_without_metadata_parses ()
;;

let%test
    "failed reads are not absent evidence (INFRA-057): unavailable events are named, not \
     empty"
  =
  test_unavailable_events_are_named_not_empty ()
;;

let%test
    "failed reads are not absent evidence (INFRA-057): zero events are reported as zero"
  =
  test_zero_events_are_reported_as_zero ()
;;

let%test
    "failed reads are not absent evidence (INFRA-057): the fetch distinguishes a denied \
     read"
  =
  test_the_fetch_distinguishes_a_denied_read ()
;;

let%test
    "failed reads are not absent evidence (INFRA-057): an unreadable workload is \
     Undetermined, never healthy"
  =
  test_an_unreadable_workload_is_undetermined_not_healthy ()
;;
