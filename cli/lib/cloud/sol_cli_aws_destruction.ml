open Sol_cli_destroy_verification
open Sol_cli_destruction
open Sol_cli_terraform_steps
open Result.Syntax

type retention_probe =
  | Settled of retention
  | Pending of string

let final_snapshot_query ~snapshot_id ~region =
  [ "aws"
  ; "rds"
  ; "describe-db-snapshots"
  ; "--db-snapshot-identifier"
  ; snapshot_id
  ; "--region"
  ; region
  ; "--output"
  ; "json"
  ]
;;

let instance_snapshots_query ~instance ~region =
  [ "aws"
  ; "rds"
  ; "describe-db-snapshots"
  ; "--db-instance-identifier"
  ; instance
  ; "--region"
  ; region
  ; "--output"
  ; "json"
  ]
;;

let snapshots_of_json stdout =
  let text key item = Sol_cli_json.field [ key ] item |> Sol_cli_json.string in
  match Yojson.Safe.from_string stdout with
  | exception Yojson.Json_error message ->
    Error ("the provider's answer is not JSON: " ^ message)
  | `Assoc _ as document ->
    (match Sol_cli_json.field [ "DBSnapshots" ] document with
     | `List items ->
       Ok
         (items
          |> List.map (fun item ->
            text "DBSnapshotIdentifier" item, text "SnapshotType" item, text "Status" item)
         )
     | _ -> Error "the provider's answer carries no `DBSnapshots` array")
  | _ -> Error "the provider's answer is not a JSON object"
;;

let transient_snapshot_status = function
  | "creating" | "pending" | "starting" -> true
  | _ -> false
;;

let snapshot_label (id, kind, _) =
  Printf.sprintf
    "%s%s"
    (Option.value id ~default:"<unnamed>")
    (match kind with
     | Some kind -> " (" ^ kind ^ ")"
     | None -> "")
;;

let classify_final_snapshot ~declared ~snapshot_id lookup =
  let policy = Sol_cli_cloud_lifecycle.destroy_retention_to_string declared in
  match lookup with
  | Unavailable reason ->
    Settled
      (Retention_unknown
         (Printf.sprintf "final snapshot %s could not be queried: %s" snapshot_id reason))
  | Answered { status = 0; stdout; _ } ->
    (match snapshots_of_json stdout with
     | Error message ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the provider's record for final snapshot %s could not be read: %s"
               snapshot_id
               message))
     | Ok snapshots ->
       (match List.find_opt (fun (id, _, _) -> id = Some snapshot_id) snapshots with
        | None ->
          Settled
            (Retention_violated
               (Printf.sprintf
                  "final-snapshot NOT observed (destroy_retention = %s): the provider's \
                   answer contains no snapshot %s%s"
                  policy
                  snapshot_id
                  (match snapshots with
                   | [] -> ""
                   | _ ->
                     " (it reported "
                     ^ String.concat ", " (List.map snapshot_label snapshots)
                     ^ ")")))
        | Some (_, _, Some "available") ->
          Settled
            (Retention_required_and_observed
               (Printf.sprintf
                  "final snapshot %s observed available (destroy_retention = %s, so the \
                   target outlives its compute; remove it with `aws rds \
                   delete-db-snapshot --db-snapshot-identifier %s` once it is no longer \
                   needed)"
                  snapshot_id
                  policy
                  snapshot_id))
        | Some (_, _, Some status) when transient_snapshot_status status ->
          Pending
            (Printf.sprintf
               "final snapshot %s exists and the provider reports it %s"
               snapshot_id
               status)
        | Some (_, _, Some status) ->
          Settled
            (Retention_violated
               (Printf.sprintf
                  "final-snapshot NOT observed (destroy_retention = %s): the provider \
                   reports snapshot %s as %s, which is not available"
                  policy
                  snapshot_id
                  status))
        | Some (_, _, None) ->
          Settled
            (Retention_unknown
               (Printf.sprintf
                  "the provider's record for final snapshot %s carries no status, so \
                   availability is not established"
                  snapshot_id))))
  | Answered { status; stderr; _ } ->
    (match Sol_cli_aws.error_code stderr with
     | Some "DBSnapshotNotFound" ->
       Settled
         (Retention_violated
            (Printf.sprintf
               "final-snapshot NOT observed (destroy_retention = %s): the target \
                declared it keeps its final snapshot, and the provider explicitly \
                reports that %s does not exist"
               policy
               snapshot_id))
     | Some code ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the final snapshot query failed (%s, exit %d), so the retention \
                guarantee is not established: %s"
               code
               status
               (abbreviate stderr)))
     | None ->
       Settled
         (Retention_unknown
            (Printf.sprintf
               "the final snapshot query failed with exit %d and no provider error code, \
                so the retention guarantee is not established: %s"
               status
               (abbreviate stderr))))
