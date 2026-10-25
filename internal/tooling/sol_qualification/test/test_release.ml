(* Adversarial tests for the typed release authority.

   These tests exercise the authority boundary, not a producer's happy path:
   evidence is real, on disk and content-addressed; each refusal is caused by a
   single independently mutated fact. The evaluator itself is pure; the loader
   and the executable are tested at their own boundaries. *)

module R = Qual_release

let check label condition =
  if condition
  then Printf.printf "  [OK]   %s\n" label
  else (
    Printf.printf "  [FAIL] %s\n" label;
    Alcotest.fail label)
;;

let error_text error = error.R.stage ^ ": " ^ error.diagnostic

let ok label = function
  | Ok value -> value
  | Error error -> Alcotest.fail (label ^ ": " ^ error_text error)
;;

let has_reason label verdict needle =
  match verdict with
  | R.Refused reasons ->
    let matched =
      List.exists
        (fun reason ->
           let needle_length = String.length needle in
           let reason_length = String.length reason in
           let rec contains index =
             index + needle_length <= reason_length
             && (String.sub reason index needle_length = needle || contains (index + 1))
           in
           contains 0)
        reasons
    in
    if not matched
    then Printf.printf "         reasons: %s\n" (String.concat "; " reasons);
    check label matched
  | R.Pass _ -> check (label ^ " (unexpectedly passed)") false
;;

let write_file path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all
let sha256 text = Qual_domain.sha256 text

let replace_line directory filename replacements =
  let path = Filename.concat directory filename in
  let lines = String.split_on_char '\n' (read_file path) in
  let replaced =
    List.map
      (fun line ->
         match String.index_opt line '=' with
         | Some index ->
           let key = String.sub line 0 index in
           (match List.assoc_opt key replacements with
            | Some value -> key ^ "=" ^ value
            | None -> line)
         | None -> line)
      lines
  in
  write_file path (String.concat "\n" replaced)
;;

let rec mkdir_p path =
  if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_dir label f =
  let path = Filename.temp_file ("qual-release-" ^ label) "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let revision = String.make 40 'a'
let source_revision = String.make 40 'a'
let harness = String.make 40 'd'
let bundle = String.make 64 'b'
let binary = String.make 64 'e'
let runner = "ghcr.io/example/sol-migration-runner@sha256:" ^ String.make 64 'c'

