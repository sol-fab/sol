module L = Qual_lifecycle

let check message condition = if not condition then Alcotest.fail message
let verdict phase exit_code = { L.phase; exit_code; at = Some "2026-10-24T00:00:00Z" }

let attempt ?(resumed = false) ?(eligible = true) verdicts =
  { L.provenance =
      { attempt = "a1"
      ; claim = "production"
      ; issuer = "letsencrypt-prod"
      ; resumed_from = (if resumed then Some "/tmp/source" else None)
      ; promotion_eligible = eligible
      }
  ; verdicts
  }
;;

let complete ?(resumed = false) ?(eligible = true) () =
  [ verdict L.Prepare 0; verdict L.Cloud 0; verdict L.App 0; verdict L.Destroy 0 ]
  |> attempt ~resumed ~eligible
;;

let test_complete () =
  let result = L.assess (complete ()) in
  check "complete production is eligible" result.eligible;
  check "required phases pass" result.required_phases_ok;
  match result.continuity with
  | L.Continuous -> ()
  | L.Resumed _ -> Alcotest.fail "not resumed"
;;

let test_staging () =
  let result = L.assess (complete ~eligible:false ()) in
  check "staging is not eligible" (not result.eligible);
  check "phases still pass" result.required_phases_ok;
  check
    "claim reason"
    (List.exists
       (function
         | L.Not_promotion_eligible _ -> true
         | _ -> false)
       result.reasons)
;;

let test_repeated () =
  let a = complete () in
  let result = L.assess { a with L.verdicts = a.verdicts @ [ List.hd a.verdicts ] } in
  check "repeated phase is not eligible" (not result.eligible);
  check "repeated phase fails required sequence" (not result.required_phases_ok)
;;

let test_failed () =
  let result =
    L.assess
      (attempt
         [ verdict L.Prepare 0; verdict L.Cloud 0; verdict L.App 1; verdict L.Destroy 0 ])
  in
  check "failed phase is not eligible" (not result.eligible);
  check "failed phase fails required sequence" (not result.required_phases_ok)
;;

let test_missing () =
  let result =
    L.assess (attempt [ verdict L.Prepare 0; verdict L.Cloud 0; verdict L.App 0 ])
  in
  check "missing phase is not eligible" (not result.eligible);
  check "missing phase fails required sequence" (not result.required_phases_ok)
;;

let test_resumed () =
  let result = L.assess (complete ~resumed:true ()) in
  check "resume is not eligible" (not result.eligible);
  match result.continuity with
  | L.Resumed _ -> ()
  | L.Continuous -> Alcotest.fail "resume not recorded"
;;

let with_temp_dir f =
  let dir = Filename.temp_file "qual-lifecycle" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () -> f dir)
;;

let write path lines =
  Out_channel.with_open_text path (fun output ->
    List.iter (fun line -> output_string output (line ^ "\n")) lines)
;;

let test_of_dir () =
  with_temp_dir (fun dir ->
    write
      (Filename.concat dir "attempt.txt")
      [ "attempt=a1"
      ; "claim=production"
      ; "issuer=letsencrypt-prod"
      ; "promotion_eligible=yes"
      ];
    write
      (Filename.concat dir "phase-verdicts.txt")
      [ "phase=prepare exit=0 at=x"
      ; "phase=cloud exit=0 at=x"
      ; "phase=app exit=0 at=x"
      ; "phase=destroy exit=0 at=x"
      ];
    match L.of_dir dir with
    | Error message -> Alcotest.fail message
    | Ok parsed ->
      let result = L.assess parsed in
      check "parsed complete attempt is eligible" result.eligible)
;;

let test_of_dir_unknown_phase () =
  with_temp_dir (fun dir ->
    write
      (Filename.concat dir "attempt.txt")
      [ "attempt=a1"
      ; "claim=production"
      ; "issuer=letsencrypt-prod"
      ; "promotion_eligible=yes"
      ];
    write (Filename.concat dir "phase-verdicts.txt") [ "phase=deploy exit=0 at=x" ];
    check "unknown phase is refused" (Result.is_error (L.of_dir dir)))
