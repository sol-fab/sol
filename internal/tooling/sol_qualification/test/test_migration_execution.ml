(* Qualification-owned launcher boundary. A fake installed candidate speaks the
   private receipt protocol so validation, the observation window and the release
   of the product's own cleanup are exercised without a live provider. The
   authority-bearing [run] path is exercised against a real verified candidate in
   test_candidate_boundary.py. *)
module D = Qual_domain
module Q = Qual_migration_execution

let get = function
  | Ok x -> x
  | Error e -> Alcotest.fail e
;;

let check b text = if not b then Alcotest.fail text

let write path text =
  Sol_cli_fs.mkdir_p (Filename.dirname path) |> get;
  Out_channel.with_open_text path (fun c -> output_string c text);
  Unix.chmod path 0o755
;;

let fake_sol =
  {|#!/usr/bin/env python3
import json, os, time
binding = os.environ["SOL_MIGRATION_EXECUTION_BINDING"]
message = (
    {"schema": 1, "kind": "NoExecution", "reason": "no migration files found"}
    if os.environ.get("FAKE_NO_EXECUTION") == "1"
    else {"schema": 1, "kind": "Unavailable"}
    if os.environ.get("FAKE_UNAVAILABLE") == "1"
    else {
        "schema": 1,
        "kind": "MigrationExecution",
        "binding": os.environ.get("FAKE_BINDING", binding),
        "target": os.environ["FAKE_TARGET"],
        "namespace": "database-system",
        "name": "sol-migrate-fake",
        "uid": "submission-uid-7",
        "principal": os.environ["FAKE_PRINCIPAL"],
        "cluster": os.environ["FAKE_CLUSTER"],
        "endpoint": os.environ["FAKE_ENDPOINT"],
        "observed_at": 1,
    }
)
os.write(0, (json.dumps(message) + "\n").encode())
with open(os.environ["FAKE_BLOCKED_MARKER"], "w") as handle:
    handle.write("blocked")
ack = os.read(0, 64).decode().strip()
with open(os.environ["FAKE_ACK_MARKER"], "w") as handle:
    handle.write(ack)
if os.environ.get("FAKE_HANG_AFTER_ACK") == "1":
    time.sleep(3600)
|}
;;

let fake_producer =
  {|#!/usr/bin/env python3
import os, sys
if sys.argv[1:2] == ["migration-receipt-protocol"]:
    print(os.environ["FAKE_PROTOCOL"])
    sys.exit(0)
sys.exit(2)
|}
;;

let kube : D.kube_target =
  { principal = "offline-reader"
  ; cluster = "offline-cluster"
  ; endpoint = "https://offline.invalid"
  }
;;

let binding = String.make 64 'b'
let target = "dev/aws/us-east-1"

let environment =
  [ "FAKE_TARGET"
  ; "FAKE_BINDING"
  ; "FAKE_PRINCIPAL"
  ; "FAKE_CLUSTER"
  ; "FAKE_ENDPOINT"
  ; "FAKE_BLOCKED_MARKER"
  ; "FAKE_ACK_MARKER"
  ; "FAKE_PROTOCOL"
  ; "FAKE_UNAVAILABLE"
  ; "FAKE_NO_EXECUTION"
  ; "FAKE_HANG_AFTER_ACK"
  ; "SOL_MIGRATION_EXECUTION_BINDING"
  ]
;;

let with_install
      ?(producer = true)
      ?(no_execution = false)
      ?(protocol = {|{"channel":"migration-execution","schema":1}|})
      fn
  =
  let root = Filename.temp_dir "sol-migration-execution-" "" in
  let previous = List.map (fun k -> k, Sys.getenv_opt k) environment in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (k, v) ->
           match v with
           | Some v -> Unix.putenv k v
           | None -> Unix.putenv k "")
        previous;
      ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       write (root ^ "/install/bin/sol") fake_sol;
       if producer then write (root ^ "/install/bin/sol-database-contract") fake_producer;
       Sol_cli_fs.mkdir_p (root ^ "/workspace") |> get;
       Unix.putenv "FAKE_TARGET" target;
       Unix.putenv "FAKE_PRINCIPAL" kube.principal;
       Unix.putenv "FAKE_CLUSTER" kube.cluster;
       Unix.putenv "FAKE_ENDPOINT" kube.endpoint;
       Unix.putenv "FAKE_BLOCKED_MARKER" (root ^ "/blocked");
       Unix.putenv "FAKE_ACK_MARKER" (root ^ "/ack");
       Unix.putenv "FAKE_PROTOCOL" protocol;
       Unix.putenv "FAKE_NO_EXECUTION" (if no_execution then "1" else "");
       fn root)
