(* The executable guard for the ownership rule (docs/architecture/ownership.md): a label
   selects what to look at, only the live UID recorded at apply authorizes a removal. These
   tests drive the removal paths themselves (Sol_cli_rollback.prune_workloads and
   Sol_cli_workload_scope.release_workloads), not just the ownership predicate, so a revert
   to label-based selection fails here even though the predicate would still pass. Verified
   by negative control: making both paths label-based fails both tests.

   Run it through dune — `dune build @ci-unit` (what CI runs) or
   `dune build @cli/test/inline/runtest`. Do not invoke the generated
   `inline-test-runner.exe` by hand after a plain `dune build`: the runner is only built by
   the `runtest` alias, so a bare build leaves the previous binary in place and a real
   regression would read as a pass. CI is `opam exec -- dune build @ci-unit`, which rebuilds
   the runner from the changed library, so the guard cannot be masked there. *)

let with_fake_kubectl script f =
  let dir = Filename.temp_file "sol-guard-kubectl" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
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

let owned resource namespace name uid =
  { Sol_cli_release_id.resource; namespace; name; uid }
;;

let identity kind name : Sol_cli_rollback.workload_identity =
  { kind; namespace = "myapp-payments"; name }
;;

let has_target targets ~resource ~name =
  List.exists
    (fun (t : Sol_cli_rollback.prune_target) ->
       String.equal t.resource resource && String.equal t.name name)
    targets
;;

let contains haystack needle = Sol_cli_string.contains ~needle haystack

(* --- Rollback prune ------------------------------------------------------------------ *)

(* The fake answers the per-object UID read at removal time (a jsonpath get), the claim
   read, and the delete. `uid-owned`/`uid-cron` match the recorded evidence; `mismatch`
   reads a different UID; `no-evidence` has no recorded UID. *)
let rollback_script =
  {|#!/bin/sh
case "$3" in
  get)
    case "$*" in
      *jsonpath*)
        case "$4/$5" in
          deployment/owned) printf '%s' uid-owned ;;
          cronjob/owned-cron) printf '%s' uid-cron ;;
          deployment/mismatch) printf '%s' uid-live-other ;;
          deployment/no-evidence) printf '%s' uid-live-none ;;
          *) printf '%s\n' 'Error from server (NotFound): not found' >&2; exit 1 ;;
        esac ;;
      *) printf '%s' '{"spec":{"template":{"spec":{"volumes":[]}}}}' ;;
    esac ;;
  delete) exit 0 ;;
  *) exit 1 ;;
esac
|}
;;

let test_rollback_prunes_only_label_matched_workloads_with_the_recorded_uid () =
  let evidence =
    [ owned "deployment" "myapp-payments" "owned" "uid-owned"
    ; owned "cronjob" "myapp-payments" "owned-cron" "uid-cron"
    ; owned "deployment" "myapp-payments" "mismatch" "uid-recorded-other"
    ]
  in
  let surplus =
    [ identity Sol_cli_rollback.Live_deployment "owned"
    ; identity Sol_cli_rollback.Live_cronjob "owned-cron"
    ; identity Sol_cli_rollback.Live_deployment "mismatch"
    ; identity Sol_cli_rollback.Live_deployment "no-evidence"
    ]
  in
  let as_live = List.map (fun id -> id, "r-1") surplus in
  with_fake_kubectl rollback_script (fun () ->
    match
      Sol_cli_rollback.prune_workloads
        ~ctx:Sol_cli_kube_destination.local_context
        ~evidence
        ~live:as_live
        ~surplus:as_live
    with
    | Error message -> Windtrap.fail message
    | Ok report ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"a label-matched Deployment whose live UID is the recorded one is removed"
        true
        (has_target report.removed ~resource:"deployment" ~name:"owned");
      Windtrap.equal
        Windtrap.bool
        ~msg:"a label-matched CronJob whose live UID is the recorded one is removed"
        true
        (has_target report.removed ~resource:"cronjob" ~name:"owned-cron");
      Windtrap.equal
        Windtrap.bool
        ~msg:"a label-matched workload whose live UID differs is retained"
        false
        (has_target report.removed ~resource:"deployment" ~name:"mismatch");
      Windtrap.equal
        Windtrap.bool
        ~msg:"a label-matched workload with no recorded UID is retained"
        false
        (has_target report.removed ~resource:"deployment" ~name:"no-evidence");
      Windtrap.equal
        Windtrap.bool
        ~msg:"an auxiliary follows the owning workload's match"
        true
        (has_target report.removed ~resource:"service" ~name:"owned"
         && has_target report.removed ~resource:"service" ~name:"owned-cron");
      Windtrap.equal
        Windtrap.bool
        ~msg:"an auxiliary of a retained workload is never a target"
        false
        (has_target report.removed ~resource:"service" ~name:"mismatch"
         || has_target report.removed ~resource:"service" ~name:"no-evidence");
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"both retained workloads are reported, in order, as not owned"
        [ "mismatch"; "no-evidence" ]
        (List.map
           (fun (u : Sol_cli_rollback.unowned_workload) -> u.identity.name)
           report.unowned))
