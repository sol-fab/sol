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
  let run = prepared.B.run in
  let obligations = prepared.B.obligations in
  if not (D.same_run run (E.run recorder))
  then Error "evidence recorder belongs to another candidate assessment"
  else
    let* requirement = migration_requirement obligations in
    let* application = CA.observe_all ~directory ~run ~obligations ~recorder ~read in
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
            ~run
            ~obligations
            ~recorder
            ~read
            ~execution:(fun _ -> Ok execution))
    in
    match execution with
    | QME.Executed migration -> Ok { application; migration }
    | QME.Skipped reason ->
      Error
        (Printf.sprintf
           "the candidate performed no migration execution (%s); the migration CA family \
            is unestablished"
           reason)
;;
