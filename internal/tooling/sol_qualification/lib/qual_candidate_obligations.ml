open Result.Syntax
module D = Qual_domain
module E = Qual_evidence

type t =
  { verified : Qual_candidate.t
  ; run : D.run
  ; intent : D.intent
  ; obligations : D.obligations
  ; requests : D.request list
  ; required_captures : (string * string) list
  }

let verified t = t.verified

let binding_id run =
  "candidate-contract/" ^ D.sha256 (Yojson.Safe.to_string (D.run_json run))
;;

let binding_subject = "candidate-contract"

let prepare ~verified ~scenario ~attempt ~assessment ~kubernetes =
  let* run, intent =
    D.bind_candidate ~scenario ~attempt ~assessment ~kubernetes verified
  in
  let* selection = D.select run intent in
  let* obligations = D.bind_obligations run scenario selection in
  let requests = List.map D.plan (D.instances obligations) in
  let* () = D.reconcile_plan obligations requests in
  Ok
    { verified
    ; run
    ; intent
    ; obligations
    ; requests
    ; required_captures = [ binding_id run, binding_subject ]
    }
;;

let capture_binding prepared recorder =
  if not (D.same_run prepared.run (E.run recorder))
  then
    Error
      { E.stage = "candidate binding"
      ; diagnostic = "recorder belongs to another candidate assessment"
      }
  else
    E.capture_required
      recorder
      ~id:(binding_id prepared.run)
      ~subject:binding_subject
      ~payload:(D.run_json prepared.run)
;;
