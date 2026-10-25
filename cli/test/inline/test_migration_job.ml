let with_fake_kubectl script f =
  let dir = Filename.temp_dir "sol-fake-kubectl-" "" in
  let bin = Filename.concat dir "kubectl" in
  Out_channel.with_open_text bin (fun oc -> output_string oc script);
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      ignore (Sol_cli_fs.remove_tree dir))
    f
;;

let fake ~succeeded ~waiting =
  Printf.sprintf
    {|#!/bin/sh
case "$*" in
  *"get job"*"status.succeeded"*) printf '%s' ;;
  *"get job"*"status.failed"*) printf '' ;;
  *"get pods"*) printf '%%s' '%s' ;;
  *) exit 1 ;;
esac
|}
    succeeded
    waiting
;;

let job =
  { Sol_cli_migration_job.namespace = "pluto-payments"
  ; job_name = "sol-migrate-1"
  ; configmap_name = Some "sol-migrate-files-1"
  }
;;

let wait () =
  Sol_cli_migration_job.wait
    ~ctx:Sol_cli_kube_destination.local_context
    ~interval_s:0.01
    ~attempts:5
    job
;;

let test_unstartable_fails_fast () =
  with_fake_kubectl
    (fake
       ~succeeded:""
       ~waiting:{|CreateContainerConfigError|secret "sol-secrets" not found|})
    (fun () ->
       match wait () with
       | Unstartable { reason; detail } ->
         Windtrap.equal
           Windtrap.string
           ~msg:"the reason"
           "CreateContainerConfigError"
           reason;
         Windtrap.equal
           (Windtrap.option Windtrap.string)
           ~msg:"the message naming the thing"
           (Some {|secret "sol-secrets" not found|})
           detail
       | _ -> Windtrap.fail "a container that cannot start was waited on")
;;

let test_succeeded () =
  with_fake_kubectl (fake ~succeeded:"1" ~waiting:"") (fun () ->
    match wait () with
    | Succeeded -> ()
    | _ -> Windtrap.fail "a succeeded Job was not read as succeeded")
;;

let test_times_out_on_a_transient_wait () =
  with_fake_kubectl (fake ~succeeded:"" ~waiting:"ContainerCreating|") (fun () ->
    match wait () with
    | Timed_out _ -> ()
    | _ -> Windtrap.fail "a transient waiting reason ended the wait")
;;

let service domain name : Sol_cli_manifest.service =
  { domain; name; primitive = Sol_cli_manifest.Svc; dir = "app/" ^ domain ^ "/" ^ name }
;;

(* **#1424: the database namespace is the target's, not the application inventory's.** The old
   derivation took the namespace of the alphabetically-first *selected* service, and the setup
   step and the migration gate were given different lists — so omitting the alphabetically-first
   domain put the DDL class Secret and the Job that reads it in different namespaces, and moved
   the password authority with them. *)
let test_database_namespace_is_the_targets () =
  let namespace ?(resource = "app_db") ?(target = "qual-2b-a33-aws-us-east-1") () =
    Sol_cli_database_setup_render.database_namespace
      (Sol_cli_database_setup_render.database_identity
         ~workspace:"pluto"
         ~target
         ~resource)
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"which resource is bound does not move the namespace"
    (namespace ())
    (namespace ~resource:"another_db" ());
  Windtrap.equal
    Windtrap.bool
    ~msg:"and the namespace is not any domain's"
    true
    (not
       (List.mem
          (namespace ())
          [ "pluto-checkout"; "pluto-comms"; "pluto-payments"; "pluto-demo-ts" ]));
  Windtrap.equal
    Windtrap.bool
    ~msg:"two targets in one cluster do not share a database namespace"
    true
    (not (String.equal (namespace ()) (namespace ~target:"another-aws-us-east-1" ())))
;;

(* The deploy declares the identity it resolved, so a verifier reads the declaration rather than
   reproducing the naming rule. **The sentinel and the whole field set are the contract**, both
   in `runtime.md` and in the doc comment -- a row parsing this line breaks on a sentinel change
   exactly as hard as on a field-name change, so the test covers all of it. If a field is added
   to the report and not here, this test stops being the thing that makes drift fail. *)