let candidate () =
  `Assoc
    [ "version", `String "v0.1.0-alpha.99"
    ; "revision", `String revision
    ; "bundle_sha256", `String bundle
    ; "runner_image", `String runner
    ]
;;

let evaluator_json
      ?(revision = R.evaluator_revision)
      ?(source_revision = source_revision)
      ?(binary = binary)
      ()
  =
  `Assoc
    [ "revision", `String revision
    ; "source_revision", `String source_revision
    ; "binary_sha256", `String binary
    ]
;;

let test_path = "internal/tooling/sol_qualification/test/test_release.ml"

let contract_json
      ?(providers = [ "aws"; "gcp" ])
      ?(phases = [ "prepare"; "cloud"; "app"; "destroy" ])
      ?(claims = None)
      ?(exceptions = None)
      ()
  =
  let claims =
    match claims with
    | Some claims -> claims
    | None ->
      [ `Assoc
          [ "family", `String "application-transaction"
          ; "evidence_class", `String "behavioral"
          ; "test", `String "internal/qualification/local/test-rows-ocaml.sh"
          ; "ids", `Assoc [ "aws", `String "B1"; "gcp", `String "B1" ]
          ]
      ; `Assoc
          [ "family", `String "destroy-preparation"
          ; "evidence_class", `String "behavioral"
          ; ( "test"
            , `String "internal/qualification/aws/production-single-region-v1-matrix.md" )
          ; "ids", `Assoc [ "aws", `String "I8" ]
          ]
      ]
  in
  let exceptions =
    match exceptions with
    | Some exceptions -> exceptions
    | None ->
      [ `Assoc
          [ "family", `String "destroy-preparation"
          ; "provider", `String "gcp"
          ; "reason", `String "GCP has no RDS final-snapshot preparation step"
          ; "test", `String test_path
          ]
      ]
  in
  `Assoc
    [ "id", `String "test-cross-provider"
    ; "revision", `String "2026-10-25"
    ; "providers", `List (List.map (fun value -> `String value) providers)
    ; "phases", `List (List.map (fun value -> `String value) phases)
    ; "profile", `String "production-single-region/v1"
    ; ( "attempt_requirements"
      , `Assoc [ "claim", `String "production"; "issuer", `String "letsencrypt-prod" ] )
    ; ( "selection"
      , `Assoc
          [ "languages", `List [ `String "ocaml"; `String "typescript" ]
          ; "primitives", `List [ `String "svc"; `String "worker" ]
          ] )
    ; "claims", `List claims
    ; "exceptions", `List exceptions
    ]
;;

let repository () = Sys.getenv "SOL_TEST_REPOSITORY"
let contract () = ok "canonical contract" (R.load_contract ~repository:(repository ()))
let contract_id contract = R.contract_id contract
let contract_digest contract = R.contract_digest contract

let evidence_ref directory name class_ =
  let contents = Printf.sprintf "{\"evidence\":%S}\n" name in
  write_file (Filename.concat directory name) contents;
  `Assoc
    [ "path", `String name; "sha256", `String (sha256 contents); "class", `String class_ ]
;;

let attempt_text ~attempt ~target ~cluster ~provider ~claim ~issuer =
  String.concat
    "\n"
    [ "attempt=" ^ attempt
    ; "target=" ^ target
    ; "cluster=" ^ cluster
    ; "provider=" ^ provider
    ; "claim=" ^ claim
    ; "issuer=" ^ issuer
    ; "candidate_revision=" ^ revision
    ; "promotion_eligible=yes"
    ]
  ^ "\n"
;;

let phase_ledger () =
  String.concat
    "\n"
    [ "phase=prepare exit=0 at=2026-10-25T00:00:00Z"
    ; "phase=cloud exit=0 at=2026-10-25T00:01:00Z"
    ; "phase=app exit=0 at=2026-10-25T00:02:00Z"
    ; "phase=destroy exit=0 at=2026-10-25T00:03:00Z"
    ]
  ^ "\n"
;;

let attempt_facts provider =
  match provider with
  | "aws" ->
    ( "aws-1"
    , "qual-aws/aws/us-east-1"
    , "sol-qual-aws"
    , "arn:aws:iam::123456789012:role/sol-deploy-subject" )
  | "gcp" ->
    ( "gcp-1"
    , "qual-gcp/gcp/us-central1"
    , "sol-qual-gcp"
    , "serviceAccount:sol-deploy@example.iam.gserviceaccount.com" )
  | _ -> assert false
;;

let write_attempt directory provider =
  let attempt, target, cluster, subject = attempt_facts provider in
  write_file
    (Filename.concat directory "attempt.txt")
    (attempt_text
       ~attempt
       ~target
       ~cluster
       ~provider
       ~claim:"production"
       ~issuer:"letsencrypt-prod");
  write_file (Filename.concat directory "phase-verdicts.txt") (phase_ledger ());
  attempt, target, cluster, subject
;;

let record_json
      ?(evaluator = evaluator_json ())
      ?(harness = harness)
      ?(candidate = candidate ())
      ?selection
      ?boundary
      ?permission
      ~directory
      ~contract
      ~provider
      ()
  =
  let attempt, target, cluster, subject = write_attempt directory provider in
  let observations =
    [ "transaction", "behavioral"
    ; "profile", "behavioral"
    ; "boundary", "behavioral"
    ; "permission", "behavioral"
    ]
    |> List.map (fun (name, class_) ->
      `Assoc
        [ "id", `String name
        ; "evidence", `List [ evidence_ref directory (name ^ ".json") class_ ]
        ])
  in
  let phase_evidence name =
    `List [ evidence_ref directory ("phase-" ^ name ^ ".json") "behavioral" ]
  in
  let phases =
    [ "prepare"; "cloud"; "app"; "destroy" ]
    |> List.map (fun name ->
      `Assoc [ "name", `String name; "evidence", phase_evidence name ])
  in
  let claims =
    [ `Assoc
        [ "id", `String "B1"
        ; "status", `String "pass"
        ; "observations", `List [ `String "transaction" ]
        ]
    ]
    @
    match provider with
    | "aws" ->
      [ `Assoc
          [ "id", `String "I8"
          ; "status", `String "pass"
          ; "observations", `List [ `String "transaction" ]
          ]
      ]
    | _ -> []
  in
  let selection =
    match selection with
    | Some selection -> selection
    | None ->
      `Assoc
        [ "languages", `List [ `String "ocaml"; `String "typescript" ]
        ; "primitives", `List [ `String "svc"; `String "worker" ]
        ]
  in
  let boundary =
    match boundary with
    | Some boundary -> boundary
    | None ->
      `Assoc
        [ "kind", `String (if provider = "aws" then "artifact-gate" else "migration-gate")
        ; "observations", `List [ `String "boundary" ]
        ]
  in
  let permission =
    match permission with
    | Some permission -> permission
    | None ->
      `Assoc
        [ "deploy_identity", `String ("sol-deploy-" ^ provider)
        ; "mechanism", `String "direct"
        ; "subject", `String subject
        ; "observations", `List [ `String "permission" ]
        ]
  in
  `Assoc
    [ "provider", `String provider
    ; "candidate", candidate
    ; "harness_revision", `String harness
    ; "evaluator", evaluator
    ; ( "attempt"
      , `Assoc
          [ "id", `String attempt
          ; "target", `String target
          ; "cluster", `String cluster
          ; "provider", `String provider
          ; "claim", `String "production"
          ; "issuer", `String "letsencrypt-prod"
          ; "candidate_revision", `String revision
          ] )
    ; ( "contract"
      , `Assoc
          [ "id", `String (contract_id contract)
          ; "digest", `String (contract_digest contract)
          ] )
    ; "selection", selection
    ; "phases", `List phases
    ; "observations", `List observations
    ; "claims", `List claims
    ; ( "profile"
      , `Assoc
          [ "kind", `String "production-single-region/v1"
          ; "observations", `List [ `String "profile" ]
          ] )
    ; "boundary", boundary
    ; "permission_binding", permission
    ]
;;

let write_record directory contract provider json =
  ignore contract;
  ignore provider;
  let path = Filename.concat directory "record.json" in
  write_file path (Yojson.Safe.pretty_to_string json ^ "\n");
  path
;;

let load directory contract =
  let path = Filename.concat directory "record.json" in
  ok "load record" (R.load_record ~contract ~directory ~path)
;;

let fixture contract provider directory =
  let json = record_json ~directory ~contract ~provider () in
  ignore (write_record directory contract provider json);
  load directory contract, json
;;

let evaluate contract aws gcp =
  let evaluator =
    ok
      "evaluator"
      (R.evaluator
         ~revision:R.evaluator_revision
         ~source_revision:(Some source_revision)
         ~binary_sha256:binary)
  in
  R.evaluate ~evaluator contract aws gcp
;;

(* ------------------------------------------------------------------ *)

let json_records verdict =
  match R.verdict_to_yojson verdict with
  | `Assoc fields ->
    (match List.assoc_opt "records" fields with
     | Some (`List records) -> records
     | _ -> [])
  | _ -> []
;;

let test_valid_pair () =
  let contract = contract () in
  with_temp_dir "valid-aws" (fun aws_dir ->
    with_temp_dir "valid-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      match evaluate contract aws gcp with
      | R.Pass pass ->
        check "a valid two-provider qualification passes" true;
        check "the pass binds both provider records" (List.length pass.records = 2);
        check
          "the pass binds the contract digest"
          (pass.contract_digest = contract_digest contract);
        check "the pass shows the typed exceptions" (List.length pass.exceptions = 1);
        check "the pass shows both claim families" (List.length pass.claims = 2);
        let records = json_records (evaluate contract aws gcp) in
        let digests =
          List.filter_map
            (function
              | `Assoc fields ->
                (match List.assoc_opt "record_sha256" fields with
                 | Some (`String digest) -> Some digest
                 | _ -> None)
              | _ -> None)
            records
        in
        let expected =
          [ sha256 (read_file (Filename.concat aws_dir "record.json"))
          ; sha256 (read_file (Filename.concat gcp_dir "record.json"))
          ]
        in
        check
          "the verdict binds each record's raw bytes"
          (List.sort String.compare digests = List.sort String.compare expected);
        let attempts =
          List.filter_map
            (function
              | `Assoc fields ->
                (match List.assoc_opt "attempt" fields with
                 | Some (`String attempt) -> Some attempt
                 | _ -> None)
              | _ -> None)
            records
        in
        check
          "the verdict binds both attempt identities"
          (List.sort String.compare attempts = [ "aws-1"; "gcp-1" ])
      | R.Refused reasons ->
        check
          ("a valid two-provider qualification passes: " ^ String.concat "; " reasons)
          false))
;;

let test_one_provider_contract () =
  let json = contract_json ~providers:[ "aws" ] () in
  match R.contract_of_json json with
  | Error _ -> check "a one-provider contract is refused" true
  | Ok _ -> check "a one-provider contract is refused" false
;;

let test_missing_phase_contract () =
  let json = contract_json ~phases:[ "prepare"; "cloud"; "app" ] () in
  match R.contract_of_json json with
  | Error _ -> check "a contract that weakens the lifecycle phase set is refused" true
  | Ok _ -> check "a contract that weakens the lifecycle phase set is refused" false
;;

let test_claim_without_provider () =
  let claims =
    [ `Assoc
        [ "family", `String "application-transaction"
        ; "evidence_class", `String "behavioral"
        ; "test", `String "internal/qualification/local/test-rows-ocaml.sh"
        ; "ids", `Assoc [ "aws", `String "B1" ]
        ]
    ]
  in
  match
    R.contract_of_json (contract_json ~claims:(Some claims) ~exceptions:(Some []) ())
  with
  | Error _ -> check "a provider-specific omission needs an exception" true
  | Ok _ -> check "a provider-specific omission needs an exception" false
;;

let test_mapped_and_exception () =
  let exceptions =
    [ `Assoc
        [ "family", `String "application-transaction"
        ; "provider", `String "aws"
        ; "reason", `String "invented"
        ; "test", `String test_path
        ]
    ]
  in
  match R.contract_of_json (contract_json ~exceptions:(Some exceptions) ()) with
  | Error _ -> check "a claim id and an exception for the same provider is refused" true
  | Ok _ -> check "a claim id and an exception for the same provider is refused" false
;;

let test_evidence_missing () =
  let contract = contract () in
  with_temp_dir "missing-evidence" (fun directory ->
    let _, json = fixture contract "aws" directory in
    let json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if key <> "observations"
                then key, value
                else
                  ( key
                  , match value with
                    | `List (_ :: rest) ->
                      `List
                        (`Assoc
                           [ "id", `String "transaction"
                           ; ( "evidence"
                             , `List
                                 [ `Assoc
                                     [ "path", `String "absent.json"
                                     ; "sha256", `String (String.make 64 '0')
                                     ; "class", `String "behavioral"
                                     ]
                                 ] )
                           ]
                         :: rest)
                    | _ -> value ))
             fields)
      | value -> value
    in
    let path = write_record directory contract "aws" json in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "missing evidence refuses" true
    | Ok _ -> check "missing evidence refuses" false)
;;

let test_evidence_digest () =
  let contract = contract () in
  with_temp_dir "bad-digest" (fun directory ->
    let _, json = fixture contract "aws" directory in
    write_file (Filename.concat directory "transaction.json") "{}";
    let json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if key = "observations"
                then
                  ( key
                  , match value with
                    | `List (_ :: rest) ->
                      `List
                        (`Assoc
                           [ "id", `String "transaction"
                           ; ( "evidence"
                             , `List
                                 [ `Assoc
                                     [ "path", `String "transaction.json"
                                     ; "sha256", `String (String.make 64 '0')
                                     ; "class", `String "behavioral"
                                     ]
                                 ] )
                           ]
                         :: rest)
                    | _ -> value )
                else key, value)
             fields)
      | value -> value
    in
    let path = write_record directory contract "aws" json in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "an altered evidence file refuses" true
    | Ok _ -> check "an altered evidence file refuses" false)
;;

let test_evidence_path () =
  let contract = contract () in
  with_temp_dir "path" (fun directory ->
    let _, json = fixture contract "aws" directory in
    let json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if key = "observations"
                then
                  ( key
                  , match value with
                    | `List (_ :: rest) ->
                      `List
                        (`Assoc
                           [ "id", `String "transaction"
                           ; ( "evidence"
                             , `List
                                 [ `Assoc
                                     [ "path", `String "../transaction.json"
                                     ; "sha256", `String (String.make 64 '0')
                                     ; "class", `String "behavioral"
                                     ]
                                 ] )
                           ]
                         :: rest)
                    | _ -> value )
                else key, value)
             fields)
      | value -> value
    in
    let path = write_record directory contract "aws" json in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "an evidence path outside the attempt directory refuses" true
    | Ok _ -> check "an evidence path outside the attempt directory refuses" false)
;;

let test_record_duplicate_key () =
  let contract = contract () in
  with_temp_dir "duplicate" (fun directory ->
    ignore (write_attempt directory "aws");
    let path = Filename.concat directory "record.json" in
    write_file path "{\"provider\":\"aws\",\"provider\":\"aws\"}\n";
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "duplicate JSON keys refuse" true
    | Ok _ -> check "duplicate JSON keys refuse" false)
;;

let test_attempt_drift () =
  let contract = contract () in
  with_temp_dir "attempt" (fun directory ->
    let _, json = fixture contract "aws" directory in
    let json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if key = "attempt"
                then
                  ( key
                  , match value with
                    | `Assoc attempt ->
                      `Assoc
                        (List.map
                           (fun (field, value) ->
                              if field = "id"
                              then field, `String "aws-other"
                              else field, value)
                           attempt)
                    | _ -> value )
                else key, value)
             fields)
      | value -> value
    in
    let path = write_record directory contract "aws" json in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "attempt identity drift refuses" true
    | Ok _ -> check "attempt identity drift refuses" false)
;;

let test_attempt_candidate_drift () =
  let contract = contract () in
  with_temp_dir "attempt-candidate" (fun directory ->
    ignore (fixture contract "aws" directory);
    replace_line directory "attempt.txt" [ "candidate_revision", String.make 40 'f' ];
    let path = Filename.concat directory "record.json" in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "candidate/attempt revision drift refuses" true
    | Ok _ -> check "candidate/attempt revision drift refuses" false)
;;

let test_contract_digest_drift () =
  let contract = contract () in
  with_temp_dir "contract-drift" (fun directory ->
    let _, json = fixture contract "aws" directory in
    let json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if key = "contract"
                then
                  ( "contract"
                  , `Assoc
                      [ "id", `String (contract_id contract)
                      ; "digest", `String (String.make 64 '9')
                      ] )
                else key, value)
             fields)
      | value -> value
    in
    let path = write_record directory contract "aws" json in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "a record bound to another contract digest refuses" true
    | Ok _ -> check "a record bound to another contract digest refuses" false)
;;

let test_contract_change_invalidates () =
  let old_contract = contract () in
  with_temp_dir "old-contract" (fun aws_dir ->
    let _, json = fixture old_contract "aws" aws_dir in
    let claims =
      [ `Assoc
          [ "family", `String "application-transaction"
          ; "evidence_class", `String "behavioral"
          ; "test", `String "internal/qualification/local/test-rows-ocaml.sh"
          ; "ids", `Assoc [ "aws", `String "B1"; "gcp", `String "B1" ]
          ]
      ; `Assoc
          [ "family", `String "destroy-preparation"
          ; "evidence_class", `String "behavioral"
          ; ( "test"
            , `String "internal/qualification/aws/production-single-region-v1-matrix.md" )
          ; "ids", `Assoc [ "aws", `String "I8"; "gcp", `String "I8" ]
          ]
      ]
    in
    let changed_json = contract_json ~claims:(Some claims) ~exceptions:(Some []) () in
    let changed = ok "changed contract" (R.contract_of_json changed_json) in
    let path = write_record aws_dir old_contract "aws" json in
    match R.load_record ~contract:changed ~directory:aws_dir ~path with
    | Error _ -> check "a changed contract invalidates old records" true
    | Ok _ -> check "a changed contract invalidates old records" false)
;;

let test_candidate_mismatch () =
  let contract = contract () in
  with_temp_dir "cand-aws" (fun aws_dir ->
    with_temp_dir "cand-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json =
        record_json
          ~candidate:
            (`Assoc
                [ "version", `String "v0.1.0-alpha.98"
                ; "revision", `String revision
                ; "bundle_sha256", `String bundle
                ; "runner_image", `String runner
                ])
          ~directory:gcp_dir
          ~contract
          ~provider:"gcp"
          ()
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "a different candidate refuses"
        (evaluate contract aws gcp)
        "different candidates"))
;;

let test_harness_mismatch () =
  let contract = contract () in
  with_temp_dir "har-aws" (fun aws_dir ->
    with_temp_dir "har-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json =
        record_json
          ~harness:(String.make 40 'f')
          ~directory:gcp_dir
          ~contract
          ~provider:"gcp"
          ()
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "a different harness revision refuses"
        (evaluate contract aws gcp)
        "different harness"))
;;

let test_evaluator_mismatch () =
  let contract = contract () in
  with_temp_dir "eval-aws" (fun aws_dir ->
    with_temp_dir "eval-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      let other =
        ok
          "other evaluator"
          (R.evaluator
             ~revision:"other"
             ~source_revision:(Some source_revision)
             ~binary_sha256:(String.make 64 'f'))
      in
      has_reason
        "a different evaluator implementation refuses"
        (R.evaluate ~evaluator:other contract aws gcp)
        "not produced by this evaluator"))
;;

let test_record_evaluator_mismatch () =
  let contract = contract () in
  with_temp_dir "evalrec-aws" (fun aws_dir ->
    with_temp_dir "evalrec-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json =
        record_json
          ~evaluator:(evaluator_json ~revision:"old" ())
          ~directory:gcp_dir
          ~contract
          ~provider:"gcp"
          ()
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "records from another evaluator refuse"
        (evaluate contract aws gcp)
        "same evaluator"))
;;

let test_same_attempt () =
  let contract = contract () in
  with_temp_dir "same-aws" (fun aws_dir ->
    let aws, _ = fixture contract "aws" aws_dir in
    has_reason
      "the same attempt cannot fill both provider slots"
      (evaluate contract aws aws)
      "same attempt")
;;

let test_selection_lower_bound () =
  let contract = contract () in
  with_temp_dir "sel-aws" (fun aws_dir ->
    with_temp_dir "sel-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json =
        record_json
          ~selection:
            (`Assoc
                [ "languages", `List [ `String "ocaml" ]
                ; "primitives", `List [ `String "svc"; `String "worker" ]
                ])
          ~directory:gcp_dir
          ~contract
          ~provider:"gcp"
          ()
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "a record below the selection lower bound refuses"
        (evaluate contract aws gcp)
        "required languages"))
