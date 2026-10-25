(* Thin JSON adapter over Qual_release.

   The executable is an effects boundary only: it reads the repository-owned
   contract and the two evidence directories, computes its own binary identity,
   invokes the pure evaluator and prints the typed verdict. It accepts no
   --contract argument, so a caller cannot substitute a weaker attached contract.

   Exit codes: 0 PASS, 1 REFUSED, 2 input/usage error. *)

let usage =
  "usage:\n\
  \  qualification_release contract --repository DIR [--out FILE]\n\
  \  qualification_release evaluate --repository DIR \\\n\
  \    --aws-record FILE --aws-evidence DIR --gcp-record FILE --gcp-evidence DIR \\\n\
  \    [--out FILE]"
;;

let die message =
  prerr_endline ("qualification_release: " ^ message);
  exit 2
;;

let arguments () =
  let arguments = List.tl (Array.to_list Sys.argv) in
  match arguments with
  | command :: rest -> command, rest
  | [] -> die usage
;;

let flags arguments =
  let rec loop values = function
    | [] -> Ok (List.rev values)
    | flag :: value :: rest
      when String.length flag > 2 && flag.[0] = '-' && flag.[1] = '-' ->
      if String.length value > 1 && value.[0] = '-' && value.[1] = '-'
      then Error (Printf.sprintf "option %s needs a value" flag)
      else loop ((flag, value) :: values) rest
    | flag :: _ -> Error (Printf.sprintf "unexpected argument %S" flag)
  in
  loop [] arguments
;;

let required option values =
  match List.assoc_opt option values with
  | Some value -> value
  | None -> die (Printf.sprintf "missing %s\n%s" option usage)
;;

let optional option values = List.assoc_opt option values

let known options values =
  List.iter
    (fun (option, _) ->
       if not (List.mem option options)
       then die (Printf.sprintf "unknown option %s\n%s" option usage))
    values
;;

let read_bytes path =
  try In_channel.with_open_bin path In_channel.input_all with
  | Sys_error message -> die message
;;

let json_field key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let json_string ~what key json =
  match json_field key json with
  | Some (`String value) when String.trim value <> "" -> value
  | _ -> die (Printf.sprintf "%s has no string %S" what key)
;;

let json_list ~what key json =
  match json_field key json with
  | Some (`List values) -> values
  | _ -> die (Printf.sprintf "%s has no list %S" what key)
;;

let evidence_ref ~directory entry =
  let path = json_string ~what:"evidence" "path" entry in
  let class_ = json_string ~what:"evidence" "class" entry in
  let actual = Filename.concat directory path in
  let bytes =
    try In_channel.with_open_bin actual In_channel.input_all with
    | Sys_error message -> die message
  in
  `Assoc
    [ "path", `String path
    ; "sha256", `String (Qual_domain.sha256 bytes)
    ; "class", `String class_
    ]
;;

