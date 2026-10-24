type phase =
  | Prepare
  | Cloud
  | Transport
  | App
  | Destroy
  | Verify
  | Inventory
  | Resume

let string_of_phase = function
  | Prepare -> "prepare"
  | Cloud -> "cloud"
  | Transport -> "transport"
  | App -> "app"
  | Destroy -> "destroy"
  | Verify -> "verify"
  | Inventory -> "inventory"
  | Resume -> "resume"
;;

let phase_of_string = function
  | "prepare" -> Ok Prepare
  | "cloud" -> Ok Cloud
  | "transport" -> Ok Transport
  | "app" -> Ok App
  | "destroy" -> Ok Destroy
  | "verify" -> Ok Verify
  | "inventory" -> Ok Inventory
  | "resume" -> Ok Resume
  | value -> Error (Printf.sprintf "unknown qualification phase %S" value)
;;

type verdict =
  { phase : phase
  ; exit_code : int
  ; at : string option
  }

type provenance =
  { attempt : string
  ; claim : string
  ; issuer : string
  ; resumed_from : string option
  ; promotion_eligible : bool
  }

type t =
  { provenance : provenance
  ; verdicts : verdict list
  }

type continuity =
  | Continuous
  | Resumed of string

type reason =
  | Missing_phase of phase
  | Failed_phase of phase
  | Repeated_phase of phase
  | Not_promotion_eligible of string
  | Resumed_attempt of string

let string_of_reason = function
  | Missing_phase phase -> Printf.sprintf "missing phase %s" (string_of_phase phase)
  | Failed_phase phase -> Printf.sprintf "phase %s failed" (string_of_phase phase)
  | Repeated_phase phase ->
    Printf.sprintf "phase %s has more than one verdict" (string_of_phase phase)
  | Not_promotion_eligible detail -> "attempt is not promotion-eligible: " ^ detail
  | Resumed_attempt source -> "attempt is a diagnostic resume of " ^ source
;;

let required_phases = [ Prepare; Cloud; App; Destroy ]

let read_lines path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () ->
       let rec loop acc =
         match input_line input with
         | line -> loop (line :: acc)
         | exception End_of_file -> List.rev acc
       in
       loop [])
;;

let nonempty_lines path =
  read_lines path |> List.map String.trim |> List.filter (fun line -> line <> "")
;;

let split_field line =
  match String.index_opt line '=' with
  | None -> Error (Printf.sprintf "malformed line %S" line)
  | Some index ->
    let key = String.sub line 0 index |> String.trim in
    let value =
      String.sub line (index + 1) (String.length line - index - 1) |> String.trim
    in
    if key = "" then Error (Printf.sprintf "malformed line %S" line) else Ok (key, value)
;;

let fields line = String.split_on_char ' ' line |> List.filter (fun field -> field <> "")

let parse_verdict line =
  let parsed =
    List.fold_left
      (fun state field ->
         match state, split_field field with
         | Error message, _ -> Error message
         | Ok _, Error message -> Error message
         | Ok parsed, Ok (key, value) ->
           (match key with
            | "phase" | "exit" | "at" ->
              if List.mem_assoc key parsed
              then Error (Printf.sprintf "verdict line %S repeats the %s field" line key)
              else Ok ((key, value) :: parsed)
            | _ ->
              Error (Printf.sprintf "verdict line %S has an unknown field %s" line key)))
      (Ok [])
      (fields line)
  in
  let ( let* ) result next =
    match result with
    | Ok value -> next value
    | Error _ as error -> error
  in
  let* parsed = parsed in
  let find key =
    match List.assoc_opt key parsed with
    | Some value -> Ok value
    | None -> Error (Printf.sprintf "verdict line %S has no %s field" line key)
  in
  match find "phase" with
  | Error message -> Error message
  | Ok phase_name ->
    (match phase_of_string phase_name with
     | Error message -> Error message
     | Ok phase ->
       (match find "exit" with
        | Error message -> Error message
        | Ok exit_value ->
          (match int_of_string_opt exit_value with
           | None -> Error (Printf.sprintf "verdict line %S has a non-integer exit" line)
           | Some exit_code ->
             let at = List.assoc_opt "at" parsed in
             Ok { phase; exit_code; at })))
;;

let unique_field key lines =
  let values =
    List.filter_map
      (fun line ->
         match split_field line with
         | Ok (candidate, value) when candidate = key -> Some value
         | _ -> None)
      lines
  in
  match values with
  | [] -> Ok None
  | [ value ] -> Ok (Some value)
  | _ -> Error (Printf.sprintf "attempt identity repeats the %s field" key)
;;