;;

let classify_instance_snapshots lookup =
  match lookup with
  | Unavailable reason ->
    Retention_unknown
      (Printf.sprintf
         "no-residue could not be observed: the snapshot query could not be run: %s"
         reason)
  | Answered { status = 0; stdout; _ } ->
    (match snapshots_of_json stdout with
     | Error message ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the provider's answer could not be read: \
             %s"
            message)
     | Ok [] ->
       Retention_required_and_observed
         "none observed (destroy_retention = none): the provider returns no manual or \
          automated snapshot for this target's database"
     | Ok snapshots ->
       Retention_violated
         (Printf.sprintf
            "retain-nothing NOT observed (destroy_retention = none): %d snapshot(s) \
             attributable to this destruction remain: %s"
            (List.length snapshots)
            (String.concat ", " (List.map snapshot_label snapshots))))
  | Answered { status; stderr; _ } ->
    (match Sol_cli_aws.error_code stderr with
     | Some ("DBInstanceNotFound" | "InvalidDBInstanceId.NotFound") ->
       Retention_required_and_observed
         "none observed (destroy_retention = none): the provider reports no such \
          database instance, so no snapshot of it is retained"
     | Some code ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the snapshot query failed (%s, exit %d): \
             %s"
            code
            status
            (abbreviate stderr))
     | None ->
       Retention_unknown
         (Printf.sprintf
            "no-residue could not be observed: the snapshot query failed with exit %d \
             and no provider error code: %s"
            status
            (abbreviate stderr)))
;;

let load_balancers_gone ~region ~cluster_name =
  let tag_key = Printf.sprintf "kubernetes.io/cluster/%s" cluster_name in
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "aws"
         ; "resourcegroupstaggingapi"
         ; "get-resources"
         ; "--resource-type-filters"
         ; "elasticloadbalancing"
         ; "--tag-filters"
         ; Printf.sprintf "Key=%s" tag_key
         ; "--query"
         ; "ResourceTagMappingList[].ResourceARN"
         ; "--output"
         ; "text"
         ; "--region"
         ; region
         ])
  with
  | Ok r -> Some (String.trim r.stdout = "")
  | _ -> None
;;

let rec wait_for_load_balancers_gone ~region ~cluster_name attempts =
  if attempts = 0
  then
    Sol_cli_report.app
      "  (warning: load balancer(s) may still be deprovisioning; proceeding to cloud \
       destroy and retaining the final absence check)"
  else (
    match load_balancers_gone ~region ~cluster_name with
    | Some true -> ()
    | Some false | None ->
      Unix.sleepf 5.;
      wait_for_load_balancers_gone ~region ~cluster_name (attempts - 1))
;;

let final_snapshot_attempts = 12

let final_snapshot_interval_s () =
  Sol_cli_duration.env_seconds ~name:"SOL_DESTROY_SNAPSHOT_INTERVAL_S" ~default:10.
;;

let rec observe_final_snapshot ~interval ~declared ~snapshot_id ~region ~attempts =
  let lookup = run_provider_query (final_snapshot_query ~snapshot_id ~region) in
  match classify_final_snapshot ~declared ~snapshot_id lookup with
  | Settled retention -> retention
  | Pending message ->
    if attempts <= 0
    then
      Sol_cli_destroy_verification.Retention_unknown
        (Printf.sprintf
           "%s; the retention guarantee is not established while it has not reached \
            available"
           message)
    else (
      Unix.sleepf interval;
      observe_final_snapshot
        ~interval
        ~declared
        ~snapshot_id
        ~region
        ~attempts:(attempts - 1))
;;

let rds_target = Sol_cli_terraform.targets "aws_db_instance.postgres" []
let rds_address = "aws_db_instance.postgres[0]"

let unique_rds_snapshot_id cluster_name =
  Printf.sprintf
    "%s-postgres-final-%d"
    cluster_name
    (int_of_float (Unix.gettimeofday () *. 1000.))
;;

let rds_of_state state =
  let open Sol_cli_cloud_destroy in
  match find_address state rds_address with
  | Some resource when resource.kind = "aws_db_instance" ->
    (match resource.deletion_protection with
     | Some deletion_protection ->
       Ok
         (Some
            ( deletion_protection
            , resource.final_snapshot_identifier
            , resource.skip_final_snapshot ))
     | None -> Error "RDS deletion_protection is absent from its state representation")
  | Some resource ->
    Error
      (Printf.sprintf
         "address %s is a %s, not an aws_db_instance"
         rds_address
         resource.kind)
  | None ->
    (match substrate_presence state with
     | Substrate_unknown -> Error "could not read this target's state"
     | Substrate_absent -> Ok None
     | Substrate_present ->
       (match
          List.find_opt
            (fun (resource : Sol_cli_cloud_destroy.resource) ->
               String.equal resource.kind "aws_db_instance")
            (Sol_cli_cloud_destroy.resources state)
        with
        | Some resource ->
          Error
            (Printf.sprintf
               "the state represents an aws_db_instance at %s, but this target's counted \
                database address is %s"
               resource.address
               rds_address)
        | None -> Ok None))