;;

(* --- Cloud destroy release ----------------------------------------------------------- *)

let deployment_listing =
  {|{"items":[
      {"kind":"Deployment","metadata":{"name":"owned","uid":"uid-owned"},
       "spec":{"template":{"metadata":{"labels":{"workspace":"myapp"}}}}},
      {"kind":"Deployment","metadata":{"name":"mismatch","uid":"uid-live-other"},
       "spec":{"template":{"metadata":{"labels":{"workspace":"myapp"}}}}},
      {"kind":"Deployment","metadata":{"name":"no-evidence","uid":"uid-live-none"},
       "spec":{"template":{"metadata":{"labels":{"workspace":"myapp"}}}}},
      {"kind":"Deployment","metadata":{"name":"someone-else","uid":"uid-other"},
       "spec":{"template":{"metadata":{"labels":{"workspace":"other"}}}}}
    ]}|}
;;

let cronjob_listing =
  {|{"items":[
      {"kind":"CronJob","metadata":{"name":"owned-cron","uid":"uid-cron"},
       "spec":{"jobTemplate":{"spec":{"template":{"metadata":{"labels":{"workspace":"myapp"}}}}}}}
    ]}|}
;;

let empty_listing = {|{"items":[]}|}

let test_release_deletes_only_label_matched_workloads_with_the_recorded_uid () =
  let evidence =
    [ owned "deployment" "myapp-payments" "owned" "uid-owned"
    ; owned "cronjob" "myapp-payments" "owned-cron" "uid-cron"
    ; owned "deployment" "myapp-payments" "mismatch" "uid-recorded-other"
    ]
  in
  let deleted = ref [] in
  let run args =
    match List.nth_opt args 1 with
    | Some "deployment" -> Ok deployment_listing
    | Some "cronjob" -> Ok cronjob_listing
    | Some ("job" | "rollout") -> Ok empty_listing
    | _ -> Ok empty_listing
  in
  let release, reported =
    Sol_cli_report.collect (fun () ->
      Sol_cli_workload_scope.release_workloads
        ~run
          (* The namespace exists, so the release path under test is the namespaced one. *)
        ~namespace_probe:(fun _ -> Sol_cli_workload_scope.Namespace_exists)
        ~delete:(fun ~namespace:_ ~names ->
          deleted := !deleted @ names;
          Ok ())
        ~wait:(fun ~namespace:_ -> Ok ())
        ~evidence
        ~namespaces:[ "myapp-payments" ]
        ~workspace:"myapp")
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the release completes"
    true
    (match release with
     | Sol_cli_workload_scope.Workloads_released -> true
     | _ -> false);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "the workspace label selects candidates; only the exact recorded UID is deleted, \
       and a CronJob is deleted on the same rule"
    [ "deployment/owned"; "cronjob/owned-cron" ]
    !deleted;
  let text = String.concat "\n" (List.map snd reported) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a label-matched workload whose live UID differs is reported as retained"
    true
    (contains text "deployment/mismatch");
  Windtrap.equal
    Windtrap.bool
    ~msg:"a label-matched workload with no recorded UID is reported as retained"
    true
    (contains text "deployment/no-evidence")
;;

let%test "guard: rollback prunes only on the recorded UID, not the label" =
  test_rollback_prunes_only_label_matched_workloads_with_the_recorded_uid ()
;;

let test_release_with_only_retained_workloads_is_unestablished () =
  let deleted = ref [] in
  let run args =
    match List.nth_opt args 1 with
    | Some "deployment" -> Ok deployment_listing
    | Some ("cronjob" | "job" | "rollout" | "statefulset" | "daemonset") ->
      Ok empty_listing
    | _ -> Ok empty_listing
  in
  let release =
    Sol_cli_workload_scope.release_workloads
      ~run
      ~namespace_probe:(fun _ -> Sol_cli_workload_scope.Namespace_exists)
      ~delete:(fun ~namespace:_ ~names ->
        deleted := !deleted @ names;
        Ok ())
      ~wait:(fun ~namespace:_ -> Ok ())
      ~evidence:[]
      ~namespaces:[ "myapp-payments" ]
      ~workspace:"myapp"
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"live workloads with no recorded UID are not reported as released"
    true
    (match release with
     | Sol_cli_workload_scope.Workloads_unestablished _ -> true
     | Sol_cli_workload_scope.Workloads_released
     | Sol_cli_workload_scope.Workloads_not_releasable _ -> false);
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing is deleted when no live workload matches a recorded UID"
    []
    !deleted
;;

let%test "guard: destroy releases only on the recorded UID, not the workspace label" =
  test_release_deletes_only_label_matched_workloads_with_the_recorded_uid ()
;;

let%test "guard: a release with only unmatched live workloads is unestablished" =
  test_release_with_only_retained_workloads_is_unestablished ()
;;