let require_field key lines =
  let ( let* ) result next =
    match result with
    | Ok value -> next value
    | Error _ as error -> error
  in
  let* value = unique_field key lines in
  match value with
  | Some value when value <> "" -> Ok value
  | _ -> Error (Printf.sprintf "attempt identity has no %s field" key)
;;

let parse_promotion_eligible lines =
  let ( let* ) result next =
    match result with
    | Ok value -> next value
    | Error _ as error -> error
  in
  let* value = unique_field "promotion_eligible" lines in
  match value with
  | Some "yes" -> Ok true
  | Some "no" -> Ok false
  | Some value -> Error (Printf.sprintf "unexpected promotion_eligible value %S" value)
  | None -> Error "attempt identity has no promotion_eligible field"
;;

let parse_resumed_from lines =
  let ( let* ) result next =
    match result with
    | Ok value -> next value
    | Error _ as error -> error
  in
  let* value = unique_field "resumed_from" lines in
  match value with
  | Some value when value <> "" -> Ok (Some value)
  | _ -> Ok None
;;

let of_dir directory =
  try
    let identity_path = Filename.concat directory "attempt.txt" in
    let ledger_path = Filename.concat directory "phase-verdicts.txt" in
    let identity = nonempty_lines identity_path in
    let ledger = nonempty_lines ledger_path in
    let ( let* ) result next =
      match result with
      | Ok value -> next value
      | Error _ as error -> error
    in
    let* attempt = require_field "attempt" identity in
    let* claim = require_field "claim" identity in
    let* issuer = require_field "issuer" identity in
    let* promotion_eligible = parse_promotion_eligible identity in
    let* resumed_from = parse_resumed_from identity in
    let recorded_claim_consistent =
      match claim, promotion_eligible, resumed_from with
      | "production", true, None -> true
      | "production", false, Some _ -> true
      | "mechanism-only", false, _ -> true
      | _ -> false
    in
    if not recorded_claim_consistent
    then
      Error
        (Printf.sprintf
           "recorded promotion_eligible=%b is inconsistent with claim=%s and \
            resumed_from=%s"
           promotion_eligible
           claim
           (Option.value ~default:"<none>" resumed_from))
    else
      let* verdicts =
        List.fold_left
          (fun state line ->
             let* acc = state in
             let* verdict = parse_verdict line in
             Ok (verdict :: acc))
          (Ok [])
          ledger
      in
      Ok
        { provenance = { attempt; claim; issuer; resumed_from; promotion_eligible }
        ; verdicts = List.rev verdicts
        }
  with
  | Sys_error message -> Error message
  | Failure message -> Error message
;;

type assessment =
  { attempt : string
  ; eligible : bool
  ; required_phases_ok : bool
  ; continuity : continuity
  ; reasons : reason list
  }

let verdicts_for phase verdicts =
  List.filter (fun verdict -> verdict.phase = phase) verdicts
;;

let assess attempt =
  let phase_reasons =
    List.concat_map
      (fun phase ->
         match verdicts_for phase attempt.verdicts with
         | [] -> [ Missing_phase phase ]
         | [ verdict ] when verdict.exit_code <> 0 -> [ Failed_phase phase ]
         | [ _ ] -> []
         | _ -> [ Repeated_phase phase ])
      required_phases
  in
  let required_phases_ok = phase_reasons = [] in
  let claim_reason =
    if attempt.provenance.promotion_eligible
    then []
    else
      [ Not_promotion_eligible
          (Printf.sprintf
             "claim=%s issuer=%s"
             attempt.provenance.claim
             attempt.provenance.issuer)
      ]
  in
  let continuity, resume_reason =
    match attempt.provenance.resumed_from with
    | None -> Continuous, []
    | Some source -> Resumed source, [ Resumed_attempt source ]
  in
  let reasons = phase_reasons @ claim_reason @ resume_reason in
  { attempt = attempt.provenance.attempt
  ; eligible =
      required_phases_ok
      && attempt.provenance.promotion_eligible
      && attempt.provenance.resumed_from = None
  ; required_phases_ok
  ; continuity
  ; reasons
  }
;;

let assessment_to_yojson assessment =
  let continuity =
    match assessment.continuity with
    | Continuous -> "continuous"
    | Resumed _ -> "resumed"
  in
  `Assoc
    [ "attempt", `String assessment.attempt
    ; "eligible", `Bool assessment.eligible
    ; "required_phases_ok", `Bool assessment.required_phases_ok
    ; "continuity", `String continuity
    ; ( "reasons"
      , `List
          (List.map (fun reason -> `String (string_of_reason reason)) assessment.reasons)
      )
    ]
;;
