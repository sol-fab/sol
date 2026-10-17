(* AWS database-CA family driver for the live qualification row.

   It is the single qualification-policy owner for the database-CA family. The
   live row calls it in phases at the lifecycle points where each observation is
   valid:

   - [migration] runs the verified candidate's own `migrate apply`, captures the
     actual Job locator and observes its CA before cleanup;
   - [application] observes the declared consumers after the final deploy;
   - [report] re-reads the durable phase captures and verifies that the complete
     CA-family outcome set is present and passing. A successful command exit is
     not by itself a family pass.

   It never decides the overall release: a CA-family pass is reported separately
   from DML, TLS and the other required claims. *)
module D = Qual_domain
module C = Qual_candidate
module B = Qual_candidate_obligations
module E = Qual_evidence
module L = Qual_kubernetes_live
module CA = Qual_database_ca
module P = Qual_path

let get = function
  | Ok value -> value
  | Error message -> failwith message
;;

let evidence = function
  | Ok value -> value
  | Error (error : E.error) -> failwith (error.stage ^ ": " ^ error.diagnostic)
;;

let arg name =
  let rec loop = function
    | flag :: value :: _ when flag = name -> value
    | _ :: rest -> loop rest
    | [] -> failwith ("missing argument " ^ name)
  in
  loop (List.tl (Array.to_list Sys.argv))
;;

let field json name = Yojson.Safe.Util.member name json
let text json name = field json name |> Yojson.Safe.Util.to_string

let scenario = function
  | "aws" -> D.Aws
  | "gcp" -> D.Gcp
  | value -> failwith ("unsupported scenario " ^ value)
;;

let decision = function
  | D.Pass -> "pass"
  | D.Fail _ -> "fail"
  | D.Unknown _ -> "unknown"
  | D.Not_run _ -> "not_run"
;;

let outcome_json (outcome : CA.outcome) =
  let identity = D.instance_identity outcome.instance in
  match outcome.result with
  | Error error ->
    `Assoc
      [ "identity", `String identity; "decision", `Null; "error", `String error.E.stage ]
  | Ok recorded ->
    `Assoc
      [ "identity", `String identity
      ; "decision", `String (decision recorded.verdict.decision)
      ; "error", `Null
      ; "verdict", E.reference_json recorded.receipt
      ]
;;

let prepare_request () =
  let request = Yojson.Safe.from_file (arg "--request") in
  let pins = field request "pins" in
  let authority_json = field request "authority" in
  let expected : C.expected =
    { revision = text pins "revision"
    ; bundle_digest = text pins "bundle_digest"
    ; definition_digest = text pins "definition_digest"
    ; specimen_digest = text pins "specimen_digest"
    ; requested_target = text pins "requested_target"
    ; target = text pins "target"
    }
  in
  let authority : D.kube_target =
    { principal = text authority_json "principal"
    ; cluster = text authority_json "cluster"
    ; endpoint = text authority_json "endpoint"
    }
  in
  let verified =
    C.verify
      ~repository:(text request "repository")
      ~candidate:(text request "candidate")
      ~install:(text request "install")
      ~workspace:(text request "workspace")
      ~expected
    |> get
  in
  let prepared =
    B.prepare
      ~verified
      ~scenario:(scenario (text request "scenario"))
      ~attempt:(text request "attempt")
      ~assessment:(text request "assessment")
      ~kubernetes:authority
    |> get
  in
  request, prepared, authority
;;

(* Every CA-family claim this path owns, from the verified candidate's complete
   obligation universe. The report requires exactly this set, so an omitted
   consumer or migration cannot pass by simply not being observed. *)
let expected_family prepared =
  D.instances prepared.B.obligations
  |> List.filter_map (fun instance ->
    match D.plan instance with
    | D.Ca_delivery _ | D.Migration_ca_delivery _ -> Some (D.instance_identity instance)
    | _ -> None)
;;

let write json path =
  Out_channel.with_open_text path (fun channel ->
    output_string channel (Yojson.Safe.to_string json))
;;

let captured_payload ~directory ~run reference_path =
  let reference =
    In_channel.with_open_text reference_path In_channel.input_all
    |> Yojson.Safe.from_string
    |> E.reference_of_json
    |> evidence
  in
  E.read_capture ~directory ~run reference |> evidence
;;