;;

let test_selection_mismatch () =
  let contract = contract () in
  with_temp_dir "sel2-aws" (fun aws_dir ->
    with_temp_dir "sel2-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json =
        record_json
          ~selection:
            (`Assoc
                [ ( "languages"
                  , `List [ `String "ocaml"; `String "typescript"; `String "go" ] )
                ; "primitives", `List [ `String "svc"; `String "worker" ]
                ])
          ~directory:gcp_dir
          ~contract
          ~provider:"gcp"
          ()
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "providers with different actual selections refuse"
        (evaluate contract aws gcp)
        "different selections"))
;;

let test_selection_order () =
  let contract = contract () in
  with_temp_dir "order-aws" (fun aws_dir ->
    with_temp_dir "order-gcp" (fun gcp_dir ->
      let reorder =
        `Assoc
          [ "languages", `List [ `String "typescript"; `String "ocaml" ]
          ; "primitives", `List [ `String "worker"; `String "svc" ]
          ]
      in
      let aws_json =
        record_json ~selection:reorder ~directory:aws_dir ~contract ~provider:"aws" ()
      in
      ignore (write_record aws_dir contract "aws" aws_json);
      let aws = load aws_dir contract in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      match evaluate contract aws gcp with
      | R.Pass _ -> check "selection order does not change the decision" true
      | R.Refused reasons ->
        check
          ("selection order does not change the decision: " ^ String.concat "; " reasons)
          false))
;;

let test_claim_missing () =
  let contract = contract () in
  with_temp_dir "claim-aws" (fun aws_dir ->
    with_temp_dir "claim-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let gcp_json =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) -> if key = "claims" then key, `List [] else key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      match
        R.load_record
          ~contract
          ~directory:gcp_dir
          ~path:(Filename.concat gcp_dir "record.json")
      with
      | Error _ -> check "a record with no claims refuses at parse time" true
      | Ok gcp ->
        has_reason "a missing required claim refuses" (evaluate contract aws gcp) "claims"))