let test_database_identity_report_is_the_interface () =
  let identity =
    Sol_cli_database_setup_render.database_identity
      ~workspace:"pluto"
      ~target:"qual-2b-a33-aws-us-east-1"
      ~resource:"app_db"
  in
  let report = Sol_cli_database_setup_render.database_identity_report identity in
  let field key =
    let prefix = key ^ "=" in
    report
    |> String.split_on_char ' '
    |> List.find_opt (fun f ->
      String.length f > String.length prefix
      && String.sub f 0 (String.length prefix) = prefix)
    |> Option.map (fun f ->
      String.sub f (String.length prefix) (String.length f - String.length prefix))
    |> Option.value ~default:"<absent>"
  in
  Windtrap.equal
    Windtrap.bool
    ~msg:"the sentinel is the contract's first token"
    true
    (String.length report
     >= String.length Sol_cli_database_setup_render.database_identity_sentinel
     && String.sub
          report
          0
          (String.length Sol_cli_database_setup_render.database_identity_sentinel)
        = Sol_cli_database_setup_render.database_identity_sentinel);
  Windtrap.equal
    Windtrap.string
    ~msg:"the report names the target"
    "qual-2b-a33-aws-us-east-1"
    (field "target");
  (* The identity's fields name things, so the report carries the **name-safe** form of the
     resource (`_` becomes `-`), not the config's spelling. That is what makes the line
     whitespace-parseable for any resource the config admits. *)
  Windtrap.equal
    Windtrap.string
    ~msg:"and the resource, name-safe"
    "app-db"
    (field "resource");
  Windtrap.equal
    Windtrap.string
    ~msg:"and the namespace it wrote into"
    (Sol_cli_database_setup_render.database_namespace identity)
    (field "namespace");
  Windtrap.equal
    Windtrap.string
    ~msg:"and the DDL class Secret name"
    (Sol_cli_database_setup_render.ddl_creds_name "qual-2b-a33-aws-us-east-1")
    (field "ddl-creds");
  Windtrap.equal
    Windtrap.string
    ~msg:"and the authority Secret name"
    (Sol_cli_database_setup_render.authority_name "qual-2b-a33-aws-us-east-1")
    (field "authority");
  Windtrap.equal
    Windtrap.string
    ~msg:"and the CA ConfigMap name"
    (Sol_cli_database_setup_render.ca_configmap_name "qual-2b-a33-aws-us-east-1")
    (field "ca-configmap");
  Windtrap.equal
    Windtrap.string
    ~msg:"and no declared field is absent from what the report prints"
    ""
    (String.concat
       ", "
       (List.filter
          (fun key -> String.equal (field key) "<absent>")
          [ "target"; "resource"; "namespace"; "ddl-creds"; "authority"; "ca-configmap" ]))
;;

(* **A local rollback reads where its credential is.** Local has no target, and `sol-secrets` is
   written per workload namespace, so this path stays inventory-derived on purpose: a
   target-derived `sol-db-<workspace>-local` would be a namespace the local deploy never
   populates and the read would fail on a missing credential (#1424).

   A workspace with no service has **no** namespace holding the credential, so this keeps the
   original, explicit failure rather than naming a namespace that would report a missing Secret
   instead -- and it propagates the namespace-name error rather than swallowing it. *)
let test_local_namespace_is_a_workload_namespace () =
  let services =
    [ service "payments" "orders_svc"
    ; service "comms" "fulfilment_worker"
    ; service "checkout" "checkout_svc"
    ]
  in
  Windtrap.equal
    (Windtrap.result Windtrap.string Windtrap.string)
    ~msg:"the first service by domain, then name"
    (Ok "pluto-checkout")
    (Sol_cli_migration_job.local_namespace ~workspace:"pluto" ~services);
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "and it is one of the workspace's workload namespaces, never a target-derived one"
    true
    (match Sol_cli_migration_job.local_namespace ~workspace:"pluto" ~services with
     | Ok ns -> List.mem ns [ "pluto-payments"; "pluto-comms"; "pluto-checkout" ]
     | Error _ -> false);
  Windtrap.equal
    Windtrap.bool
    ~msg:
      "a workspace with no service fails, naming why, rather than pointing at a namespace"
    true
    (match Sol_cli_migration_job.local_namespace ~workspace:"pluto" ~services:[] with
     | Ok _ -> false
     | Error message ->
       Sol_cli_string.contains ~needle:"no deployed service found" message)
;;

(* **A reader splits the report on whitespace**, so no value may contain a space or an `=`. A
   resource name is not covered by the config's identifier check (unlike a store, a domain or a
   unit), so this proves the identity is name-safe by construction rather than by trusting the
   config. *)
