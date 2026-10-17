(* Qualification-owned launcher boundary. A fake installed candidate speaks the
   private receipt protocol so validation, the observation window and the release
   of the product's own cleanup are exercised without a live provider. The real
   product channel is covered by the CLI boundary in test_live_kubernetes.ml. *)
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
import json, os
binding = os.environ["SOL_MIGRATION_EXECUTION_BINDING"]
message = (
    {"schema": 1, "kind": "Unavailable"}
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
  ; "SOL_MIGRATION_EXECUTION_BINDING"
  ]
;;

let with_install
      ?(producer = true)
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
       fn root)
;;

let context : D.read_context =
  { target = kube
  ; verified_at = 1
  ; started_at = 1
  ; finished_at = 1
  ; expires_at = Some 100
  }
;;

let launch
      ?(requested = target)
      ?(expected = kube)
      ?(launch_binding = binding)
      root
      consume
  =
  Q.run
    ~install:(root ^ "/install")
    ~workspace:(root ^ "/workspace")
    ~requested_target:requested
    ~expected
    ~binding:launch_binding
    ~timeout_s:10.
    ~completion_timeout_s:10.
    ~establish:(fun () -> Ok context)
    ~consume
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

let unavailable_is_not_a_receipt () =
  with_install (fun root ->
    Unix.putenv "FAKE_UNAVAILABLE" "1";
    let outcome = launch root (fun _ -> Alcotest.fail "consume ran") in
    check (Result.is_error outcome) "unavailable metadata was accepted as a receipt";
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

let refuses_candidate_without_protocol () =
  with_install ~producer:false (fun root ->
    let outcome = launch root (fun _ -> Alcotest.fail "consume ran") in
    check
      (Result.is_error outcome)
      "launched a candidate without the execution-receipt protocol";
    check
      (not (Sys.file_exists (root ^ "/blocked")))
      "an unsupported candidate was still launched")
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
            "unavailable is not a receipt"
            `Quick
            unavailable_is_not_a_receipt
        ; Alcotest.test_case
            "refuses a candidate without the protocol"
            `Quick
            refuses_candidate_without_protocol
        ; Alcotest.test_case
            "probes the bundled protocol"
            `Quick
            probes_the_bundled_protocol
        ] )
    ]
;;