;;

let test_claim_extra () =
  let contract = contract () in
  with_temp_dir "extra-aws" (fun aws_dir ->
    with_temp_dir "extra-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let gcp_json =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "claims"
                  then
                    ( key
                    , match value with
                      | `List claims ->
                        `List
                          (claims
                           @ [ `Assoc
                                 [ "id", `String "B4"
                                 ; "status", `String "pass"
                                 ; "observations", `List [ `String "transaction" ]
                                 ]
                             ])
                      | _ -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "an extra claim outside the contract refuses"
        (evaluate contract aws gcp)
        "not the contract's"))
;;

let test_claim_no_observation () =
  let contract = contract () in
  with_temp_dir "noobs-aws" (fun aws_dir ->
    with_temp_dir "noobs-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let gcp_json =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "claims"
                  then
                    ( key
                    , match value with
                      | `List claims ->
                        `List
                          (List.map
                             (fun claim ->
                                match claim with
                                | `Assoc fields ->
                                  `Assoc
                                    (List.map
                                       (fun (field, value) ->
                                          if field = "observations"
                                          then field, `List []
                                          else field, value)
                                       fields)
                                | value -> value)
                             claims)
                      | _ -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "a passing claim with no observation refuses"
        (evaluate contract aws gcp)
        "no observation references"))
;;

let test_claim_mechanism_only () =
  let contract = contract () in
  with_temp_dir "mech-aws" (fun aws_dir ->
    with_temp_dir "mech-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let gcp_json =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  match key, value with
                  | "observations", `List observations ->
                    let mechanism =
                      `Assoc
                        [ "id", `String "mechanism"
                        ; ( "evidence"
                          , `List [ evidence_ref gcp_dir "mechanism.json" "mechanism" ] )
                        ]
                    in
                    "observations", `List (mechanism :: observations)
                  | "claims", `List claims ->
                    ( "claims"
                    , `List
                        (List.map
                           (fun claim ->
                              match claim with
                              | `Assoc fields ->
                                `Assoc
                                  (List.map
                                     (fun (field, value) ->
                                        if field = "observations"
                                        then field, `List [ `String "mechanism" ]
                                        else field, value)
                                     fields)
                              | value -> value)
                           claims) )
                  | _ -> key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "mechanism evidence cannot pass a behavioural claim"
        (evaluate contract aws gcp)
        "has no behavioral evidence"))
;;

let test_phases () =
  let contract = contract () in
  with_temp_dir "phase-aws" (fun aws_dir ->
    with_temp_dir "phase-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let reorder =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "phases"
                  then
                    ( key
                    , match value with
                      | `List (first :: rest) -> `List (rest @ [ first ])
                      | _ -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" reorder);
      let gcp = load gcp_dir contract in
      has_reason
        "reordered phases refuse"
        (evaluate contract aws gcp)
        "phases do not match the lifecycle authority"))
;;

let test_phase_missing () =
  let contract = contract () in
  with_temp_dir "phasem-aws" (fun aws_dir ->
    with_temp_dir "phasem-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let missing =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "phases"
                  then
                    ( key
                    , match value with
                      | `List (_ :: rest) -> `List rest
                      | _ -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" missing);
      let gcp = load gcp_dir contract in
      has_reason
        "a missing phase refuses"
        (evaluate contract aws gcp)
        "phases do not match the lifecycle authority"))
;;

let test_boundary_and_permission () =
  let contract = contract () in
  with_temp_dir "bound-aws" (fun aws_dir ->
    with_temp_dir "bound-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json =
        record_json
          ~boundary:
            (`Assoc
                [ "kind", `String "migration-gate"
                ; "observations", `List [ `String "mechanism" ]
                ])
          ~permission:
            (`Assoc
                [ "deploy_identity", `String "sol-deploy-gcp"
                ; "mechanism", `String "group"
                ; "subject", `String "group:sol-deploy"
                ; "observations", `List [ `String "mechanism" ]
                ])
          ~directory:gcp_dir
          ~contract
          ~provider:"gcp"
          ()
      in
      let gcp_json =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  match key with
                  | "observations" ->
                    ( key
                    , (match value with
                       | `List observations ->
                         `List
                           (`Assoc
                              [ "id", `String "mechanism"
                              ; ( "evidence"
                                , `List
                                    [ evidence_ref gcp_dir "mechanism.json" "mechanism" ]
                                )
                              ]
                            :: observations)
                       | _ -> value) )
                  | _ -> key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      let verdict = evaluate contract aws gcp in
      has_reason
        "a boundary without behavioural evidence refuses"
        verdict
        "boundary is not supported";
      has_reason
        "a permission binding without behavioural evidence refuses"
        verdict
        "permission binding is not supported"))
;;

