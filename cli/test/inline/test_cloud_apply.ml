module A = Sol_cli_cloud_apply

type calls =
  { mutable applied_cloud : bool
  ; mutable removals : int
  ; mutable platform_applied : bool
  ; mutable discarded : bool
  ; mutable reports : string list
  ; mutable events : string list
  ; mutable prerequisites_applied : bool
  ; mutable planned : bool
  }

let fresh () =
  { applied_cloud = false
  ; removals = 0
  ; platform_applied = false
  ; discarded = false
  ; reports = []
  ; events = []
  ; prerequisites_applied = false
  ; planned = false
  }
;;

let guarded_kind = "test_guarded_kind"

let deps calls : (unit, unit, unit) A.deps =
  { substrate_exists = (fun () -> Ok true)
  ; plan =
      (fun () ->
        calls.planned <- true;
        Ok [])
  ; guarded_removals = [ guarded_kind ]
  ; confirm_guarded_removal = false
  ; confirmation_flag = "--confirm-test-removal"
  ; apply_plan =
      (fun () ->
        calls.applied_cloud <- true;
        Ok ())
  ; discard_plan = (fun () -> calls.discarded <- true)
  ; outputs = (fun () -> Ok (Some ()))
  ; open_window = (fun () -> Ok (Some ()))
  ; platform_vars = (fun () -> Ok [ "x=1" ])
  ; substrate_supported =
      (fun () ->
        calls.events <- "substrate_supported" :: calls.events;
        Ok ())
  ; cloud_ready =
      (fun () ->
        calls.events <- "cloud_ready" :: calls.events;
        Ok ())
  ; with_cluster_access = (fun () f -> f ())
  ; platform_init = (fun () -> Ok ())
  ; platform_installed = (fun () -> false)
  ; apply_prerequisites =
      (fun () _ ->
        calls.events <- "apply_prerequisites" :: calls.events;
        calls.prerequisites_applied <- true;
        Ok ())
  ; await_crds = (fun () -> true)
  ; verify_platform_prerequisites = (fun () _ -> Ok ())
  ; apply_platform =
      (fun () _ ->
        calls.events <- "apply_platform" :: calls.events;
        calls.platform_applied <- true;
        Ok ())
  ; await_readiness = (fun () -> [ "platform", Sol_cli_cloud_lifecycle.Established ])
  ; remove_bootstrap_access =
      (fun () ->
        calls.removals <- calls.removals + 1;
        Ok ())
  ; verify_deescalation = (fun () _ -> Ok ())
  ; provisioner_effective = (fun () -> true)
  ; report = (fun line -> calls.reports <- line :: calls.reports)
  }
;;

let failed_with = function
  | A.Applied -> Windtrap.fail "expected a failure, the apply succeeded"
  | A.Apply_failed { failure; cleanup } -> A.failure_to_string failure, cleanup
;;

let cleanup_is expected cleanup =
  Windtrap.equal
    Windtrap.bool
    ~msg:"cleanup"
    true
    (match expected, (cleanup : Sol_cli_cloud_destroy.cleanup) with
     | `Not_needed, Cleanup_not_needed | `Succeeded, Cleanup_succeeded -> true
     | `Failed, Cleanup_failed _ -> true
     | _ -> false)
;;

let test_happy_path () =
  let calls = fresh () in
  (match A.execute ~deps:(deps calls) with
   | A.Applied -> ()
   | A.Apply_failed { failure; _ } -> Windtrap.fail (A.failure_to_string failure));
  Windtrap.equal
    Windtrap.int
    ~msg:"the window is removed once, by the sequence"
    1
    calls.removals;
  Windtrap.equal Windtrap.bool ~msg:"the saved plan is discarded" true calls.discarded;
  Windtrap.equal
    Windtrap.bool
    ~msg:"Ready is reported last"
    true
    (List.hd calls.reports = "  lifecycle phase: Ready")
;;

let test_failure_in_window_removes_it () =
  let calls = fresh () in
  let diagnostic = "quotaExceeded: SSD_TOTAL_GB exhausted while provisioning a PVC" in
  let deps =
    { (deps calls) with
      apply_platform = (fun () _ -> Error (A.Terraform_failed diagnostic))
    }
  in
  let message, cleanup = failed_with (A.execute ~deps) in
  Windtrap.equal
    Windtrap.string
    ~msg:"Terraform's allocation diagnostic"
    diagnostic
    message;
  Windtrap.equal
    Windtrap.bool
    ~msg:"allocation failure cannot report Ready"
    false
    (List.mem "  lifecycle phase: Ready" calls.reports);
  cleanup_is `Succeeded cleanup;
  Windtrap.equal Windtrap.int ~msg:"removed exactly once" 1 calls.removals
;;

let test_installed_platform_reenters_as_updating () =
  let calls = fresh () in
  let deps = { (deps calls) with platform_installed = (fun () -> true) } in
  (match A.execute ~deps with
   | A.Applied -> ()
   | A.Apply_failed { failure; _ } -> Windtrap.fail (A.failure_to_string failure));
  Windtrap.equal
    Windtrap.bool
    ~msg:"an installed platform is re-entered as PlatformUpdating"
    true
    (List.mem "  lifecycle phase: PlatformUpdating" calls.reports)
;;

let test_removal_failure_is_not_retried () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      remove_bootstrap_access =
        (fun () ->
          calls.removals <- calls.removals + 1;
          Error (A.Terraform_failed "terraform exited 1."))
    }
  in
  let _, cleanup = failed_with (A.execute ~deps) in
  cleanup_is `Not_needed cleanup;
  Windtrap.equal Windtrap.int ~msg:"the removal is attempted once" 1 calls.removals
;;

let test_failure_after_removal_needs_no_cleanup () =
  let calls = fresh () in
  let deps = { (deps calls) with provisioner_effective = (fun () -> false) } in
  let message, cleanup = failed_with (A.execute ~deps) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"names the provisioner"
    true
    (String.length message > 0 && String.sub message 0 11 = "platform pr");
  cleanup_is `Not_needed cleanup;
  Windtrap.equal Windtrap.int ~msg:"no second removal" 1 calls.removals
