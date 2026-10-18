open Sol_cli_destroy_verification
open Sol_cli_destruction
open Sol_cli_terraform_steps
open Result.Syntax

let gcp_desired_guards ~represented ~guarded ~create_database =
  let database_address = "google_sql_database_instance.postgres" in
  let database_represented =
    List.exists
      (fun address -> Sol_cli_terraform_plan.same_resource database_address address)
      represented
  in
  match create_database with
  | Some "false" when not database_represented ->
    List.filter
      (fun address -> not (Sol_cli_terraform_plan.same_resource database_address address))
      guarded
  | Some _ | None -> guarded
;;

let gcp_prepare_destroy_result ~guarded run_log infra_dir var_files vars state
  : unit Sol_cli_cloud_lifecycle.preparation_outcome
  =
  let open Sol_cli_cloud_lifecycle in
  let open Sol_cli_cloud_destroy in
  let failed reason = Preparation_failed { reason; policy = Continue_to_destroy } in
  let report_unrepresented unrepresented =
    match unrepresented with
    | [] -> ()
    | addresses ->
      Sol_cli_report.app
        "  WARNING: %d resource(s) this target declares are ABSENT from its state and \
         will therefore NOT be destroyed: %s\n\
        \  They may still exist in the provider and remain billable (FND-0030)."
        (List.length addresses)
        (String.concat ", " addresses)
  in
  match substrate_presence state with
  | Substrate_unknown ->
    Sol_cli_report.app "  prepare: could not read this target's state; preparing nothing.";
    failed
      "the target's Terraform state could not be read, so no deletion guard could be \
       lowered"
  | Substrate_present | Substrate_absent ->
    let represented = addresses state in
    let desired =
      gcp_desired_guards
        ~represented
        ~guarded
        ~create_database:
          (Sol_cli_terraform_vars.resolved "create_database" ~var_files ~vars)
    in
    report_unrepresented
      (Sol_cli_cloud_lifecycle.preparations_unrepresented ~state:represented ~desired);
    (match Sol_cli_cloud_lifecycle.preparations_eligible ~state:represented ~desired with
     | [] ->
       Sol_cli_report.app
         "  prepare: no guarded resource in this target's state, nothing is targeted.";
       Nothing_to_prepare
     | first :: rest ->
       Sol_cli_report.app
         "  prepare: disabling the deletion guards on %s..."
         (String.concat ", " (first :: rest));
       (match
          apply_asserted
            ~run_log
            ~phase_name:"gcp-destroy-prepare"
            ~policy:(guard_preparation_policy ~addresses:(first :: rest))
            ~scope:(Sol_cli_terraform.targets first rest)
            ~chdir:infra_dir
            ~var_files
            ~vars:
              (vars @ [ "sql_deletion_protection=false"; "gke_deletion_protection=false" ])
            ()
        with
        | Error message -> failed message
        | Ok () -> Prepared ()))
;;

let verify_gcp_preparation_state state =
  let open Sol_cli_cloud_destroy in
  let resource_at expected =
    match find_address state expected with
    | Some resource -> Ok (Some resource)
    | None ->
      (match
         List.find_opt
           (fun (resource : resource) ->
              Sol_cli_terraform_plan.same_resource expected resource.address)
           (resources state)
       with
       | Some resource ->
         Error
           (Printf.sprintf
              "the state represents the guarded resource at %s, not the expected address \
               %s; \n\
              \               the guard cannot be attributed to the resource Terraform \
               will destroy"
              resource.address
              expected)
       | None -> Ok None)
  in
  let* database = resource_at "google_sql_database_instance.postgres[0]" in
  let* cluster = resource_at "google_container_cluster.main" in
  if database = None && cluster = None
  then Error "GCP destroy preparation ran but no guarded resource is in state"
  else
    let* () =
      match database with
      | Some { deletion_protection = Some true; _ } ->
        Error "Cloud SQL deletion protection is still enabled after preparation"
      | Some { deletion_protection = Some false; _ }
      | Some { deletion_protection = None; _ }
      | None -> Ok ()
    in
    let* () =
      match cluster with
      | Some { deletion_protection = Some true; _ } ->
        Error "GKE deletion protection is still enabled after preparation"
      | Some { deletion_protection = Some false; _ }
      | Some { deletion_protection = None; _ }
      | None -> Ok ()
    in
    Sol_cli_report.app
      "  verify preparation: Cloud SQL and GKE deletion protection disabled.";
    Ok ()