;;

let aws_preparation_policy ~retention =
  match retention with
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot -> Sol_cli_cloud_lifecycle.Block_destroy
  | Sol_cli_cloud_lifecycle.Retain_nothing -> Sol_cli_cloud_lifecycle.Continue_to_destroy
;;

let aws_preparation_reason ~retention reason =
  match retention with
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
    Printf.sprintf
      "the target's destroy_retention is final-snapshot, so its declared retention \
       guarantee could not be established before destroying: %s"
      reason
  | Sol_cli_cloud_lifecycle.Retain_nothing -> reason
;;

let prepare_destroy_result run_log infra_dir var_files vars ~cluster_name ~retention state
  : string Sol_cli_cloud_lifecycle.preparation_outcome
  =
  let failed reason =
    Sol_cli_cloud_lifecycle.Preparation_failed
      { reason = aws_preparation_reason ~retention reason
      ; policy = aws_preparation_policy ~retention
      }
  in
  match rds_of_state state with
  | Error message -> failed message
  | Ok None ->
    Sol_cli_report.app "  prepare: no RDS instance for this target, nothing to prepare.";
    Sol_cli_cloud_lifecycle.Nothing_to_prepare
  | Ok (Some _) ->
    let snapshot_id = unique_rds_snapshot_id cluster_name in
    Sol_cli_report.app
      "  prepare: disabling RDS deletion protection%s..."
      (match retention with
       | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
         ", final snapshot " ^ snapshot_id
       | Sol_cli_cloud_lifecycle.Retain_nothing -> ", retaining nothing");
    (match
       apply_asserted
         ~run_log
         ~phase_name:"rds-destroy-prepare"
         ~policy:
           (Sol_cli_cloud_destroy.guard_preparation_policy
              ~addresses:[ "aws_db_instance.postgres" ])
         ~scope:rds_target
         ~chdir:infra_dir
         ~var_files
         ~vars:
           (vars
            @ [ "rds_deletion_protection=false" ]
            @
            match retention with
            | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
              [ "rds_skip_final_snapshot=false"
              ; "rds_final_snapshot_identifier=" ^ snapshot_id
              ]
            | Sol_cli_cloud_lifecycle.Retain_nothing -> [ "rds_skip_final_snapshot=true" ]
           )
         ()
     with
     | Error message -> failed message
     | Ok () -> Sol_cli_cloud_lifecycle.Prepared snapshot_id)
;;

let verify_destroy_preparation_result infra_dir ~retention ~prepared =
  match prepared with
  | None ->
    Sol_cli_report.app "  verify preparation: nothing was prepared.";
    Ok ()
  | Some snapshot_id ->
    let* state = read_cloud_state infra_dir in
    let* rds = rds_of_state state in
    (match rds with
     | None ->
       Error "RDS destroy preparation ran but the instance is now absent from state"
     | Some (deletion_protection, final_snapshot_identifier, skip_final_snapshot) ->
       let* () =
         if deletion_protection
         then Error "RDS deletion protection is still enabled after preparation"
         else Ok ()
       in
       let* () =
         match retention with
         | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
           let* () =
             match skip_final_snapshot with
             | Some true ->
               Error
                 "the target retains its final snapshot, but preparation disabled \
                  snapshot creation"
             | None ->
               Error
                 "cannot establish that the final snapshot will be retained: \
                  skip_final_snapshot is absent from state"
             | Some false -> Ok ()
           in
           if final_snapshot_identifier <> Some snapshot_id
           then
             Error
               (Printf.sprintf
                  "RDS final snapshot identifier is %s, expected the prepared %s"
                  (Option.value final_snapshot_identifier ~default:"<none>")
                  snapshot_id)
           else Ok ()
         | Sol_cli_cloud_lifecycle.Retain_nothing ->
           (match skip_final_snapshot with
            | Some true -> Ok ()
            | Some false ->
              Error
                "the target retains nothing, but preparation left snapshot creation \
                 enabled"
            | None ->
              Error
                "cannot establish that snapshot creation is disabled: \
                 skip_final_snapshot is absent from state")
       in
       Sol_cli_report.app
         "  verify preparation: RDS deletion protection disabled, final snapshot %s \
          (target destroy_retention = %s)"
         (match retention with
          | Sol_cli_cloud_lifecycle.Retain_final_snapshot -> snapshot_id ^ " confirmed"
          | Sol_cli_cloud_lifecycle.Retain_nothing ->
            Printf.sprintf
              "skipped (skip_final_snapshot=%s)"
              (match skip_final_snapshot with
               | Some value -> string_of_bool value
               | None -> "absent"))
         (Sol_cli_cloud_lifecycle.destroy_retention_to_string retention);
       Ok ())
