(* One candidate-bound qualification path over the existing owners. *)
open Result.Syntax
module D = Qual_domain
module B = Qual_candidate_obligations
module E = Qual_evidence
module CA = Qual_database_ca
module QME = Qual_migration_execution

type outcomes =
  { application : CA.outcome list
  ; migration : CA.outcome list
  }

(* One locator can describe exactly one migration execution. Multiple migration
   requirements need a per-database execution locator, which this path does not
   invent; refuse rather than reuse one receipt for all of them. *)
let migration_requirement obligations =
  D.instances obligations
  |> List.filter_map (fun instance ->
    match D.plan instance with
    | D.Migration_ca_delivery requirement -> Some requirement
    | _ -> None)
  |> function
  | [ requirement ] -> Ok requirement
  | [] -> Error "the qualification path requires a migration CA obligation"
  | _ -> Error "the qualification path supports exactly one migration execution"
;;

let check_recorder prepared (recorder : E.t) =
  if D.same_run prepared.B.run (E.run recorder)
  then Ok ()
  else Error "evidence recorder belongs to another candidate assessment"
;;

(* Application CA delivery is observed at the point the workloads exist. The live
   row calls this after its final deploy; it is separate from the migration phase
   because the migration Job no longer exists by then. *)
let observe_application ~directory ~prepared ~recorder ~read =
  let* () = check_recorder prepared recorder in
  CA.observe_all
    ~directory
    ~run:prepared.B.run
    ~obligations:prepared.B.obligations
    ~recorder
    ~read
;;

(* The migration phase runs the verified candidate's own `migrate apply` at the
   point the product lifecycle performs it, capturing the actual Job locator and
   observing its CA before the product's cleanup is released. A skip is reported
   as a skip, not inferred as a satisfied execution. *)
let migration
      ~directory
      ~prepared
      ~recorder
      ~read
      ~establish
      ~expected
      ~binding
      ~timeout_s
      ~completion_timeout_s
  =
  let* () = check_recorder prepared recorder in
  let* requirement = migration_requirement prepared.B.obligations in
  let* execution =
    QME.run
      ~verified:prepared.B.verified
      ~expected
      ~binding
      ~timeout_s
      ~completion_timeout_s
      ~establish
      ~consume:(fun locator ->
        let* execution =
          CA.capture_execution
            recorder
            requirement
            ~context:locator.context
            locator.identity
          |> Result.map_error (fun error -> error.E.stage ^ ": " ^ error.E.diagnostic)
        in
        CA.observe_migrations
          ~directory
          ~run:prepared.B.run
          ~obligations:prepared.B.obligations
          ~recorder
          ~read
          ~execution:(fun _ -> Ok execution))
  in
  match execution with
  | QME.Executed outcomes -> Ok outcomes
  | QME.Skipped reason ->
    Error
      (Printf.sprintf
         "the candidate performed no migration execution (%s); the migration CA family \
          is unestablished"
         reason)
;;

(* Offline composition. Live callers use the phases separately at the lifecycle
   points where each observation is valid. *)
let run
      ~directory
      ~prepared
      ~recorder
      ~read
      ~establish
      ~expected
      ~binding
      ~timeout_s
      ~completion_timeout_s
  =
  let* application = observe_application ~directory ~prepared ~recorder ~read in
  let* migration =
    migration
      ~directory
      ~prepared
      ~recorder
      ~read
      ~establish
      ~expected
      ~binding
      ~timeout_s
      ~completion_timeout_s
  in
  Ok { application; migration }
;;