;;

let verify_gcp_destroy_preparation_result infra_dir =
  let* state = read_cloud_state infra_dir in
  verify_gcp_preparation_state state
;;

let observe_retention ~retention =
  match retention with
  | Sol_cli_cloud_lifecycle.Retain_nothing ->
    Retention_not_required
      "none declared, and there is no GCP snapshot surface to observe -- Cloud SQL \
       deletes its backups together with the instance (no final backup is requested), \
       and the observability buckets were created with soft delete off (retention 0, \
       INFRA-077), so the verified absence of the instance is the whole guarantee \
       (destroy_retention = none)"
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
    Retention_unknown
      "this destroy reached verification with destroy_retention = final-snapshot on GCP, \
       which cannot retain anything: the block was not applied, so no retention \
       guarantee can be observed"
;;

let prepare { run_log; infra_dir; var_files; vars; _ } ~retention ~cluster_name:_ ~state =
  match retention with
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
    Sol_cli_cloud_lifecycle.Preparation_failed
      { reason =
          "this GCP target's destroy_retention is final-snapshot (the default), but Sol \
           cannot retain anything on GCP yet: Cloud SQL deletes its backups together \
           with the instance, so there is no final-artifact equivalent of the RDS \
           snapshot and the recovery data would be discarded without saying so. Declare \
           `destroy_retention: none` on a disposable target, or export the database \
           first -- Sol will not decide this for you"
      ; policy = Sol_cli_cloud_lifecycle.Block_destroy
      }
  | Sol_cli_cloud_lifecycle.Retain_nothing ->
    (match
       gcp_prepare_destroy_result
         ~guarded:Sol_cli_provider_capabilities.gcp.guarded_addresses
         run_log
         infra_dir
         var_files
         vars
         state
     with
     | Sol_cli_cloud_lifecycle.Prepared () ->
       (match verify_gcp_destroy_preparation_result infra_dir with
        | Ok () ->
          Sol_cli_cloud_lifecycle.Prepared
            (Sol_cli_cloud_destroy.Prepared { retained = None })
        | Error reason ->
          Sol_cli_cloud_lifecycle.Preparation_failed
            { reason; policy = Sol_cli_cloud_lifecycle.Continue_to_destroy })
     | Sol_cli_cloud_lifecycle.Nothing_to_prepare ->
       Sol_cli_cloud_lifecycle.Nothing_to_prepare
     | Sol_cli_cloud_lifecycle.Preparation_failed failure ->
       Sol_cli_cloud_lifecycle.Preparation_failed failure)
;;

let destruction ctx : Sol_cli_destruction.t =
  { prepare = prepare ctx
  ; retention =
      (fun ~retention ~pre_destroy:_ ~preparation:_ -> observe_retention ~retention)
  ; residue =
      (fun ~pre_destroy ~cluster ->
        match
          Sol_cli_destruction.residue_cluster_name
            ~kind:"google_container_cluster"
            ~pre_destroy
            ~cluster
            ~target_cfg:ctx.target
        with
        | Some cluster_name -> Sol_cli_gcp_absence.observations ctx.target ~cluster_name
        | None ->
          Sol_cli_gcp_absence.unresolved
            ~reason:
              "the target's cluster name could not be established from Terraform state, \
               the install outputs or the target's own cluster_name declaration, so the \
               provider could not be listed by identity -- an inventory that did not run \
               cannot establish absence")
  ; before_substrate_destroy = ignore
  }
;;