;;

let test_cleanup_failure_is_reported () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      cloud_ready = (fun () -> Error "not ready")
    ; remove_bootstrap_access = (fun () -> Error (A.Terraform_failed "exited 1."))
    }
  in
  let message, cleanup = failed_with (A.execute ~deps) in
  Windtrap.equal Windtrap.string ~msg:"the primary failure is kept" "not ready" message;
  cleanup_is `Failed cleanup
;;

let test_guarded_removal_refused_before_apply () =
  let calls = fresh () in
  let change =
    { Sol_cli_terraform_plan.address = "test_guarded_kind.repos[\"a\"]"
    ; resource_type = guarded_kind
    ; mode = "managed"
    ; action = Sol_cli_terraform_plan.Delete
    }
  in
  let deps = { (deps calls) with plan = (fun () -> Ok [ change ]) } in
  let _, cleanup = failed_with (A.execute ~deps) in
  cleanup_is `Not_needed cleanup;
  Windtrap.equal Windtrap.bool ~msg:"nothing was applied" false calls.applied_cloud;
  Windtrap.equal Windtrap.int ~msg:"no window to remove" 0 calls.removals;
  Windtrap.equal Windtrap.bool ~msg:"the plan is still discarded" true calls.discarded;
  let confirmed =
    A.execute
      ~deps:{ deps with confirm_guarded_removal = true; plan = (fun () -> Ok [ change ]) }
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"confirmed, the apply proceeds"
    true
    (match confirmed with
     | A.Applied -> true
     | A.Apply_failed _ -> false)
;;

let test_unguarded_provider_is_unaffected () =
  let calls = fresh () in
  let change =
    { Sol_cli_terraform_plan.address = "other_kind.repos[\"a\"]"
    ; resource_type = "other_kind"
    ; mode = "managed"
    ; action = Sol_cli_terraform_plan.Delete
    }
  in
  let deps =
    { (deps calls) with guarded_removals = []; plan = (fun () -> Ok [ change ]) }
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"a plan removing an unguarded type applies"
    true
    (match A.execute ~deps with
     | A.Applied -> true
     | A.Apply_failed _ -> false);
  Windtrap.equal Windtrap.bool ~msg:"the plan was applied" true calls.applied_cloud
;;