;;

let fresh_context () =
  let now = int_of_float (Unix.gettimeofday ()) in
  { D.target = kube
  ; verified_at = now
  ; started_at = now
  ; finished_at = now
  ; expires_at = Some (now + 300)
  }
;;

let launch_outcome
      ?(requested = target)
      ?(expected = kube)
      ?(launch_binding = binding)
      ?context
      ?(completion_timeout_s = 10.)
      root
      consume
  =
  Q.Fixture.run
    ~program:(root ^ "/install/bin/sol")
    ~workspace:(root ^ "/workspace")
    ~requested_target:requested
    ~expected
    ~binding:launch_binding
    ~timeout_s:10.
    ~completion_timeout_s
    ~establish:(fun () -> Ok (Option.value context ~default:(fresh_context ())))
    ~consume
;;

(* Most tests exercise a submitted execution; unwrap it so a skip is a fixture
   failure rather than a silently accepted value. *)
let launch
      ?requested
      ?expected
      ?launch_binding
      ?context
      ?completion_timeout_s
      root
      consume
  =
  match
    launch_outcome
      ?requested
      ?expected
      ?launch_binding
      ?context
      ?completion_timeout_s
      root
      consume
  with
  | Ok (Q.Executed value) -> Ok value
  | Ok (Q.Skipped reason) -> Error ("unexpected skipped execution: " ^ reason)
  | Error message -> Error message
;;

let wait_for path =
  let rec loop n =
    if Sys.file_exists path
    then ()
    else if n = 0
    then Alcotest.fail ("fixture never wrote " ^ path)
    else (
      Unix.sleepf 0.01;
      loop (n - 1))
  in
  loop 500
;;

let acknowledged root =
  wait_for (root ^ "/ack");
  check
    (In_channel.with_open_text (root ^ "/ack") In_channel.input_all = "capture-finished")
    "the product was not acknowledged"
;;

let launches_and_binds () =
  with_install (fun root ->
    let observed = ref None in
    let outcome =
      launch root (fun locator ->
        (* The product blocks after the locator until the acknowledgment, so the
           observation window is still open here. *)
        wait_for (root ^ "/blocked");
        check
          (not (Sys.file_exists (root ^ "/ack")))
          "cleanup was released before independent observation";
        check (locator.receipt.binding = binding) "launcher binding lost";
        check (locator.identity.uid = "submission-uid-7") "submission UID lost";
        check (locator.identity.name = "sol-migrate-fake") "submission name lost";
        check (locator.context.target = kube) "observation context lost";
        observed := Some locator;
        Ok 42)
    in
    check (outcome = Ok 42) "a valid submission locator was rejected";
    check (Option.is_some !observed) "consume never ran";
    acknowledged root)
;;

let rejects_wrong_target () =
  with_install (fun root ->
    let outcome =
      launch ~requested:"dev/aws/eu-west-1" root (fun _ -> Alcotest.fail "consume ran")
    in
    check (Result.is_error outcome) "another requested target was accepted";
    acknowledged root)
;;

let rejects_wrong_binding () =
  with_install (fun root ->
    Unix.putenv "FAKE_BINDING" (String.make 64 'c');
    let outcome = launch root (fun _ -> Alcotest.fail "consume ran") in
    check (Result.is_error outcome) "another launcher binding was accepted";
    acknowledged root)
;;

let rejects_other_authority () =
  with_install (fun root ->
    Unix.putenv "FAKE_CLUSTER" "another-cluster";
    let outcome = launch root (fun _ -> Alcotest.fail "consume ran") in
    check (Result.is_error outcome) "another Kubernetes authority was accepted";
    acknowledged root)
;;

let rejects_other_context_authority () =
  with_install (fun root ->
    let now = int_of_float (Unix.gettimeofday ()) in
    let context =
      { D.target = { kube with cluster = "another-cluster" }
      ; verified_at = now
      ; started_at = now
      ; finished_at = now
      ; expires_at = Some (now + 300)
      }
    in
    let outcome = launch ~context root (fun _ -> Alcotest.fail "consume ran") in
    check (Result.is_error outcome) "another observation authority was accepted";
    acknowledged root)
;;