let test_the_report_is_parseable_for_a_hostile_resource () =
  let identity =
    Sol_cli_database_setup_render.database_identity
      ~workspace:"pluto"
      ~target:"qual-2b-a33-aws-us-east-1"
      ~resource:"app db=evil"
  in
  let report = Sol_cli_database_setup_render.database_identity_report identity in
  let tokens = String.split_on_char ' ' report in
  Windtrap.equal
    Windtrap.int
    ~msg:"sentinel plus six fields, whatever the resource name was"
    7
    (List.length tokens);
  Windtrap.equal
    Windtrap.bool
    ~msg:"and each field token has one =, not at its start"
    true
    (List.for_all
       (fun token ->
          token = Sol_cli_database_setup_render.database_identity_sentinel
          ||
          match String.index_opt token '=', String.rindex_opt token '=' with
          | Some i, Some j -> i = j && i > 0
          | _ -> false)
       tokens)
;;

let%test "release: the identity is name-safe, so the report is parseable" =
  test_the_report_is_parseable_for_a_hostile_resource ()
;;

let%test "release: a local migration read uses a workload namespace" =
  test_local_namespace_is_a_workload_namespace ()
;;

let%test "release: the database namespace is the target's, not the inventory's" =
  test_database_namespace_is_the_targets ()
;;

let%test "release: the deploy's database identity report is the interface the rows read" =
  test_database_identity_report_is_the_interface ()
;;

let%test "REFAC-139 part A: unstartable fails fast" = test_unstartable_fails_fast ()
let%test "REFAC-139 part A: succeeded" = test_succeeded ()

let%test "REFAC-139 part A: a transient wait runs to its bound" =
  test_times_out_on_a_transient_wait ()
;;

(* #1379: success includes releasing the Job's authority; an API refusal is not
   cleanup. Contract failures, in contrast, intentionally retain their evidence. *)
let%test "contract cleanup: a successful Job with denied deletion fails the phase" =
  with_fake_kubectl
    {|#!/bin/sh
case "$*" in
  *apply*) exit 0 ;;
  *get*job*status.succeeded*) printf 1 ;;
  *delete*) printf 'Error from server (Forbidden): cleanup denied' >&2; exit 1 ;;
  *) exit 1 ;;
esac
|}
    (fun () ->
       match
         Sol_cli_contract.reconcile_in_destination
           ~ctx:Sol_cli_kube_destination.local_context
           ~kafka:(Sol_cli_resource_binding.Local_kafka "events")
           ~secret_name:None
           ~consumer:false
           ~namespace:"pluto-payments"
           ~image:"candidate@sha256:abc"
       with
       | Ok () -> Windtrap.fail "contract success hid a surviving Job"
       | Error message ->
         List.iter
           (fun required ->
              Windtrap.equal
                Windtrap.bool
                ~msg:required
                true
                (Sol_cli_string.contains ~needle:required message))
           [ "pluto-payments/sol-contract-"; "Forbidden" ])
;;

let%test "submission cleanup: a failed first ConfigMap write still releases owned objects"
  =
  let log = Filename.temp_file "sol-submit-cleanup-" ".log" in
  Fun.protect
    ~finally:(fun () -> Sys.remove log)
    (fun () ->
       with_fake_kubectl
         (Printf.sprintf
            {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$*" in
  *apply*) printf 'connection lost after request' >&2; exit 1 ;;
  *delete*) exit 0 ;;
  *) exit 1 ;;
esac
|}
            (Filename.quote log))
         (fun () ->
            let result =
              Sol_cli_migration_job.submit
                ~ctx:Sol_cli_kube_destination.local_context
                ~namespace:"pluto-payments"
                ~name_prefix:"sol-migrate"
                ~label:"migration "
                ~image:"candidate@sha256:abc"
                ~args:[]
                ~files:[ "001.sql", "SELECT 1" ]
                ~ddl_creds_name:"target-ddl-creds"
                ()
            in
            Windtrap.equal
              Windtrap.bool
              ~msg:"submission failed"
              true
              (Result.is_error result);
            let calls = In_channel.with_open_text log In_channel.input_all in
            List.iter
              (fun required ->
                 Windtrap.equal
                   Windtrap.bool
                   ~msg:required
                   true
                   (Sol_cli_string.contains ~needle:required calls))
              [ "delete job sol-migrate-"; "delete configmap sol-migrate-files-" ];
            Windtrap.equal
              Windtrap.bool
              ~msg:"durable credentials survive"
              false
              (Sol_cli_string.contains ~needle:"delete secret" calls)))
