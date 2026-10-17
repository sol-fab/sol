let policy : Sol_jobs.retry_policy =
  { base_delay_s = 1.0; max_delay_s = 10.0; max_attempts = -1; jitter_ratio = 0.2 }
;;

let test_backoff_s_early_attempt_within_jittered_bounds () =
  let rng = Random.State.make [| 42 |] in
  let raw = policy.base_delay_s *. (2. ** Float.of_int (2 - 1)) in
  let delay = Sol_jobs.For_testing.backoff_s ~rng policy ~attempt:2 in
  Windtrap.equal
    Windtrap.bool
    ~msg:"within +-20% of the raw exponential delay"
    true
    (delay >= raw *. 0.8 && delay <= raw *. 1.2)
;;

let test_backoff_s_caps_at_max_delay () =
  let rng = Random.State.make [| 7 |] in
  for attempt = 1 to 30 do
    let delay = Sol_jobs.For_testing.backoff_s ~rng policy ~attempt in
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "attempt %d never exceeds max_delay_s" attempt)
      true
      (delay <= policy.max_delay_s)
  done
;;

let test_backoff_s_never_negative () =
  let rng = Random.State.make [| 99 |] in
  for attempt = 1 to 10 do
    let delay = Sol_jobs.For_testing.backoff_s ~rng policy ~attempt in
    Windtrap.equal
      Windtrap.bool
      ~msg:(Printf.sprintf "attempt %d never negative" attempt)
      true
      (delay >= 0.0)
  done
;;

let test_backoff_s_deterministic_with_same_seed () =
  let delay1 =
    Sol_jobs.For_testing.backoff_s ~rng:(Random.State.make [| 5 |]) policy ~attempt:3
  in
  let delay2 =
    Sol_jobs.For_testing.backoff_s ~rng:(Random.State.make [| 5 |]) policy ~attempt:3
  in
  Windtrap.equal (Windtrap.float 0.0) ~msg:"same seed, same delay" delay1 delay2
;;

let test_backoff_s_no_jitter_when_ratio_zero () =
  let policy = { policy with jitter_ratio = 0.0 } in
  let rng = Random.State.make [| 1 |] in
  Windtrap.equal
    (Windtrap.float 0.0001)
    ~msg:"exact exponential delay"
    2.0
    (Sol_jobs.For_testing.backoff_s ~rng policy ~attempt:2)
;;

let test_validate_retry_policy_rejects_zero_max_attempts () =
  let policy = { Sol_jobs.default_retry_policy with max_attempts = 0 } in
  Windtrap.equal
    Windtrap.bool
    ~msg:"Error `Config"
    true
    (match Sol_jobs.For_testing.validate_retry_policy policy with
     | Error (`Config _) -> true
     | Error (`Database _) | Ok () -> false)
;;

let test_validate_workspace () =
  let ok value = Result.is_ok (Sol_jobs.For_testing.validate_workspace value) in
  Windtrap.equal Windtrap.bool ~msg:"a plain name is accepted" true (ok "myapp");
  Windtrap.equal
    Windtrap.bool
    ~msg:"dots, dashes and case are accepted"
    true
    (ok "My_App.v2-x");
  Windtrap.equal Windtrap.bool ~msg:"empty is refused" false (ok "");
  Windtrap.equal Windtrap.bool ~msg:"whitespace only is refused" false (ok "   ");
  Windtrap.equal Windtrap.bool ~msg:"an inner space is refused" false (ok "my app");
  Windtrap.equal Windtrap.bool ~msg:"a slash is refused" false (ok "my/app");
  Windtrap.equal
    Windtrap.bool
    ~msg:"over 63 characters is refused"
    false
    (ok (String.make 64 'a'))
;;

let test_validate_kinds () =
  let ok kinds = Result.is_ok (Sol_jobs.For_testing.validate_kinds kinds) in
  Windtrap.equal
    Windtrap.bool
    ~msg:"typical kinds accepted"
    true
    (ok [ "send_email"; "report.v2-x" ]);
  Windtrap.equal Windtrap.bool ~msg:"empty list refused" false (ok []);
  Windtrap.equal Windtrap.bool ~msg:"empty kind refused" false (ok [ "a"; "" ]);
  Windtrap.equal Windtrap.bool ~msg:"separator refused" false (ok [ "a,b" ]);
  Windtrap.equal Windtrap.bool ~msg:"uppercase refused" false (ok [ "SendEmail" ])
;;

let test_validate_retry_policy_accepts_positive_and_negative () =
  let accepts max_attempts =
    match
      Sol_jobs.For_testing.validate_retry_policy
        { Sol_jobs.default_retry_policy with max_attempts }
    with
    | Ok () -> true
    | Error _ -> false
  in
  Windtrap.equal Windtrap.bool ~msg:"positive max_attempts accepted" true (accepts 5);
  Windtrap.equal
    Windtrap.bool
    ~msg:"negative (unlimited) max_attempts accepted"
    true
    (accepts (-1))
;;