;;

let observe_retention ~region ~retention ~pre_destroy ~preparation =
  let database =
    Sol_cli_cloud_destroy.resources pre_destroy
    |> List.find_opt (fun (resource : Sol_cli_cloud_destroy.resource) ->
      String.equal resource.kind "aws_db_instance")
  in
  match preparation with
  | Sol_cli_cloud_destroy.Nothing_prepared ->
    Retention_not_required
      "nothing to decide -- this target had no database whose retention a destroy had to \
       settle"
  | Sol_cli_cloud_destroy.Prepared { retained = None } ->
    Retention_unknown
      "an AWS destroy reported a preparation with no snapshot identity, so there is no \
       retention identity to observe"
  | Sol_cli_cloud_destroy.Prepared { retained = Some snapshot_id } ->
    (match retention with
     | Sol_cli_cloud_lifecycle.Retain_final_snapshot ->
       (match final_snapshot_interval_s () with
        | Ok interval ->
          observe_final_snapshot
            ~interval
            ~declared:retention
            ~snapshot_id
            ~region
            ~attempts:final_snapshot_attempts
        | Error reason -> Retention_unknown reason)
     | Sol_cli_cloud_lifecycle.Retain_nothing ->
       (match database with
        | None ->
          Retention_not_required
            "nothing to decide -- this target had no database whose retention a destroy \
             had to settle"
        | Some database ->
          (match database.identifier with
           | Some instance ->
             classify_instance_snapshots
               (run_provider_query (instance_snapshots_query ~instance ~region))
           | None ->
             Retention_unknown
               "no-residue could not be observed: Terraform state records no database \
                identifier")))
;;

let prepare { run_log; infra_dir; var_files; vars; _ } ~retention ~cluster_name ~state =
  match retention, final_snapshot_interval_s () with
  | Sol_cli_cloud_lifecycle.Retain_final_snapshot, Error reason ->
    Sol_cli_cloud_lifecycle.Preparation_failed
      { reason; policy = Sol_cli_cloud_lifecycle.Block_destroy }
  | _ ->
    (match
       prepare_destroy_result
         run_log
         infra_dir
         var_files
         vars
         ~cluster_name
         ~retention
         state
     with
     | Sol_cli_cloud_lifecycle.Prepared snapshot_id ->
       (match
          verify_destroy_preparation_result
            infra_dir
            ~retention
            ~prepared:(Some snapshot_id)
        with
        | Ok () ->
          Sol_cli_cloud_lifecycle.Prepared
            (Sol_cli_cloud_destroy.Prepared { retained = Some snapshot_id })
        | Error reason ->
          Sol_cli_cloud_lifecycle.Preparation_failed
            { reason = aws_preparation_reason ~retention reason
            ; policy = aws_preparation_policy ~retention
            })
     | Sol_cli_cloud_lifecycle.Nothing_to_prepare ->
       Sol_cli_cloud_lifecycle.Nothing_to_prepare
     | Sol_cli_cloud_lifecycle.Preparation_failed failure ->
       Sol_cli_cloud_lifecycle.Preparation_failed failure)
;;

let before_substrate_destroy ctx () =
  ctx.resolved_var "cluster_name"
  |> Option.iter (fun cluster_name ->
    let region = Option.value (ctx.resolved_var "region") ~default:"us-east-1" in
    wait_for_load_balancers_gone ~region ~cluster_name 24)
;;

let destruction ctx : Sol_cli_destruction.t =
  { prepare = prepare ctx
  ; retention =
      (fun ~retention ~pre_destroy ~preparation ->
        observe_retention ~region:ctx.target.region ~retention ~pre_destroy ~preparation)
  ; residue =
      (fun
        ?(previously_attributed = [])
        ?(authorization_identities = [])
        ~pre_destroy
        ~cluster
        ()
       ->
        match
          Sol_cli_destruction.residue_cluster_name
            ~kind:"aws_eks_cluster"
            ~pre_destroy
            ~cluster
            ~target_cfg:ctx.target
        with
        | Some cluster_name ->
          Sol_cli_aws_absence.observations
            ~previously_attributed
            ~pre_destroy
            ~authorization_identities
            ctx.target
            ~cluster_name
        | None ->
          Sol_cli_aws_absence.unresolved
            ~reason:
              "the target's cluster name could not be established from Terraform state, \
               the install outputs or the target's own cluster_name declaration, so the \
               provider could not be listed by identity -- an inventory that did not run \
               cannot establish absence")
  ; before_substrate_destroy = before_substrate_destroy ctx
  }
;;