let test_cloud_apply_failure_opens_no_window () =
  let calls = fresh () in
  let deps =
    { (deps calls) with apply_plan = (fun () -> Error (A.Terraform_failed "exited 1.")) }
  in
  let _, cleanup = failed_with (A.execute ~deps) in
  cleanup_is `Not_needed cleanup;
  Windtrap.equal Windtrap.int ~msg:"no removal" 0 calls.removals
;;

let test_unknown_substrate_fails_closed () =
  let calls = fresh () in
  let deps =
    { (deps calls) with substrate_exists = (fun () -> Error "state unreadable") }
  in
  let message, _ = failed_with (A.execute ~deps) in
  Windtrap.equal Windtrap.string ~msg:"the reason" "state unreadable" message;
  Windtrap.equal Windtrap.bool ~msg:"nothing was applied" false calls.applied_cloud
;;

let test_fresh_target_reports_bootstrap () =
  let calls = fresh () in
  let deps = { (deps calls) with substrate_exists = (fun () -> Ok false) } in
  ignore (A.execute ~deps);
  Windtrap.equal
    Windtrap.bool
    ~msg:"CloudBootstrap reported"
    true
    (List.mem "  lifecycle phase: CloudBootstrap" calls.reports)
;;

let test_unsupported_substrate_refuses_before_the_plan () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      substrate_supported =
        (fun () ->
          calls.events <- "substrate_supported" :: calls.events;
          Error (A.Refused Sol_cli_cluster_substrate.support_contract))
    }
  in
  (match A.execute ~deps with
   | A.Applied -> Windtrap.fail "an Autopilot substrate was accepted"
   | A.Apply_failed { failure; _ } ->
     let message = A.failure_to_string failure in
     Windtrap.equal
       Windtrap.bool
       ~msg:"the refusal carries the support contract"
       true
       (Sol_cli_string.contains ~needle:"GKE Autopilot is not supported" message));
  Windtrap.equal Windtrap.bool ~msg:"no plan was ever made" false calls.planned;
  Windtrap.equal Windtrap.bool ~msg:"nothing was applied" false calls.applied_cloud
;;

let test_missing_platform_prerequisite_refuses_before_the_platform () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      verify_platform_prerequisites =
        (fun () _ ->
          calls.events <- "verify_platform_prerequisites" :: calls.events;
          Error
            (A.Refused
               "the platform install cannot start: the operator-supplied Secret \
                redpanda-users is absent from namespace redpanda"))
    }
  in
  let message, cleanup = failed_with (A.execute ~deps) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the refusal names the operator-supplied prerequisite"
    true
    (Sol_cli_string.contains ~needle:"redpanda-users" message);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the platform was never applied on a missing prerequisite"
    false
    calls.platform_applied;
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:
      "the prerequisite check sits between the namespace/RBAC apply and the platform \
       apply"
    [ "substrate_supported"
    ; "cloud_ready"
    ; "apply_prerequisites"
    ; "verify_platform_prerequisites"
    ]
    (List.rev calls.events);
  cleanup_is `Succeeded cleanup
;;

(* Readiness is decided by the typed check outcomes, never by rendering. An
   unobservable check must fail the apply just as a confirmed unmet one does,
   and it must keep the probe's own evidence. *)
let test_unobservable_readiness_refuses () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      await_readiness =
        (fun () ->
          [ "platform", Sol_cli_cloud_lifecycle.Unobservable "kubectl is not installed" ])
    }
  in
  let message, _ = failed_with (A.execute ~deps) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the refusal keeps the probe's evidence"
    true
    (Sol_cli_string.contains ~needle:"kubectl is not installed" message);
  Windtrap.equal
    Windtrap.bool
    ~msg:"the lifecycle never advances to Ready"
    false
    (List.mem "  lifecycle phase: Ready" calls.reports)
;;

let test_confirmed_unmet_readiness_refuses () =
  let calls = fresh () in
  let deps =
    { (deps calls) with
      await_readiness =
        (fun () -> [ "platform", Sol_cli_cloud_lifecycle.Unmet "still installing" ])
    }
  in
  let message, _ = failed_with (A.execute ~deps) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the refusal names the confirmed unmet reason"
    true
    (Sol_cli_string.contains ~needle:"still installing" message)
;;

let%test "execute: happy path" = test_happy_path ()

let%test "execute: an unobservable readiness check refuses" =
  test_unobservable_readiness_refuses ()
;;

let%test "execute: a confirmed unmet readiness check refuses" =
  test_confirmed_unmet_readiness_refuses ()
;;

let%test "execute: failure in the window removes it" =
  test_failure_in_window_removes_it ()
;;

let%test "execute: installed platform re-enters as updating" =
  test_installed_platform_reenters_as_updating ()
;;

let%test "execute: removal failure is not retried" =
  test_removal_failure_is_not_retried ()
;;

let%test "execute: failure after removal needs no cleanup" =
  test_failure_after_removal_needs_no_cleanup ()
;;

let%test "execute: cleanup failure is reported" = test_cleanup_failure_is_reported ()

let%test "execute: guarded removal refused before apply" =
  test_guarded_removal_refused_before_apply ()
;;

let%test "execute: a provider with no guarded removal is unaffected" =
  test_unguarded_provider_is_unaffected ()
;;

let%test "execute: cloud apply failure opens no window" =
  test_cloud_apply_failure_opens_no_window ()
;;

let%test "execute: unknown substrate fails closed" =
  test_unknown_substrate_fails_closed ()
;;

let%test "execute: fresh target reports CloudBootstrap" =
  test_fresh_target_reports_bootstrap ()
;;

let%test "execute: an unsupported substrate refuses before any plan exists" =
  test_unsupported_substrate_refuses_before_the_plan ()
;;

let%test
    "execute: a missing operator-supplied platform credential refuses before the platform"
  =
  test_missing_platform_prerequisite_refuses_before_the_platform ()
;;