let test_excluded_without_exception () =
  let contract = contract () in
  with_temp_dir "exc-aws" (fun aws_dir ->
    with_temp_dir "exc-gcp" (fun gcp_dir ->
      let aws_json = record_json ~directory:aws_dir ~contract ~provider:"aws" () in
      let aws_json =
        match aws_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "claims"
                  then
                    ( key
                    , match value with
                      | `List claims ->
                        `List
                          (List.map
                             (fun claim ->
                                match claim with
                                | `Assoc fields ->
                                  `Assoc
                                    (List.map
                                       (fun (field, value) ->
                                          if field = "status"
                                          then field, `String "excluded"
                                          else if field = "reason"
                                          then field, `String "self-authorized"
                                          else field, value)
                                       fields)
                                | value -> value)
                             claims)
                      | _ -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record aws_dir contract "aws" aws_json);
      let aws = load aws_dir contract in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      has_reason
        "a record cannot self-authorize an exception"
        (evaluate contract aws gcp)
        "a provider-specific omission is a contract exception"))
;;

let test_exception_reason_drift () =
  let contract = contract () in
  with_temp_dir "excreason-aws" (fun aws_dir ->
    with_temp_dir "excreason-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      match evaluate contract aws gcp with
      | R.Pass _ ->
        let json = R.verdict_to_yojson (evaluate contract aws gcp) in
        check
          "the contract exception is visible in the PASS verdict"
          (match json with
           | `Assoc fields ->
             (match List.assoc_opt "exceptions" fields with
              | Some (`List [ `Assoc exception_fields ]) ->
                (match List.assoc_opt "reason" exception_fields with
                 | Some (`String reason) ->
                   let needle = "INV-DESTROY-4" in
                   let rec contains index =
                     index + String.length needle <= String.length reason
                     && (String.sub reason index (String.length needle) = needle
                         || contains (index + 1))
                   in
                   contains 0
                 | _ -> false)
              | _ -> false)
           | _ -> false)
      | R.Refused reasons ->
        check ("exception visibility: " ^ String.concat "; " reasons) false))
;;

let test_selection_duplicate () =
  let contract = contract () in
  with_temp_dir "dup-aws" (fun aws_dir ->
    let json =
      record_json
        ~selection:
          (`Assoc
              [ "languages", `List [ `String "ocaml"; `String "ocaml" ]
              ; "primitives", `List [ `String "svc" ]
              ])
        ~directory:aws_dir
        ~contract
        ~provider:"aws"
        ()
    in
    let path = write_record aws_dir contract "aws" json in
    match R.load_record ~contract ~directory:aws_dir ~path with
    | Error _ -> check "duplicate selection values refuse" true
    | Ok _ -> check "duplicate selection values refuse" false)
;;

let test_cli () =
  let bin = Sys.getenv "SOL_TEST_RELEASE_BIN" in
  let repository = Sys.getenv "SOL_TEST_REPOSITORY" in
  let run arguments =
    let quoted = List.map Filename.quote arguments |> String.concat " " in
    Sys.command (Filename.quote bin ^ " " ^ quoted)
  in
  check "the executable refuses no arguments" (run [] <> 0);
  check
    "the executable refuses an unknown option"
    (run [ "evaluate"; "--repository"; repository; "--bogus"; "x" ] <> 0);
  with_temp_dir "cli-missing" (fun directory ->
    check
      "the executable refuses a missing provider record"
      (run
         [ "evaluate"
         ; "--repository"
         ; repository
         ; "--aws-record"
         ; Filename.concat directory "absent.json"
         ; "--aws-evidence"
         ; directory
         ; "--gcp-record"
         ; Filename.concat directory "absent.json"
         ; "--gcp-evidence"
         ; directory
         ]
       = 2));
  let contract = ok "canonical contract" (R.load_contract ~repository) in
  with_temp_dir "cli-aws" (fun aws_dir ->
    with_temp_dir "cli-gcp" (fun gcp_dir ->
      let identity = Filename.concat aws_dir "identity.json" in
      let identity_code =
        Sys.command
          (String.concat
             " "
             (List.map Filename.quote [ bin; "identity"; "--out"; identity ]))
      in
      check "the CLI reports its evaluator identity" (identity_code = 0);
      let evaluator = Yojson.Safe.from_string (read_file identity) in
      ignore
        (write_record
           aws_dir
           contract
           "aws"
           (record_json ~evaluator ~directory:aws_dir ~contract ~provider:"aws" ()));
      ignore
        (write_record
           gcp_dir
           contract
           "gcp"
           (record_json ~evaluator ~directory:gcp_dir ~contract ~provider:"gcp" ()));
      let out = Filename.concat aws_dir "verdict.json" in
      let code =
        run
          [ "evaluate"
          ; "--repository"
          ; repository
          ; "--aws-record"
          ; Filename.concat aws_dir "record.json"
          ; "--aws-evidence"
          ; aws_dir
          ; "--gcp-record"
          ; Filename.concat gcp_dir "record.json"
          ; "--gcp-evidence"
          ; gcp_dir
          ; "--out"
          ; out
          ]
      in
      check "the CLI returns 0 for a verified pair" (code = 0);
      let verdict = Yojson.Safe.from_string (read_file out) in
      check
        "the CLI prints a typed PASS"
        (match verdict with
         | `Assoc fields -> List.assoc_opt "verdict" fields = Some (`String "PASS")
         | _ -> false)))
;;

let test_cli_refusal () =
  let bin = Sys.getenv "SOL_TEST_RELEASE_BIN" in
  let repository = Sys.getenv "SOL_TEST_REPOSITORY" in
  with_temp_dir "cliref-aws" (fun aws_dir ->
    with_temp_dir "cliref-gcp" (fun gcp_dir ->
      let contract = ok "canonical contract" (R.load_contract ~repository) in
      let identity = Filename.concat aws_dir "identity.json" in
      let identity_code =
        Sys.command
          (String.concat
             " "
             (List.map Filename.quote [ bin; "identity"; "--out"; identity ]))
      in
      check "the CLI reports its evaluator identity" (identity_code = 0);
      let evaluator = Yojson.Safe.from_string (read_file identity) in
      ignore
        (write_record
           aws_dir
           contract
           "aws"
           (record_json ~evaluator ~directory:aws_dir ~contract ~provider:"aws" ()));
      let gcp_json =
        record_json
          ~evaluator
          ~harness:(String.make 40 'f')
          ~directory:gcp_dir
          ~contract
          ~provider:"gcp"
          ()
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let quoted =
        List.map
          Filename.quote
          [ bin
          ; "evaluate"
          ; "--repository"
          ; repository
          ; "--aws-record"
          ; Filename.concat aws_dir "record.json"
          ; "--aws-evidence"
          ; aws_dir
          ; "--gcp-record"
          ; Filename.concat gcp_dir "record.json"
          ; "--gcp-evidence"
          ; gcp_dir
          ]
        |> String.concat " "
      in
      check "the CLI returns 1 for a refused pair" (Sys.command quoted = 1)))
;;

let test_replay_other_attempt () =
  let contract = contract () in
  with_temp_dir "replay" (fun directory ->
    ignore (fixture contract "aws" directory);
    replace_line directory "attempt.txt" [ "attempt", "aws-2" ];
    let path = Filename.concat directory "record.json" in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "a record replayed under another attempt identity refuses" true
    | Ok _ -> check "a record replayed under another attempt identity refuses" false)
;;

let test_resumed_attempt () =
  let contract = contract () in
  with_temp_dir "resumed" (fun directory ->
    ignore (fixture contract "aws" directory);
    replace_line directory "attempt.txt" [ "promotion_eligible", "no" ];
    let path = Filename.concat directory "attempt.txt" in
    let contents = read_file path in
    write_file path (contents ^ "resumed_from=/tmp/source\n");
    let path = Filename.concat directory "record.json" in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "a resumed attempt is not release authority" true
    | Ok _ -> check "a resumed attempt is not release authority" false)