let test_validate_retry_policy_rejects_invalid_timings () =
  let rejected policy =
    match Sol_jobs.For_testing.validate_retry_policy policy with
    | Error (`Config _) -> true
    | Error (`Database _) | Ok () -> false
  in
  let base = Sol_jobs.default_retry_policy in
  Windtrap.equal
    Windtrap.bool
    ~msg:"negative base_delay_s"
    true
    (rejected { base with base_delay_s = -1.0 });
  Windtrap.equal
    Windtrap.bool
    ~msg:"nan base_delay_s"
    true
    (rejected { base with base_delay_s = Float.nan });
  Windtrap.equal
    Windtrap.bool
    ~msg:"infinite max_delay_s"
    true
    (rejected { base with max_delay_s = Float.infinity });
  Windtrap.equal
    Windtrap.bool
    ~msg:"negative max_delay_s"
    true
    (rejected { base with max_delay_s = -10.0 });
  Windtrap.equal
    Windtrap.bool
    ~msg:"jitter above 1"
    true
    (rejected { base with jitter_ratio = 2.0 });
  Windtrap.equal
    Windtrap.bool
    ~msg:"negative jitter"
    true
    (rejected { base with jitter_ratio = -0.5 });
  Windtrap.equal
    Windtrap.bool
    ~msg:"nan jitter"
    true
    (rejected { base with jitter_ratio = Float.nan });
  Windtrap.equal
    Windtrap.bool
    ~msg:"zero retry delays accepted"
    true
    (not (rejected { base with base_delay_s = 0.0; max_delay_s = 0.0 }));
  Windtrap.equal
    Windtrap.bool
    ~msg:"the default policy is accepted"
    true
    (not (rejected base))
;;

let test_validate_timing () =
  let accepted ~poll ~lease =
    match Sol_jobs.For_testing.validate_timing ~poll_interval_s:poll ~lease_s:lease with
    | Ok () -> true
    | Error _ -> false
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"defaults accepted"
    true
    (accepted ~poll:1.0 ~lease:300.0);
  Windtrap.equal
    Windtrap.bool
    ~msg:"zero poll refused"
    false
    (accepted ~poll:0.0 ~lease:300.0);
  Windtrap.equal
    Windtrap.bool
    ~msg:"negative poll refused"
    false
    (accepted ~poll:(-1.0) ~lease:300.0);
  Windtrap.equal
    Windtrap.bool
    ~msg:"nan poll refused"
    false
    (accepted ~poll:Float.nan ~lease:300.0);
  Windtrap.equal
    Windtrap.bool
    ~msg:"infinite poll refused"
    false
    (accepted ~poll:Float.infinity ~lease:300.0);
  Windtrap.equal
    Windtrap.bool
    ~msg:"zero lease refused"
    false
    (accepted ~poll:1.0 ~lease:0.0);
  Windtrap.equal
    Windtrap.bool
    ~msg:"negative lease refused"
    false
    (accepted ~poll:1.0 ~lease:(-5.0));
  Windtrap.equal
    Windtrap.bool
    ~msg:"nan lease refused"
    false
    (accepted ~poll:1.0 ~lease:Float.nan)
;;

module Email = struct
  type t = string

  let workspace = "test"
  let kind (_ : t) = "send_email"
  let kinds = [ "send_email" ]
  let encode t = t
  let decode s = Ok s
  let handle (_ : t) = Ok ()
end

module Emails = Sol_jobs.Make (Email)

let test_invalid_timing_fails_before_database_or_signals () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  match
    Pg_db.create_pool
      ~url:"postgresql://127.0.0.1:1/unused"
      ~sw
      ~stdenv:(env :> Caqti_eio.stdenv)
      ()
  with
  | Error e -> Windtrap.failf "pool: %s" (Pg_error.to_string e)
  | Ok pool ->
    List.iter
      (fun seconds ->
         match Emails.run ~env ~pool ~execution_timeout_s:seconds () with
         | Error (`Config msg) ->
           Windtrap.equal
             Windtrap.bool
             true
             (Sol_runtime.contains_substring ~needle:"execution_timeout_s" msg)
         | _ -> Windtrap.fail "invalid execution deadline touched the database")
      [ 0.0; -1.0; nan; infinity ];
    (match Emails.run ~env ~pool ~lease_s:0.0 () with
     | Error (`Config msg) ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"names lease_s"
         true
         (Sol_runtime.contains_substring ~needle:"lease_s" msg)
     | Error (`Database m) -> Windtrap.failf "expected a Config error, got Database: %s" m
     | Ok () -> Windtrap.fail "an invalid lease must not start the poller")
;;

let () =
  let open Windtrap in
  run
    "sol_jobs"
    [ Windtrap.group
        "kinds"
        [ test "validate_kinds" test_validate_kinds
        ; test
            "validate_workspace accepts a name and refuses the rest (BUG-115)"
            test_validate_workspace
        ]
    ; Windtrap.group
        "backoff_s"
        [ test
            "early attempt within jittered bounds"
            test_backoff_s_early_attempt_within_jittered_bounds
        ; test "caps at max delay" test_backoff_s_caps_at_max_delay
        ; test "never negative" test_backoff_s_never_negative
        ; test
            "deterministic with the same seed"
            test_backoff_s_deterministic_with_same_seed
        ; test "no jitter when jitter_ratio is 0" test_backoff_s_no_jitter_when_ratio_zero
        ]
    ; Windtrap.group
        "validate_retry_policy"
        [ test
            "rejects max_attempts = 0"
            test_validate_retry_policy_rejects_zero_max_attempts
        ; test
            "accepts positive and negative max_attempts"
            test_validate_retry_policy_accepts_positive_and_negative
        ; test
            "rejects nonfinite or out-of-range timing (CODEX_STYLE_AUDIT-079)"
            test_validate_retry_policy_rejects_invalid_timings
        ]
    ; Windtrap.group
        "validate_timing"
        [ test
            "accepts positive, refuses nonpositive or nonfinite (CODEX_STYLE_AUDIT-079)"
            test_validate_timing
        ]
    ; Windtrap.group
        "config boundary"
        [ test
            "invalid timing is Config before the pool (CODEX_STYLE_AUDIT-079)"
            test_invalid_timing_fails_before_database_or_signals
        ]
    ]
;;