;;

let test_duplicate_identity_field () =
  with_temp_dir (fun dir ->
    write
      (Filename.concat dir "attempt.txt")
      [ "attempt=a1"
      ; "claim=production"
      ; "claim=mechanism-only"
      ; "issuer=letsencrypt-prod"
      ; "promotion_eligible=yes"
      ];
    write (Filename.concat dir "phase-verdicts.txt") [];
    check "duplicate identity field is refused" (Result.is_error (L.of_dir dir)))
;;

let test_duplicate_verdict_field () =
  with_temp_dir (fun dir ->
    write
      (Filename.concat dir "attempt.txt")
      [ "attempt=a1"
      ; "claim=production"
      ; "issuer=letsencrypt-prod"
      ; "promotion_eligible=yes"
      ];
    write
      (Filename.concat dir "phase-verdicts.txt")
      [ "phase=prepare exit=0 exit=1 at=x" ];
    check "duplicate verdict field is refused" (Result.is_error (L.of_dir dir)))
;;

let test_inconsistent_recorded_claim () =
  with_temp_dir (fun dir ->
    write
      (Filename.concat dir "attempt.txt")
      [ "attempt=a1"
      ; "claim=production"
      ; "issuer=letsencrypt-prod"
      ; "promotion_eligible=no"
      ];
    write (Filename.concat dir "phase-verdicts.txt") [ "phase=prepare exit=0 at=x" ];
    check "inconsistent recorded claim is refused" (Result.is_error (L.of_dir dir)))
;;

let test_resumed_production_is_valid_but_not_eligible () =
  with_temp_dir (fun dir ->
    write
      (Filename.concat dir "attempt.txt")
      [ "attempt=a1"
      ; "claim=production"
      ; "issuer=letsencrypt-prod"
      ; "promotion_eligible=no"
      ; "resumed_from=/tmp/source"
      ];
    write
      (Filename.concat dir "phase-verdicts.txt")
      [ "phase=prepare exit=0 at=x"
      ; "phase=cloud exit=0 at=x"
      ; "phase=app exit=0 at=x"
      ; "phase=destroy exit=0 at=x"
      ];
    match L.of_dir dir with
    | Error message -> Alcotest.fail message
    | Ok parsed ->
      check "resumed production remains ineligible" (not (L.assess parsed).eligible))
;;

let test_parse_unknown_phase () =
  check "unknown phase is refused" (Result.is_error (L.phase_of_string "deploy"))
;;

let () =
  Alcotest.run
    "qualification lifecycle"
    [ ( "assessment"
      , [ Alcotest.test_case "complete" `Quick test_complete
        ; Alcotest.test_case "staging" `Quick test_staging
        ; Alcotest.test_case "repeated" `Quick test_repeated
        ; Alcotest.test_case "failed" `Quick test_failed
        ; Alcotest.test_case "missing" `Quick test_missing
        ; Alcotest.test_case "resumed" `Quick test_resumed
        ; Alcotest.test_case "unknown phase" `Quick test_parse_unknown_phase
        ; Alcotest.test_case "parse attempt directory" `Quick test_of_dir
        ; Alcotest.test_case
            "reject unknown parsed phase"
            `Quick
            test_of_dir_unknown_phase
        ; Alcotest.test_case
            "duplicate identity field"
            `Quick
            test_duplicate_identity_field
        ; Alcotest.test_case "duplicate verdict field" `Quick test_duplicate_verdict_field
        ; Alcotest.test_case
            "inconsistent recorded claim"
            `Quick
            test_inconsistent_recorded_claim
        ; Alcotest.test_case
            "resumed production"
            `Quick
            test_resumed_production_is_valid_but_not_eligible
        ] )
    ]
;;