let run_phase () =
  let request, prepared, authority = prepare_request () in
  let phase = text request "phase" in
  let directory = text request "evidence" in
  let recorder = E.open_store ~directory ~run:prepared.B.run ~secrets:[] () |> evidence in
  let previous =
    match E.assessments recorder with
    | Ok refs -> refs
    | Error _ -> []
  in
  ignore
    (E.start_assessment
       recorder
       ~reason:("AWS database CA family: " ^ phase)
       ~previous
       ~required_captures:prepared.B.required_captures
     |> evidence);
  let binding_capture = B.capture_binding prepared recorder |> evidence in
  let read_from_kubernetes =
    let ctx =
      Sol_cli_kube_destination.of_context
        ~kubeconfig:(text request "kubeconfig")
        (text request "context")
      |> get
      |> Sol_cli_kube_destination.context_of_destination
    in
    let transport = L.create ~ctx ~expected:authority () in
    L.read transport, fun () -> L.establish transport
  in
  let read, establish = read_from_kubernetes in
  let outcome =
    match phase with
    | "migration" ->
      P.migration
        ~directory
        ~prepared
        ~recorder
        ~read
        ~establish
        ~expected:authority
        ~binding:(text request "binding")
        ~timeout_s:30.
        ~completion_timeout_s:600.
    | "application" -> P.observe_application ~directory ~prepared ~recorder ~read
    | other -> failwith ("unsupported phase " ^ other)
  in
  let passed =
    match outcome with
    | Error _ -> false
    | Ok outcomes ->
      outcomes <> []
      && List.for_all
           (fun (outcome : CA.outcome) ->
              match outcome.result with
              | Ok recorded -> recorded.verdict.decision = D.Pass
              | Error _ -> false)
           outcomes
  in
  let outcomes =
    match outcome with
    | Ok outcomes -> outcomes
    | Error _ -> []
  in
  let payload =
    `Assoc
      [ "phase", `String phase
      ; "ok", `Bool passed
      ; "binding", E.reference_json binding_capture
      ; "outcomes", `List (List.map outcome_json outcomes)
      ]
  in
  let capture = E.capture recorder ~subject:("ca-family/" ^ phase) ~payload |> evidence in
  write (E.reference_json capture) (text request "capture");
  write
    (match outcome with
     | Error message ->
       `Assoc [ "phase", `String phase; "ok", `Bool false; "error", `String message ]
     | Ok _ -> `Assoc [ "phase", `String phase; "ok", `Bool true ])
    (text request "report");
  E.close recorder;
  exit (if passed then 0 else 1)
;;

let run_report () =
  let request, prepared, _ = prepare_request () in
  let directory = text request "evidence" in
  let run = prepared.B.run in
  let verify_reference json =
    match json with
    | `Null -> ()
    | value ->
      let reference = E.reference_of_json value |> evidence in
      ignore (E.read_capture ~directory ~run reference |> evidence)
  in
  let read_outcomes path =
    let payload = (captured_payload ~directory ~run path).E.payload in
    (* The phase's binding slot and every recorded verdict must still be readable
       and digest-valid. The report never rests on the phase's exit status. *)
    verify_reference (field payload "binding");
    match field payload "outcomes" with
    | `List values ->
      List.map
        (fun value ->
           verify_reference (field value "verdict");
           ( text value "identity"
           , match field value "decision" with
             | `String "pass" -> `Pass
             | `String "fail" -> `Fail
             | `String "unknown" -> `Unknown
             | _ -> `Not_run ))
        values
    | _ -> []
  in
  let observed =
    read_outcomes (text request "migration_capture")
    @ read_outcomes (text request "application_capture")
  in
  let expected = expected_family prepared in
  let reported = List.map fst observed in
  let complete =
    List.length observed = List.length expected
    && List.sort compare reported = List.sort compare expected
  in
  let all_pass = List.for_all (fun (_, decision) -> decision = `Pass) observed in
  let payload =
    `Assoc
      [ "phase", `String "report"
      ; "ca_family", `String (if complete && all_pass then "pass" else "fail")
      ; "complete", `Bool complete
      ; "release_accepted", `Bool false
      ; ( "outcomes"
        , `List
            (List.map
               (fun (identity, decision) ->
                  `Assoc
                    [ "identity", `String identity
                    ; ( "decision"
                      , `String
                          (match decision with
                           | `Pass -> "pass"
                           | `Fail -> "fail"
                           | `Unknown -> "unknown"
                           | `Not_run -> "not_run") )
                    ])
               observed) )
      ]
  in
  write payload (text request "report");
  exit (if complete && all_pass then 0 else 1)
;;

let () =
  try
    match arg "--phase" with
    | "report" -> run_report ()
    | "migration" | "application" -> run_phase ()
    | value -> failwith ("unsupported phase " ^ value)
  with
  | Failure message ->
    prerr_endline ("qualification_database_ca: " ^ message);
    exit 2
;;