let evidence_entries ~directory json =
  `List
    (json_list ~what:"evidence list" "evidence" json |> List.map (evidence_ref ~directory))
;;

let attempt_json directory =
  match Qual_lifecycle.of_dir directory with
  | Error diagnostic -> die ("attempt: " ^ diagnostic)
  | Ok lifecycle ->
    let provenance = lifecycle.Qual_lifecycle.provenance in
    (match
       ( provenance.Qual_lifecycle.attempt
       , provenance.Qual_lifecycle.target
       , provenance.Qual_lifecycle.cluster
       , provenance.Qual_lifecycle.provider
       , provenance.Qual_lifecycle.claim
       , provenance.Qual_lifecycle.issuer
       , provenance.Qual_lifecycle.candidate_revision )
     with
     | attempt, Some target, Some cluster, Some provider, claim, issuer, Some revision ->
       `Assoc
         [ "id", `String attempt
         ; "target", `String target
         ; "cluster", `String cluster
         ; "provider", `String provider
         ; "claim", `String claim
         ; "issuer", `String issuer
         ; "candidate_revision", `String revision
         ]
     | _ ->
       die
         "attempt.txt records no candidate revision, provider, target or cluster; v2 \
          cannot bind this record")
;;

let binary_identity () =
  let revision = Qual_release.evaluator_revision in
  let source_revision = Sol_cli_build_info.revision in
  let binary_sha256 = Qual_domain.sha256 (read_bytes Sys.executable_name) in
  match Qual_release.evaluator ~revision ~source_revision ~binary_sha256 with
  | Ok evaluator -> evaluator
  | Error error -> die (error.stage ^ ": " ^ error.diagnostic)
;;

let emit optional_path json =
  let text = Yojson.Safe.pretty_to_string json ^ "\n" in
  match optional_path with
  | None -> print_string text
  | Some path ->
    (try Out_channel.with_open_bin path (fun channel -> output_string channel text) with
     | Sys_error message -> die message)
;;

let error_message error = error.Qual_release.stage ^ ": " ^ error.diagnostic

let main () =
  let command, arguments = arguments () in
  let values =
    match flags arguments with
    | Ok values -> values
    | Error message -> die message
  in
  match command with
  | "contract" ->
    known [ "--repository"; "--out" ] values;
    let repository = required "--repository" values in
    (match Qual_release.load_contract ~repository with
     | Error error -> die (error_message error)
     | Ok contract ->
       emit
         (optional "--out" values)
         (`Assoc
             [ "contract", Qual_release.contract_to_yojson contract
             ; "id", `String (Qual_release.contract_id contract)
             ; "digest", `String (Qual_release.contract_digest contract)
             ]))
  | "identity" ->
    known [ "--out" ] values;
    emit (optional "--out" values) (Qual_release.evaluator_json (binary_identity ()))
  | "emit-record" ->
    known [ "--repository"; "--attempt-dir"; "--candidate"; "--manifest"; "--out" ] values;
    let repository = required "--repository" values in
    let attempt_dir = required "--attempt-dir" values in
    let candidate_path = required "--candidate" values in
    let manifest_path = required "--manifest" values in
    let out = required "--out" values in
    let evaluator = binary_identity () in
    let contract =
      match Qual_release.load_contract ~repository with
      | Ok contract -> contract
      | Error error -> die (error_message error)
    in
    let candidate =
      try Yojson.Safe.from_string (read_bytes candidate_path) with
      | Yojson.Json_error message -> die ("candidate: " ^ message)
    in
    let manifest =
      try Yojson.Safe.from_string (read_bytes manifest_path) with
      | Yojson.Json_error message -> die ("manifest: " ^ message)
    in
    (match json_field "schema" manifest with
     | Some (`Int 1) -> ()
     | _ -> die "manifest: unsupported schema (want 1)");
    let provider = json_string ~what:"manifest" "provider" manifest in
    let provider_value =
      match provider with
      | "aws" -> Qual_release.Aws
      | "gcp" -> Qual_release.Gcp
      | _ -> die (Printf.sprintf "manifest: unknown provider %S" provider)
    in
    let harness_revision = json_string ~what:"manifest" "harness_revision" manifest in
    let phase_values = json_list ~what:"manifest" "phases" manifest in
    let phase_names =
      List.map (fun phase -> json_string ~what:"phase" "name" phase) phase_values
    in
    if
      phase_names
      <> List.map Qual_lifecycle.string_of_phase Qual_lifecycle.required_phases
    then
      die
        ("manifest: phases "
         ^ String.concat "," phase_names
         ^ " do not match the lifecycle authority");
    let phases =
      `List
        (List.map
           (fun phase ->
              `Assoc
                [ "name", `String (json_string ~what:"phase" "name" phase)
                ; "evidence", evidence_entries ~directory:attempt_dir phase
                ])
           phase_values)
    in
    let observations =
      `List
        (json_list ~what:"manifest" "observations" manifest
         |> List.map (fun observation ->
           `Assoc
             [ "id", `String (json_string ~what:"observation" "id" observation)
             ; "evidence", evidence_entries ~directory:attempt_dir observation
             ]))
    in
    let claim_values = json_list ~what:"manifest" "claims" manifest in
    let claim_ids =
      List.map (fun claim -> json_string ~what:"claim" "id" claim) claim_values
      |> List.sort String.compare
    in
    let expected_ids = Qual_release.contract_claim_ids contract provider_value in
    if claim_ids <> expected_ids
    then
      die
        ("manifest: claims "
         ^ String.concat "," claim_ids
         ^ " do not match the contract's "
         ^ String.concat "," expected_ids);
    let claims =
      `List
        (List.map
           (fun claim ->
              let fields =
                [ "id", `String (json_string ~what:"claim" "id" claim)
                ; "status", `String (json_string ~what:"claim" "status" claim)
                ; "observations", `List (json_list ~what:"claim" "observations" claim)
                ]
              in
              `Assoc
                (fields
                 @
                 match json_field "reason" claim with
                 | Some (`String reason) -> [ "reason", `String reason ]
                 | _ -> []))
           claim_values)
    in
    let boundary =
      match json_field "boundary" manifest with
      | Some (`Assoc fields) -> `Assoc fields
      | _ -> die "manifest has no boundary object"
    in
    let permission =
      match json_field "permission_binding" manifest with
      | Some (`Assoc fields) -> `Assoc fields
      | _ -> die "manifest has no permission_binding object"
    in
    let selection =
      match json_field "selection" manifest with
      | Some value -> value
      | None -> die "manifest has no selection"
    in
    let record =
      `Assoc
        [ "schema", `Int 2
        ; "provider", `String provider
        ; "candidate", candidate
        ; "harness_revision", `String harness_revision
        ; "evaluator", Qual_release.evaluator_json evaluator
        ; "attempt", attempt_json attempt_dir
        ; ( "contract"
          , `Assoc
              [ "id", `String (Qual_release.contract_id contract)
              ; "digest", `String (Qual_release.contract_digest contract)
              ] )
        ; "selection", selection
        ; "phases", phases
        ; "observations", observations
        ; "claims", claims
        ; "boundary", boundary
        ; "permission_binding", permission
        ]
    in
    let temp = out ^ ".tmp" in
    (try
       Out_channel.with_open_bin temp (fun channel ->
         output_string channel (Yojson.Safe.pretty_to_string record ^ "\n"))
     with
     | Sys_error message -> die message);
    (match Qual_release.load_record ~contract ~directory:attempt_dir ~path:temp with
     | Error error ->
       (try Sys.remove temp with
        | Sys_error _ -> ());
       die (error_message error)
     | Ok _ ->
       (try Sys.rename temp out with
        | Sys_error message -> die message);
       print_endline out)
  | "evaluate" ->
    known
      [ "--repository"
      ; "--aws-record"
      ; "--aws-evidence"
      ; "--gcp-record"
      ; "--gcp-evidence"
      ; "--out"
      ]
      values;
    let repository = required "--repository" values in
    let aws_record = required "--aws-record" values in
    let aws_evidence = required "--aws-evidence" values in
    let gcp_record = required "--gcp-record" values in
    let gcp_evidence = required "--gcp-evidence" values in
    let evaluator = binary_identity () in
    (match Qual_release.load_contract ~repository with
     | Error error -> die (error_message error)
     | Ok contract ->
       let load record directory =
         match Qual_release.load_record ~contract ~directory ~path:record with
         | Ok value -> Ok value
         | Error error -> Error (error_message error)
       in
       (match load aws_record aws_evidence, load gcp_record gcp_evidence with
        | Error message, _ | _, Error message -> die message
        | Ok aws, Ok gcp ->
          let verdict = Qual_release.evaluate ~evaluator contract aws gcp in
          emit (optional "--out" values) (Qual_release.verdict_to_yojson verdict);
          (match verdict with
           | Qual_release.Pass _ -> ()
           | Qual_release.Refused _ -> exit 1)))
  | other -> die (Printf.sprintf "unknown command %S\n%s" other usage)
;;

let () = main ()