;;

let test_provider_mislabeled () =
  let contract = contract () in
  with_temp_dir "mislabeled" (fun directory ->
    let _, json = fixture contract "aws" directory in
    let json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                match key, value with
                | "provider", _ -> key, `String "gcp"
                | "attempt", `Assoc attempt ->
                  ( "attempt"
                  , `Assoc
                      (List.map
                         (fun (field, value) ->
                            if field = "provider"
                            then field, `String "gcp"
                            else field, value)
                         attempt) )
                | _ -> key, value)
             fields)
      | value -> value
    in
    let path = write_record directory contract "aws" json in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "a provider record cannot relabel itself" true
    | Ok _ -> check "a provider record cannot relabel itself" false)
;;

let test_symlink_escape () =
  let contract = contract () in
  with_temp_dir "symlink" (fun directory ->
    ignore (fixture contract "aws" directory);
    let outside =
      Filename.concat (Filename.dirname directory) "qual-release-outside.json"
    in
    write_file outside "{\"outside\":true}\n";
    Fun.protect
      ~finally:(fun () ->
        try Unix.unlink outside with
        | Unix.Unix_error _ -> ())
      (fun () ->
         Unix.symlink outside (Filename.concat directory "escape.json");
         let json =
           match
             Yojson.Safe.from_string (read_file (Filename.concat directory "record.json"))
           with
           | `Assoc fields ->
             `Assoc
               (List.map
                  (fun (key, value) ->
                     if key = "observations"
                     then
                       ( key
                       , match value with
                         | `List (_ :: rest) ->
                           `List
                             (`Assoc
                                [ "id", `String "transaction"
                                ; ( "evidence"
                                  , `List
                                      [ `Assoc
                                          [ "path", `String "escape.json"
                                          ; "sha256", `String (sha256 (read_file outside))
                                          ; "class", `String "behavioral"
                                          ]
                                      ] )
                                ]
                              :: rest)
                         | _ -> value )
                     else key, value)
                  fields)
           | value -> value
         in
         let path = write_record directory contract "aws" json in
         match R.load_record ~contract ~directory ~path with
         | Error _ -> check "a symlink cannot escape the evidence directory" true
         | Ok _ -> check "a symlink cannot escape the evidence directory" false))
;;

let test_claim_order () =
  let contract = contract () in
  with_temp_dir "claimorder-aws" (fun aws_dir ->
    with_temp_dir "claimorder-gcp" (fun gcp_dir ->
      let aws_json = record_json ~directory:aws_dir ~contract ~provider:"aws" () in
      let aws_json =
        match aws_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "claims"
                  then
                    ( key
                    , match value with
                      | `List claims -> `List (List.rev claims)
                      | _ -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record aws_dir contract "aws" aws_json);
      let aws = load aws_dir contract in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      match evaluate contract aws gcp with
      | R.Pass _ -> check "claim order does not change the decision" true
      | R.Refused reasons ->
        check
          ("claim order does not change the decision: " ^ String.concat "; " reasons)
          false))
;;

let test_boundary_required () =
  let contract = contract () in
  with_temp_dir "noboundary" (fun directory ->
    let _, json = fixture contract "aws" directory in
    let json =
      match json with
      | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> key <> "boundary") fields)
      | value -> value
    in
    let path = write_record directory contract "aws" json in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "a record with no typed boundary refuses" true
    | Ok _ -> check "a record with no typed boundary refuses" false)
;;

let test_phase_mechanism () =
  let contract = contract () in
  with_temp_dir "phasemech-aws" (fun aws_dir ->
    with_temp_dir "phasemech-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let gcp_json =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "phases"
                  then
                    ( key
                    , match value with
                      | `List (phase :: rest) ->
                        `List
                          ((match phase with
                            | `Assoc fields ->
                              `Assoc
                                (List.map
                                   (fun (field, value) ->
                                      if field = "evidence"
                                      then
                                        ( field
                                        , `List
                                            [ evidence_ref
                                                gcp_dir
                                                "phase-mechanism.json"
                                                "mechanism"
                                            ] )
                                      else field, value)
                                   fields)
                            | value -> value)
                           :: rest)
                      | _ -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "a phase supported only by mechanism evidence refuses"
        (evaluate contract aws gcp)
        "no behavioural evidence"))
;;

let test_exception_reason_invalidates () =
  let old_contract = contract () in
  with_temp_dir "excreasonchange" (fun directory ->
    let _, json = fixture old_contract "aws" directory in
    let exceptions =
      [ `Assoc
          [ "family", `String "destroy-preparation"
          ; "provider", `String "gcp"
          ; "reason", `String "a different reason"
          ; "test", `String test_path
          ]
      ]
    in
    let changed =
      ok
        "changed exception"
        (R.contract_of_json (contract_json ~exceptions:(Some exceptions) ()))
    in
    check
      "changing an exception reason changes the contract identity"
      (contract_digest old_contract <> contract_digest changed);
    let path = write_record directory old_contract "aws" json in
    match R.load_record ~contract:changed ~directory ~path with
    | Error _ -> check "changing an exception reason invalidates old records" true
    | Ok _ -> check "changing an exception reason invalidates old records" false)
;;

let test_ledger_order () =
  let contract = contract () in
  with_temp_dir "ledger-order" (fun directory ->
    ignore (fixture contract "aws" directory);
    write_file
      (Filename.concat directory "phase-verdicts.txt")
      (String.concat
         "\n"
         [ "phase=prepare exit=0 at=2026-10-25T00:00:00Z"
         ; "phase=app exit=0 at=2026-10-25T00:01:00Z"
         ; "phase=cloud exit=0 at=2026-10-25T00:02:00Z"
         ; "phase=destroy exit=0 at=2026-10-25T00:03:00Z"
         ]
       ^ "\n");
    let path = Filename.concat directory "record.json" in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "a reordered attempt ledger refuses" true
    | Ok _ -> check "a reordered attempt ledger refuses" false)
;;

let test_attempt_issuer_mismatch () =
  let contract = contract () in
  with_temp_dir "issuer-aws" (fun aws_dir ->
    with_temp_dir "issuer-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let gcp_json =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "attempt"
                  then
                    ( key
                    , match value with
                      | `Assoc attempt ->
                        `Assoc
                          (List.map
                             (fun (field, value) ->
                                if field = "issuer"
                                then field, `String "letsencrypt-staging"
                                else field, value)
                             attempt)
                      | value -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      replace_line gcp_dir "attempt.txt" [ "issuer", "letsencrypt-staging" ];
      let gcp = load gcp_dir contract in
      has_reason
        "an attempt issuer outside the contract refuses"
        (evaluate contract aws gcp)
        "attempt issuer"))
;;

let test_claim_missing_one () =
  let contract = contract () in
  with_temp_dir "missingone-aws" (fun aws_dir ->
    with_temp_dir "missingone-gcp" (fun gcp_dir ->
      let aws_json = record_json ~directory:aws_dir ~contract ~provider:"aws" () in
      let aws_json =
        match aws_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "claims"
                  then
                    ( key
                    , match value with
                      | `List claims ->
                        `List
                          (List.filter
                             (fun claim ->
                                match claim with
                                | `Assoc fields ->
                                  List.assoc_opt "id" fields <> Some (`String "I8")
                                | _ -> true)
                             claims)
                      | _ -> value )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record aws_dir contract "aws" aws_json);
      let aws = load aws_dir contract in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      has_reason
        "a deliberately omitted required claim refuses"
        (evaluate contract aws gcp)
        "not the contract's"))
