type lookup_result =
  | Answered of
      { status : int
      ; stdout : string
      ; stderr : string
      }
  | Unavailable of string

type state_evidence =
  | State_absent
  | State_residue of string list
  | State_unreadable of string

let state_evidence = function
  | Ok [] -> State_absent
  | Ok addresses -> State_residue addresses
  | Error reason -> State_unreadable reason
;;

type sweep =
  | Sweep_not_run
  | Sweep_ran of
      { residues : string list
      ; indeterminate : string list
      }

type retention =
  | Retention_required_and_observed of string
  | Retention_not_required of string
  | Retention_violated of string
  | Retention_unknown of string

let retention_to_string = function
  | Retention_required_and_observed evidence -> "observed: " ^ evidence
  | Retention_not_required reason -> "not required: " ^ reason
  | Retention_violated reason -> "violated: " ^ reason
  | Retention_unknown reason -> "unknown: " ^ reason
;;

type observation =
  { state : state_evidence
  ; sweep : sweep
  ; retention : retention
  }

type verdict =
  { violations : string list
  ; unknowns : string list
  }

let is_verified verdict = verdict.violations = [] && verdict.unknowns = []

let verdict_message verdict =
  let join = String.concat "; " in
  match verdict.violations, verdict.unknowns with
  | [], [] -> "the destruction postcondition is established"
  | violations, [] ->
    Printf.sprintf "the destruction postcondition is violated: %s" (join violations)
  | [], unknowns ->
    Printf.sprintf
      "the destruction postcondition could not be established (UNKNOWN is not absence): \
       %s"
      (join unknowns)
  | violations, unknowns ->
    Printf.sprintf
      "the destruction postcondition is violated (%s), and could not be established for \
       (%s)"
      (join violations)
      (join unknowns)
;;

let classify observation =
  let violations = ref [] in
  let unknowns = ref [] in
  let violate message = violations := message :: !violations in
  let unknown message = unknowns := message :: !unknowns in
  (match observation.state with
   | State_absent -> ()
   | State_residue addresses ->
     addresses
     |> List.iter (fun address ->
       violate
         (Printf.sprintf
            "Terraform still represents %s in this root's state after destroy"
            address))
   | State_unreadable reason ->
     unknown
       (Printf.sprintf
          "this root's Terraform state could not be read after destroy (%s), so what it \
           still represents is unknown"
          reason));
  (match observation.sweep with
   | Sweep_not_run -> unknown "the residue inventory did not run"
   | Sweep_ran { residues; indeterminate } ->
     List.iter violate residues;
     List.iter unknown indeterminate);
  (match observation.retention with
   | Retention_required_and_observed _ | Retention_not_required _ -> ()
   | Retention_violated reason -> violate reason
   | Retention_unknown reason -> unknown reason);
  { violations = List.rev !violations; unknowns = List.rev !unknowns }
;;

let report observation =
  let buffer = Buffer.create 1024 in
  let line format = Printf.ksprintf (Buffer.add_string buffer) format in
  line "  verification: evidence, not `terraform destroy`'s exit status\n";
  (match observation.state with
   | State_absent ->
     line
       "    terraform state (disposable root): empty -- Terraform destroyed every \
        resource it manages (DEC-045: Terraform's destroy is the authority for them)\n"
   | State_residue addresses ->
     line
       "    terraform state (disposable root): STILL REPRESENTS %s\n"
       (String.concat ", " addresses)
   | State_unreadable reason ->
     line
       "    terraform state (disposable root): UNKNOWN -- the read failed (%s), which is \
        not absence\n"
       reason);
  (match observation.sweep with
   | Sweep_not_run -> line "    residue: UNKNOWN -- the residue inventory did not run\n"
   | Sweep_ran { residues = []; indeterminate = [] } ->
     line
       "    residue Terraform does not own (controller load balancers, PVC volumes, \
        abandoned peering): none found\n"
   | Sweep_ran { residues; indeterminate } ->
     List.iter (fun reason -> line "    residue: %s\n" reason) residues;
     indeterminate
     |> List.iter (fun reason ->
       line
         "    residue check inconclusive -- %s (an observation that did not run does not \
          establish residue absence, and is never read as one)\n"
         reason));
  (match observation.retention with
   | Retention_required_and_observed evidence -> line "    retention: %s\n" evidence
   | Retention_not_required reason -> line "    retention: %s\n" reason
   | Retention_violated reason -> line "    retention: %s\n" reason
   | Retention_unknown reason -> line "    retention: %s\n" reason);
  Buffer.contents buffer
;;
