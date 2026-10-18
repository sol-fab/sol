type failure =
  | Terraform_failed of string
  | Refused of string

type outcome =
  | Applied
  | Apply_failed of
      { failure : failure
      ; cleanup : Sol_cli_cloud_destroy.cleanup
      }

type ('outputs, 'env, 'control) deps =
  { substrate_exists : unit -> (bool, string) result
  ; substrate_supported : unit -> (unit, failure) result
  ; plan : unit -> (Sol_cli_terraform_plan.change list, failure) result
  ; guarded_removals : string list
  ; confirm_guarded_removal : bool
  ; confirmation_flag : string
  ; apply_plan : unit -> (unit, failure) result
  ; discard_plan : unit -> unit
  ; outputs : unit -> ('outputs option, string) result
  ; open_window : 'outputs -> ('control option, string) result
  ; platform_vars : 'outputs -> (string list, string) result
  ; cloud_ready : 'outputs -> (unit, string) result
  ; with_cluster_access :
      'outputs -> ('env -> (unit, failure) result) -> (unit, failure) result
  ; platform_init : unit -> (unit, failure) result
  ; platform_installed : 'env -> bool
  ; apply_prerequisites : 'env -> string list -> (unit, failure) result
  ; await_crds : 'env -> bool
  ; verify_platform_prerequisites : 'env -> string list -> (unit, failure) result
  ; apply_platform : 'env -> string list -> (unit, failure) result
  ; await_readiness : 'env -> (string * Sol_cli_cloud_lifecycle.readiness) list
  ; remove_bootstrap_access : unit -> (unit, failure) result
  ; verify_deescalation : 'outputs -> 'control option -> (unit, string) result
  ; provisioner_effective : 'env -> bool
  ; report : string -> unit
  }

let failure_to_string = function
  | Terraform_failed message | Refused message -> message
;;

let refused result = Result.map_error (fun message -> Refused message) result

open Result.Syntax

let report_phase deps phase =
  deps.report
    (Printf.sprintf
       "  lifecycle phase: %s"
       (Sol_cli_cloud_lifecycle.phase_to_string phase))
;;

let check_guarded_removals deps changes =
  let removed =
    deps.guarded_removals
    |> List.concat_map (fun resource_type ->
      Sol_cli_terraform_plan.removed_of_type ~resource_type changes)
  in
  match removed with
  | [] -> Ok ()
  | removed when deps.confirm_guarded_removal ->
    deps.report
      (Printf.sprintf
         "  guarded removal: deleting %s (confirmed with %s)"
         (String.concat ", " removed)
         deps.confirmation_flag);
    Ok ()
  | removed ->
    Error
      (Refused
         (Printf.sprintf
            "this apply would delete %s and everything in them.\n\
            \  Sol refuses to remove what a re-apply cannot restore unless the removal \
             is intended: run from the checkout that deploys this target, or pass %s. \
             Nothing was changed."
            (String.concat ", " removed)
            deps.confirmation_flag))
;;

let operation_phase observed =
  match (observed : Sol_cli_cloud_lifecycle.phase) with
  | Ready -> Sol_cli_cloud_lifecycle.enter ~from:Ready ~to_:Platform_updating |> refused
  | Absent | Platform_installing -> Ok Sol_cli_cloud_lifecycle.Platform_installing
  | (Cloud_bootstrap | Platform_updating | Preparing_destroy | Destroying) as other ->
    Error
      (Refused
         (Printf.sprintf
            "refusing to apply from observed lifecycle phase %s"
            (Sol_cli_cloud_lifecycle.phase_to_string other)))
;;

let install_platform deps ~closing =
  let* outputs =
    match deps.outputs () with
    | Ok (Some outputs) -> Ok outputs
    | Ok None -> Error (Refused "Terraform apply completed without lifecycle outputs")
    | Error message -> Error (Refused message)
  in
  let* platform_vars = deps.platform_vars outputs |> refused in
  let* () = deps.cloud_ready outputs |> refused in
  let* control = deps.open_window outputs |> refused in
  (match control with
   | Some _ -> ()
   | None -> deps.report "  bootstrap window control: not captured");
  deps.with_cluster_access outputs (fun env ->
    let* () = deps.platform_init () in
    let observed =
      Sol_cli_cloud_lifecycle.observed_phase
        ~cloud_exists:true
        ~platform_installed:(deps.platform_installed env)
    in
    let* phase = operation_phase observed in
    report_phase deps phase;
    let* () = deps.apply_prerequisites env platform_vars in
    let* () =
      if deps.await_crds env
      then Ok ()
      else Error (Refused "cert-manager CRDs did not become Established")
    in
    let* () = deps.verify_platform_prerequisites env platform_vars in
    let* () = deps.apply_platform env platform_vars in
    let* () =
      Sol_cli_cloud_lifecycle.readiness_decision (deps.await_readiness env)
      |> Result.map_error (fun summary -> Refused ("platform readiness " ^ summary))
    in
    closing := true;
    let* () = deps.remove_bootstrap_access () in
    let* () = deps.verify_deescalation outputs control |> refused in
    let* _ =
      Sol_cli_cloud_lifecycle.enter ~from:phase ~to_:Sol_cli_cloud_lifecycle.Ready
      |> refused
    in
    let* () =
      if deps.provisioner_effective env
      then Ok ()
      else
        Error
          (Refused
             "platform provisioner RBAC is not effective after bootstrap access removal")
    in
    report_phase deps Sol_cli_cloud_lifecycle.Ready;
    Ok ())
;;

let execute ~deps =
  let cloud_stage () =
    let* exists = deps.substrate_exists () |> refused in
    if not exists then report_phase deps Sol_cli_cloud_lifecycle.Cloud_bootstrap;
    let* () = deps.substrate_supported () in
    let* changes = deps.plan () in
    let* () = check_guarded_removals deps changes in
    deps.apply_plan ()
  in
  match Fun.protect ~finally:deps.discard_plan cloud_stage with
  | Error failure -> Apply_failed { failure; cleanup = Cleanup_not_needed }
  | Ok () ->
    let closing = ref false in
    (match install_platform deps ~closing with
     | Ok () -> Applied
     | Error failure when !closing ->
       Apply_failed { failure; cleanup = Cleanup_not_needed }
     | Error failure ->
       let cleanup =
         match deps.remove_bootstrap_access () with
         | Ok () -> Sol_cli_cloud_destroy.Cleanup_succeeded
         | Error removal -> Cleanup_failed (failure_to_string removal)
       in
       Apply_failed { failure; cleanup })
;;