;;

let test_provider_slot () =
  let contract = contract () in
  with_temp_dir "slot-aws" (fun aws_dir ->
    with_temp_dir "slot-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      has_reason
        "a record in the wrong provider slot refuses"
        (evaluate contract gcp aws)
        "slot contains"))
;;

let test_unloaded_contract_cannot_pass () =
  let synthetic = ok "synthetic contract" (R.contract_of_json (contract_json ())) in
  with_temp_dir "unloaded-aws" (fun aws_dir ->
    with_temp_dir "unloaded-gcp" (fun gcp_dir ->
      let aws, _ = fixture synthetic "aws" aws_dir in
      let gcp, _ = fixture synthetic "gcp" gcp_dir in
      has_reason
        "a parser-constructed contract cannot issue a PASS"
        (evaluate synthetic aws gcp)
        "repository-owned source"))
;;

let test_contract_substitution () =
  with_temp_dir "contract-substitution" (fun directory ->
    let path = Filename.concat directory R.canonical_contract_path in
    mkdir_p (Filename.dirname path);
    let weakened =
      contract_json
        ~claims:
          (Some
             [ `Assoc
                 [ "family", `String "application-transaction"
                 ; "evidence_class", `String "behavioral"
                 ; "test", `String "internal/qualification/local/test-rows-ocaml.sh"
                 ; "ids", `Assoc [ "aws", `String "B1"; "gcp", `String "B1" ]
                 ]
             ])
        ~exceptions:(Some [])
        ()
    in
    write_file path (Yojson.Safe.pretty_to_string weakened ^ "\n");
    match R.load_contract ~repository:directory with
    | Error error ->
      let diagnostic = error.R.diagnostic in
      let needle = "reviewed pin" in
      let rec contains index =
        index + String.length needle <= String.length diagnostic
        && (String.sub diagnostic index (String.length needle) = needle
            || contains (index + 1))
      in
      check
        "a structurally valid weakened contract refuses against the evaluator pin"
        (contains 0)
    | Ok _ ->
      check
        "a structurally valid weakened contract refuses against the evaluator pin"
        false)
;;

let test_contract_provider_without_claim () =
  let claims =
    [ `Assoc
        [ "family", `String "application-transaction"
        ; "evidence_class", `String "behavioral"
        ; "test", `String "internal/qualification/local/test-rows-ocaml.sh"
        ; "ids", `Assoc [ "aws", `String "B1" ]
        ]
    ]
  in
  let exceptions =
    [ `Assoc
        [ "family", `String "application-transaction"
        ; "provider", `String "gcp"
        ; "reason", `String "no GCP claim"
        ; "test", `String test_path
        ]
    ]
  in
  match
    R.contract_of_json
      (contract_json ~claims:(Some claims) ~exceptions:(Some exceptions) ())
  with
  | Error _ -> check "an exception-only provider is refused as unsatisfiable" true
  | Ok _ -> check "an exception-only provider is refused as unsatisfiable" false
;;

let test_unverified_record_cannot_pass () =
  let contract = contract () in
  with_temp_dir "unverified-aws" (fun aws_dir ->
    with_temp_dir "unverified-gcp" (fun gcp_dir ->
      let aws_json = record_json ~directory:aws_dir ~contract ~provider:"aws" () in
      let aws = ok "parse-only aws record" (R.record_of_json ~contract aws_json) in
      let gcp, _ = fixture contract "gcp" gcp_dir in
      has_reason
        "a parsed but unverified record cannot pass"
        (evaluate contract aws gcp)
        "not loaded and evidence-verified"))
;;

let test_evaluator_source_revision_mismatch () =
  let contract = contract () in
  with_temp_dir "evalsrc-aws" (fun aws_dir ->
    with_temp_dir "evalsrc-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json =
        record_json
          ~evaluator:(evaluator_json ~source_revision:(String.make 40 'b') ())
          ~directory:gcp_dir
          ~contract
          ~provider:"gcp"
          ()
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "an evaluator built from another source revision refuses"
        (evaluate contract aws gcp)
        "not produced by this evaluator"))
;;

let test_emit_record () =
  let contract = contract () in
  with_temp_dir "emit-record" (fun directory ->
    ignore (fixture contract "aws" directory);
    let candidate_path = Filename.concat directory "candidate.json" in
    write_file candidate_path (Yojson.Safe.pretty_to_string (candidate ()) ^ "\n");
    let manifest =
      `Assoc
        [ "provider", `String "aws"
        ; "harness_revision", `String harness
        ; ( "selection"
          , `Assoc
              [ "languages", `List [ `String "ocaml"; `String "typescript" ]
              ; "primitives", `List [ `String "svc"; `String "worker" ]
              ] )
        ; ( "profile"
          , `Assoc
              [ "kind", `String "production-single-region/v1"
              ; "observations", `List [ `String "profile" ]
              ] )
        ; ( "boundary"
          , `Assoc
              [ "kind", `String "artifact-gate"
              ; "observations", `List [ `String "boundary" ]
              ] )
        ; ( "permission_binding"
          , `Assoc
              [ "deploy_identity", `String "sol-deploy-aws"
              ; "mechanism", `String "direct"
              ; "subject", `String "arn:aws:iam::123456789012:role/sol-deploy"
              ; "observations", `List [ `String "permission" ]
              ] )
        ; ( "phases"
          , `List
              (List.map
                 (fun name ->
                    `Assoc
                      [ "name", `String name
                      ; ( "evidence"
                        , `List
                            [ `Assoc
                                [ "path", `String ("phase-" ^ name ^ ".json")
                                ; "class", `String "behavioral"
                                ]
                            ] )
                      ])
                 [ "prepare"; "cloud"; "app"; "destroy" ]) )
        ; ( "observations"
          , `List
              (List.map
                 (fun id ->
                    `Assoc
                      [ "id", `String id
                      ; ( "evidence"
                        , `List
                            [ `Assoc
                                [ "path", `String (id ^ ".json")
                                ; "class", `String "behavioral"
                                ]
                            ] )
                      ])
                 [ "transaction"; "profile"; "boundary"; "permission" ]) )
        ; ( "claims"
          , `List
              [ `Assoc
                  [ "id", `String "B1"
                  ; "status", `String "pass"
                  ; "observations", `List [ `String "transaction" ]
                  ]
              ; `Assoc
                  [ "id", `String "I8"
                  ; "status", `String "pass"
                  ; "observations", `List [ `String "transaction" ]
                  ]
              ] )
        ]
    in
    let manifest_path = Filename.concat directory "manifest.json" in
    write_file manifest_path (Yojson.Safe.pretty_to_string manifest ^ "\n");
    let out = Filename.concat directory "produced-record.json" in
    let bin = Sys.getenv "SOL_TEST_RELEASE_BIN" in
    let repository = Sys.getenv "SOL_TEST_REPOSITORY" in
    let command =
      String.concat
        " "
        (List.map
           Filename.quote
           [ bin
           ; "emit-record"
           ; "--repository"
           ; repository
           ; "--attempt-dir"
           ; directory
           ; "--candidate"
           ; candidate_path
           ; "--manifest"
           ; manifest_path
           ; "--out"
           ; out
           ])
    in
    check "the producer emits a record" (Sys.command command = 0);
    match R.load_record ~contract ~directory ~path:out with
    | Ok _ -> check "the emitted record passes the v2 loader" true
    | Error error ->
      check ("the emitted record passes the v2 loader: " ^ error_text error) false)
;;

let remove_top_level key json =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (name, _) -> name <> key) fields)
  | value -> value
;;

let test_contract_profile_required () =
  let without = remove_top_level "profile" (contract_json ()) in
  (match R.contract_of_json without with
   | Error _ -> check "a contract without a deployment profile refuses" true
   | Ok _ -> check "a contract without a deployment profile refuses" false);
  let unknown =
    match contract_json () with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if key = "profile" then key, `String "durable" else key, value)
           fields)
    | value -> value
  in
  match R.contract_of_json unknown with
  | Error _ -> check "an untyped/durable profile cannot be the contract profile" true
  | Ok _ -> check "an untyped/durable profile cannot be the contract profile" false