let rejects_expired_context () =
  with_install (fun root ->
    let now = int_of_float (Unix.gettimeofday ()) in
    let context =
      { D.target = kube
      ; verified_at = now
      ; started_at = now
      ; finished_at = now
      ; expires_at = Some (now - 1)
      }
    in
    let outcome = launch ~context root (fun _ -> Alcotest.fail "consume ran") in
    check (Result.is_error outcome) "an expired observation context was accepted";
    acknowledged root)
;;

let rejects_stale_context () =
  with_install (fun root ->
    let now = int_of_float (Unix.gettimeofday ()) in
    let context =
      { D.target = kube
      ; verified_at = now - 400
      ; started_at = now - 400
      ; finished_at = now - 400
      ; expires_at = Some (now + 300)
      }
    in
    let outcome = launch ~context root (fun _ -> Alcotest.fail "consume ran") in
    check (Result.is_error outcome) "a stale observation context was accepted";
    acknowledged root)
;;

let unavailable_is_not_a_receipt () =
  with_install (fun root ->
    Unix.putenv "FAKE_UNAVAILABLE" "1";
    let outcome = launch root (fun _ -> Alcotest.fail "consume ran") in
    check (Result.is_error outcome) "unavailable metadata was accepted as a receipt";
    acknowledged root)
;;

let overdue_child_is_unestablished () =
  with_install (fun root ->
    Unix.putenv "FAKE_HANG_AFTER_ACK" "1";
    let outcome = launch ~completion_timeout_s:0.5 root (fun _ -> Ok 7) in
    match outcome with
    | Ok _ -> Alcotest.fail "an overdue child was reported as a completed capture"
    | Error message ->
      check
        (Sol_cli_string.contains ~needle:"unestablished" message)
        "overdue outcome is not explicitly unestablished";
      check
        (Sol_cli_string.contains ~needle:"cleanup" message)
        "overdue outcome does not name the remaining cleanup responsibility")
;;

let no_execution_is_reported_not_inferred () =
  with_install ~no_execution:true (fun root ->
    let outcome =
      launch_outcome root (fun _ -> Alcotest.fail "consume ran for a skipped execution")
    in
    (match outcome with
     | Ok (Q.Skipped reason) -> check (String.trim reason <> "") "skip reason missing"
     | Ok (Q.Executed _) -> Alcotest.fail "a skipped execution became a receipt"
     | Error message -> Alcotest.fail ("a skipped execution became an error: " ^ message));
    acknowledged root)
;;

let probes_the_bundled_protocol () =
  with_install (fun root ->
    check
      (Q.protocol_supported ~install:(root ^ "/install") = Ok true)
      "the advertised protocol was not recognized");
  with_install ~protocol:{|{"channel":"migration-execution","schema":2}|} (fun root ->
    check
      (Q.protocol_supported ~install:(root ^ "/install") = Ok false)
      "another protocol was accepted");
  with_install ~producer:false (fun root ->
    check
      (Result.is_error (Q.protocol_supported ~install:(root ^ "/install")))
      "a missing producer was accepted")
;;

let () =
  Alcotest.run
    "Qualification-owned migration execution launcher"
    [ ( "migration execution"
      , [ Alcotest.test_case "launches and binds the submission" `Quick launches_and_binds
        ; Alcotest.test_case
            "rejects another requested target"
            `Quick
            rejects_wrong_target
        ; Alcotest.test_case
            "rejects another launcher binding"
            `Quick
            rejects_wrong_binding
        ; Alcotest.test_case
            "rejects another Kubernetes authority"
            `Quick
            rejects_other_authority
        ; Alcotest.test_case
            "rejects another observation authority"
            `Quick
            rejects_other_context_authority
        ; Alcotest.test_case
            "rejects an expired observation context"
            `Quick
            rejects_expired_context
        ; Alcotest.test_case
            "rejects a stale observation context"
            `Quick
            rejects_stale_context
        ; Alcotest.test_case
            "unavailable is not a receipt"
            `Quick
            unavailable_is_not_a_receipt
        ; Alcotest.test_case
            "a skipped execution is reported, not inferred"
            `Quick
            no_execution_is_reported_not_inferred
        ; Alcotest.test_case
            "an overdue child leaves the outcome unestablished"
            `Quick
            overdue_child_is_unestablished
        ; Alcotest.test_case
            "probes the bundled protocol"
            `Quick
            probes_the_bundled_protocol
        ] )
    ]
;;
