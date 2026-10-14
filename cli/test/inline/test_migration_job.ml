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
  Windtrap.equal Windtrap.string ~msg:"and the resource" "app_db" (field "resource");
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