;;

let test_record_profile_required () =
  let contract = contract () in
  with_temp_dir "profile-missing" (fun directory ->
    let _, json = fixture contract "aws" directory in
    let path = write_record directory contract "aws" (remove_top_level "profile" json) in
    (match R.load_record ~contract ~directory ~path with
     | Error _ -> check "a record without a typed profile refuses" true
     | Ok _ -> check "a record without a typed profile refuses" false);
    let durable =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if key = "profile"
                then
                  ( key
                  , `Assoc
                      [ "kind", `String "durable"
                      ; "observations", `List [ `String "profile" ]
                      ] )
                else key, value)
             fields)
      | value -> value
    in
    let path = write_record directory contract "aws" durable in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "a durable-shape record cannot satisfy the production profile" true
    | Ok _ -> check "a durable-shape record cannot satisfy the production profile" false)
;;

let test_profile_observations_required () =
  let contract = contract () in
  with_temp_dir "profile-observer-aws" (fun aws_dir ->
    with_temp_dir "profile-observer-gcp" (fun gcp_dir ->
      let aws, _ = fixture contract "aws" aws_dir in
      let gcp_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let gcp_json =
        match gcp_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  if key = "profile"
                  then
                    ( key
                    , `Assoc
                        [ "kind", `String "production-single-region/v1"
                        ; "observations", `List []
                        ] )
                  else key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" gcp_json);
      let gcp = load gcp_dir contract in
      has_reason
        "a profile with no observation refuses"
        (evaluate contract aws gcp)
        "profile names no observations";
      let mech_json = record_json ~directory:gcp_dir ~contract ~provider:"gcp" () in
      let mech_json =
        match mech_json with
        | `Assoc fields ->
          `Assoc
            (List.map
               (fun (key, value) ->
                  match key, value with
                  | "observations", `List observations ->
                    ( "observations"
                    , `List
                        (`Assoc
                           [ "id", `String "profile-mechanism"
                           ; ( "evidence"
                             , `List
                                 [ evidence_ref
                                     gcp_dir
                                     "profile-mechanism.json"
                                     "mechanism"
                                 ] )
                           ]
                         :: observations) )
                  | "profile", `Assoc _ ->
                    ( "profile"
                    , `Assoc
                        [ "kind", `String "production-single-region/v1"
                        ; "observations", `List [ `String "profile-mechanism" ]
                        ] )
                  | _ -> key, value)
               fields)
        | value -> value
      in
      ignore (write_record gcp_dir contract "gcp" mech_json);
      let gcp = load gcp_dir contract in
      match evaluate contract aws gcp with
      | R.Pass _ -> check "mechanism evidence establishes the declared profile" true
      | R.Refused reasons ->
        check
          ("mechanism evidence establishes the declared profile: "
           ^ String.concat "; " reasons)
          false))
;;

let test_duplicate_evidence () =
  let contract = contract () in
  with_temp_dir "duplicate-evidence" (fun directory ->
    let _, json = fixture contract "aws" directory in
    let json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if key <> "observations"
                then key, value
                else
                  ( key
                  , match value with
                    | `List (observation :: rest) ->
                      `List
                        ((match observation with
                          | `Assoc fields ->
                            `Assoc
                              (List.map
                                 (fun (field, value) ->
                                    if field <> "evidence"
                                    then field, value
                                    else
                                      ( field
                                      , match value with
                                        | `List (entry :: _) -> `List [ entry; entry ]
                                        | _ -> value ))
                                 fields)
                          | value -> value)
                         :: rest)
                    | _ -> value ))
             fields)
      | value -> value
    in
    let path = write_record directory contract "aws" json in
    match R.load_record ~contract ~directory ~path with
    | Error _ -> check "a repeated evidence reference refuses" true
    | Ok _ -> check "a repeated evidence reference refuses" false)
;;

let tests () =
  [ "valid pair", test_valid_pair
  ; "contract profile required", test_contract_profile_required
  ; "record profile required", test_record_profile_required
  ; "profile observations required", test_profile_observations_required
  ; "unloaded contract", test_unloaded_contract_cannot_pass
  ; "emit record", test_emit_record
  ; "contract substitution", test_contract_substitution
  ; "provider without claim", test_contract_provider_without_claim
  ; "unverified record", test_unverified_record_cannot_pass
  ; "one-provider contract", test_one_provider_contract
  ; "missing phase contract", test_missing_phase_contract
  ; "claim without provider", test_claim_without_provider
  ; "mapped claim and exception", test_mapped_and_exception
  ; "missing evidence", test_evidence_missing
  ; "altered evidence", test_evidence_digest
  ; "evidence path", test_evidence_path
  ; "duplicate JSON key", test_record_duplicate_key
  ; "attempt drift", test_attempt_drift
  ; "attempt candidate drift", test_attempt_candidate_drift
  ; "contract digest drift", test_contract_digest_drift
  ; "contract change", test_contract_change_invalidates
  ; "candidate mismatch", test_candidate_mismatch
  ; "harness mismatch", test_harness_mismatch
  ; "evaluator mismatch", test_evaluator_mismatch
  ; "record evaluator mismatch", test_record_evaluator_mismatch
  ; "evaluator source revision mismatch", test_evaluator_source_revision_mismatch
  ; "same attempt", test_same_attempt
  ; "selection lower bound", test_selection_lower_bound
  ; "selection mismatch", test_selection_mismatch
  ; "selection order", test_selection_order
  ; "missing claim", test_claim_missing
  ; "missing one required claim", test_claim_missing_one
  ; "provider slot", test_provider_slot
  ; "extra claim", test_claim_extra
  ; "claim without observation", test_claim_no_observation
  ; "mechanism-only claim", test_claim_mechanism_only
  ; "reordered phases", test_phases
  ; "missing phase", test_phase_missing
  ; "boundary and permission", test_boundary_and_permission
  ; "excluded without exception", test_excluded_without_exception
  ; "exception visible", test_exception_reason_drift
  ; "duplicate selection", test_selection_duplicate
  ; "duplicate evidence", test_duplicate_evidence
  ; "replay other attempt", test_replay_other_attempt
  ; "resumed attempt", test_resumed_attempt
  ; "provider mislabeled", test_provider_mislabeled
  ; "symlink escape", test_symlink_escape
  ; "claim order", test_claim_order
  ; "boundary required", test_boundary_required
  ; "phase mechanism", test_phase_mechanism
  ; "exception reason invalidates", test_exception_reason_invalidates
  ; "ledger order", test_ledger_order
  ; "attempt issuer", test_attempt_issuer_mismatch
  ; "CLI", test_cli
  ; "CLI refusal", test_cli_refusal
  ]
;;

let () =
  Alcotest.run
    "qualification release authority"
    [ ( "adversarial"
      , List.map (fun (name, test) -> Alcotest.test_case name `Quick test) (tests ()) )
    ]
;;