;;

let with_cleanup_calls ?(refuse = false) f =
  let log = Filename.temp_file "sol-job-cleanup-" ".log" in
  Fun.protect
    ~finally:(fun () -> Sys.remove log)
    (fun () ->
       with_fake_kubectl
         (Printf.sprintf
            {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$*" in
  *delete*) %s ;;
  *apply*) exit 0 ;;
  *status.succeeded*) printf '' ;;
  *status.failed*) printf 1 ;;
  *logs*) printf 'registry unavailable' ;;
  *) exit 0 ;;
esac
|}
            (Filename.quote log)
            (if refuse
             then "printf 'Forbidden: deletion denied' >&2; exit 1"
             else "exit 0"))
         (fun () -> f (fun () -> In_channel.with_open_text log In_channel.input_all)))
;;

let assert_transients_only calls =
  List.iter
    (fun name ->
       Windtrap.equal
         Windtrap.bool
         ~msg:name
         true
         (Sol_cli_string.contains ~needle:name calls))
    [ "delete job sol-migrate-1"; "delete configmap sol-migrate-files-1" ];
  Windtrap.equal
    Windtrap.bool
    ~msg:"durable credentials are never cleanup targets"
    false
    (Sol_cli_string.contains ~needle:"delete secret" calls)
;;

let%test "Job cleanup: success and returned failure release only transient objects" =
  List.iter
    (fun original ->
       with_cleanup_calls (fun calls ->
         let result =
           Sol_cli_migration_job.with_cleanup
             ~ctx:Sol_cli_kube_destination.local_context
             job
             (fun () -> original)
         in
         Windtrap.equal
           (Windtrap.result Windtrap.unit Windtrap.string)
           ~msg:"primary result survives cleanup"
           original
           result;
         assert_transients_only (calls ())))
    [ Ok (); Error "primary failure" ]
;;

let%test "Job cleanup: exception releases transients without masking the primary failure" =
  with_cleanup_calls ~refuse:true (fun calls ->
    let caught =
      try
        ignore
          (Sol_cli_migration_job.with_cleanup
             ~ctx:Sol_cli_kube_destination.local_context
             job
             (fun () -> failwith "primary exception"));
        false
      with
      | Failure message -> message = "primary exception"
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"the primary exception survives cleanup failure"
      true
      caught;
    assert_transients_only (calls ()))
;;

let%test "Job cleanup: errors include the surviving authority and provider diagnostic" =
  with_cleanup_calls ~refuse:true (fun calls ->
    match
      Sol_cli_migration_job.with_cleanup
        ~ctx:Sol_cli_kube_destination.local_context
        job
        (fun () -> Error "primary failure")
    with
    | Ok _ -> Windtrap.fail "cleanup failure became success"
    | Error message ->
      List.iter
        (fun required ->
           Windtrap.equal
             Windtrap.bool
             ~msg:required
             true
             (Sol_cli_string.contains ~needle:required message))
        [ "primary failure"
        ; "pluto-payments/sol-migrate-1"
        ; "credential references"
        ; "pluto-payments/sol-migrate-files-1"
        ; "Forbidden"
        ];
      assert_transients_only (calls ()))
;;

let%test "contract cleanup: a failed Job remains available for inspection" =
  with_cleanup_calls (fun calls ->
    let result =
      Sol_cli_contract.reconcile_in_destination
        ~ctx:Sol_cli_kube_destination.local_context
        ~kafka:(Sol_cli_resource_binding.Local_kafka "events")
        ~secret_name:None
        ~consumer:false
        ~namespace:"pluto-payments"
        ~image:"candidate@sha256:abc"
    in
    Windtrap.equal
      Windtrap.bool
      ~msg:"reconciliation failed"
      true
      (Result.is_error result);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the diagnostic Job survives"
      false
      (Sol_cli_string.contains ~needle:"delete" (calls ())))
;;
