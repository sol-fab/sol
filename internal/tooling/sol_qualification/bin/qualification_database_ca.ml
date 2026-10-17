(* AWS database-CA family driver for the live qualification row.

   The live row calls it in phases at the lifecycle points where each observation
   is valid:

   - [migration] runs the verified candidate's own `migrate apply`, captures the
     actual Job locator and observes its CA before cleanup;
   - [application] observes the declared consumers after the final deploy;
   - [report] re-reads the persisted verdicts and candidate-binding captures and
     decides the family from those verdicts, never from summary fields copied into
     a phase capture. A successful phase exit is not a family pass.

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

(* The evidence store canonicalizes what it persists. Compare canonical forms so
   a key ordering difference is never treated as a different run. *)
let canonical json =
  match Sol_cli_database_contract_data.canonical json with
  | Ok value -> value
  | Error _ -> json
;;

let scenario = function
  | "aws" -> D.Aws
  | "gcp" -> D.Gcp
  | value -> failwith ("unsupported scenario " ^ value)
;;

let scenario_label = function
  | "aws" -> "AWS"
  | "gcp" -> "GCP"
  | value -> failwith ("unsupported scenario " ^ value)
;;

let authority_of_json json : D.kube_target =
  { principal = text json "principal"
  ; cluster = text json "cluster"
  ; endpoint = text json "endpoint"
  }
;;

let prepare_request () =
  let request = Yojson.Safe.from_file (arg "--request") in
  let pins = field request "pins" in
  let expected : C.expected =
    { revision = text pins "revision"
    ; bundle_digest = text pins "bundle_digest"
    ; definition_digest = text pins "definition_digest"
    ; specimen_digest = text pins "specimen_digest"
    ; requested_target = text pins "requested_target"
    ; target = text pins "target"
    }
  in
  let scenario_name = text request "scenario" in
  let authority = authority_of_json (field request "authority") in
  (* The product submits the migration Job as a different Kubernetes identity
     from the read-only observer on providers where Sol cannot hand its write
     credential to qualification. The observation authority remains [authority];
     only the submission receipt is checked against this one. Absent means the
     same identity, which preserves the AWS row's existing binding. *)
  let submission_authority =
    match field request "submission_authority" with
    | `Null -> authority
    | json -> authority_of_json json
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
      ~scenario:(scenario scenario_name)
      ~attempt:(text request "attempt")
      ~assessment:(text request "assessment")
      ~kubernetes:authority
    |> get
  in
  let identity_scope =
    match text request "identity_scope" with
    | "qualifier" -> "qualifier"
    | "deploy" -> "deploy"
    | other -> failwith ("unsupported observation identity scope " ^ other)
  in
  request, prepared, authority, submission_authority, identity_scope, scenario_name
;;

(* Every CA-family claim this path owns, from the verified candidate's complete
   obligation universe, as (instance key, complete requirement identity). The
   report requires exactly this set, so an omitted consumer or migration cannot
   pass by simply not being observed. *)
let expected_family prepared =
  D.instances prepared.B.obligations
  |> List.filter_map (fun instance ->
    match D.plan instance with
    | D.Ca_delivery _ | D.Migration_ca_delivery _ ->
      Some (D.instance_key instance, D.instance_identity instance)
    | _ -> None)
;;

(* Read authority for the exact resources the observations need, in every
   namespace they need. The selected identity must answer `yes`; a failure is
   unestablished, never a fallback to a more privileged identity. *)
let check_read_authority ~ctx prepared =
  let reads =
    D.instances prepared.B.obligations
    |> List.concat_map (fun instance ->
      match D.plan instance with
      | D.Ca_delivery requirement ->
        let binding = D.ca_binding requirement in
        [ binding.namespace, "deployments.apps"; binding.namespace, "configmaps" ]
      | D.Migration_ca_delivery requirement ->
        let binding = D.migration_ca_binding requirement in
        [ binding.namespace, "jobs.batch"; binding.namespace, "configmaps" ]
      | _ -> [])
    |> List.sort_uniq compare
  in
  List.iter
    (fun (namespace, resource) ->
       match
         Sol_cli_kubectl.run
           ~timeout_s:15.
           ~ctx
           [ "auth"; "can-i"; "get"; resource; "-n"; namespace ]
       with
       | Ok output when String.trim output.stdout = "yes" -> ()
       | Ok _ ->
         failwith
           (Printf.sprintf
              "the observation identity cannot read %s in %s; the CA family is \
               unestablished"
              resource
              namespace)
       | Error error ->
         failwith
           (Printf.sprintf
              "could not establish read authority for %s in %s (%s); the CA family is \
               unestablished"
              resource
              namespace
              (Sol_cli_process.error_to_string error)))
    reads
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

let kube_json (target : D.kube_target) =
  `Assoc
    [ "principal", `String target.principal
    ; "cluster", `String target.cluster
    ; "endpoint", `String target.endpoint
    ]
;;

let run_phase () =
  let request, prepared, authority, submission_authority, identity_scope, scenario_name =
    prepare_request ()
  in
  let phase = text request "phase" in
  let directory = text request "evidence" in
  let ctx =
    Sol_cli_kube_destination.of_context
      ~kubeconfig:(text request "kubeconfig")
      (text request "context")
    |> get
    |> Sol_cli_kube_destination.context_of_destination
  in
  check_read_authority ~ctx prepared;
  let transport = L.create ~ctx ~expected:authority () in
  let recorder = E.open_store ~directory ~run:prepared.B.run ~secrets:[] () |> evidence in
  (* One assessment spans both phases: the same reason/required-capture spec
     reopens it rather than creating a conflicting second assessment. *)
  ignore
    (E.start_assessment
       recorder
       ~reason:(scenario_label scenario_name ^ " database CA family")
       ~previous:[]
       ~required_captures:prepared.B.required_captures
     |> evidence);
  let binding_capture = B.capture_binding prepared recorder |> evidence in
  let read = L.read transport in
  let establish () = L.establish transport in
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
        ~submission_authority
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
  let verdicts =
    match outcome with
    | Error _ -> []
    | Ok outcomes ->
      List.filter_map
        (fun (outcome : CA.outcome) ->
           match outcome.result with
           | Ok recorded -> Some (E.reference_json recorded.receipt)
           | Error _ -> None)
        outcomes
  in
  (* A phase capture is only a pointer list: the binding slot and the persisted
     verdict references. It carries no decision of its own. The submission and
     observation authorities are recorded separately so the report cannot later
     collapse the two roles into one. *)
  let payload =
    `Assoc
      [ "phase", `String phase
      ; "ok", `Bool passed
      ; "identity_scope", `String identity_scope
      ; "authority", kube_json authority
      ; "submission_authority", kube_json submission_authority
      ; "binding", E.reference_json binding_capture
      ; "verdicts", `List verdicts
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

(* The persisted verdict schema is exactly `D.verdict_json`; this decodes that
   shape and rejects anything else. *)
let verdict_keys = [ "decision"; "detail"; "evidence"; "instance"; "requirement"; "run" ]

let decode_verdict_payload ~run payload =
  let keys =
    match payload with
    | `Assoc fields -> List.map fst fields |> List.sort compare
    | _ -> failwith "a persisted verdict is not an object"
  in
  if keys <> verdict_keys
  then failwith "a persisted verdict does not match the verdict schema"
  else (
    let instance = text payload "instance" in
    let requirement = text payload "requirement" in
    if canonical (field payload "run") <> canonical (D.run_json run)
    then failwith "a persisted verdict belongs to another assessment"
    else if field payload "decision" <> `String "PASS"
    then failwith (Printf.sprintf "verdict %s is not PASS" requirement)
    else (
      ignore (field payload "detail" |> Yojson.Safe.Util.to_string);
      ignore (field payload "evidence" |> Yojson.Safe.Util.to_list);
      instance, requirement))
;;

let verify_binding_capture ~directory ~run json =
  let reference = E.reference_of_json json |> evidence in
  let captured = E.read_capture ~directory ~run reference |> evidence in
  if captured.E.subject <> B.binding_subject
  then failwith "the phase binding capture is not the candidate binding"
  else if canonical captured.E.payload <> canonical (D.run_json run)
  then failwith "the phase binding capture belongs to another candidate assessment"
;;

let run_report () =
  let request, prepared, authority, submission_authority, identity_scope, scenario_name =
    prepare_request ()
  in
  let directory = text request "evidence" in
  let run = prepared.B.run in
  let recorder = E.open_store ~directory ~run ~secrets:[] () |> evidence in
  (* Reopen the same assessment so verdicts_for can check provenance. *)
  ignore
    (E.start_assessment
       recorder
       ~reason:(scenario_label scenario_name ^ " database CA family")
       ~previous:[]
       ~required_captures:prepared.B.required_captures
     |> evidence);
  let phase path =
    let payload = (captured_payload ~directory ~run path).E.payload in
    let verdicts =
      match field payload "verdicts" with
      | `List values -> values
      | _ -> failwith "phase capture carries no verdict references"
    in
    if text payload "identity_scope" <> identity_scope
    then failwith "phase identity scope does not match the report";
    if canonical (field payload "authority") <> canonical (kube_json authority)
    then failwith "phase observation authority does not match the report";
    if
      canonical (field payload "submission_authority")
      <> canonical (kube_json submission_authority)
    then failwith "phase submission authority does not match the report";
    verify_binding_capture ~directory ~run (field payload "binding");
    let references =
      List.map (fun json -> E.reference_of_json json |> evidence) verdicts
    in
    E.verdicts_for recorder references
    |> evidence
    |> List.map (decode_verdict_payload ~run)
  in
  let observed =
    phase (text request "migration_capture") @ phase (text request "application_capture")
  in
  let expected = expected_family prepared in
  let complete = List.sort compare observed = List.sort compare expected in
  let payload =
    `Assoc
      [ "phase", `String "report"
      ; "ca_family", `String (if complete then "pass" else "fail")
      ; "complete", `Bool complete
      ; "identity_scope", `String identity_scope
      ; "independent_qualifier", `Bool (identity_scope = "qualifier")
      ; "authority", kube_json authority
      ; "submission_authority", kube_json submission_authority
      ; "release_accepted", `Bool false
      ; ( "outcomes"
        , `List
            (List.map
               (fun (instance, requirement) ->
                  `Assoc
                    [ "instance", `String instance
                    ; "requirement", `String requirement
                    ; "decision", `String "pass"
                    ])
               observed) )
      ]
  in
  E.close recorder;
  write payload (text request "report");
  exit (if complete then 0 else 1)
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
