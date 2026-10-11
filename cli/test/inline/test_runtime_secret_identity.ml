let assert_contains label haystack needle =
  if not (Sol_cli_string.contains ~needle haystack)
  then Windtrap.failf "%s: expected to find %S in:\n%s" label needle haystack
;;

let assert_absent label haystack needle =
  if Sol_cli_string.contains ~needle haystack
  then Windtrap.failf "%s: did not expect to find %S in:\n%s" label needle haystack
;;

let namespace = "pluto-checkout"

let test_substrate_secret_carries_the_runtime_identity () =
  let substrate =
    Sol_cli_manifest.secret_doc
      ~ns:namespace
      ~name:Sol_cli_manifest.runtime_secret_name
      ()
    |> fun doc -> Sol_cli_yaml.render [ doc ]
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"one runtime identity, defined once"
    "sol-secrets"
    Sol_cli_manifest.runtime_secret_name;
  assert_contains
    "the substrate Secret carries that identity"
    substrate
    "  name: sol-secrets\n";
  assert_contains
    "the substrate Secret lands in the workload's namespace"
    substrate
    ("  namespace: " ^ namespace ^ "\n");
  assert_absent
    "the shared runtime Secret is not suffixed a second time"
    substrate
    "sol-secrets-secrets"
;;

let test_workload_secrets_keep_their_own_convention () =
  Windtrap.equal
    Windtrap.string
    ~msg:"a workload's Secret is its name plus the suffix"
    "charge-svc-secrets"
    (Sol_cli_manifest.workload_secret_name "charge-svc");
  assert_contains
    "and rendering it produces exactly that name"
    (Sol_cli_yaml.render
       [ Sol_cli_manifest.secret_doc
           ~ns:namespace
           ~name:(Sol_cli_manifest.workload_secret_name "charge-svc")
           ()
       ])
    "  name: charge-svc-secrets\n";
  assert_absent
    "a workload Secret is not suffixed twice either"
    (Sol_cli_yaml.render
       [ Sol_cli_manifest.secret_doc
           ~ns:namespace
           ~name:(Sol_cli_manifest.workload_secret_name "charge-svc")
           ()
       ])
    "charge-svc-secrets-secrets"
;;

(* 2b: the migration Job is a DDL consumer, so its credential is the target's DDL class
   Secret, not the workspace runtime Secret. The runtime Secret survives for Kafka. *)
let test_migration_job_reads_the_ddl_class_secret () =
  let ddl_creds = Sol_cli_database_setup_render.ddl_creds_name "pluto" in
  let job =
    Sol_cli_yaml.render
      [ Sol_cli_manifest.migration_job_doc
          ~name:"sol-migrate-x"
          ~namespace
          ~image:"runner:1"
          ~args:[ "migrate"; "up" ]
          ~configmap_name:"sol-migrate-files-x"
          ~ddl_creds_name:ddl_creds
          ()
      ]
  in
  let secret_ref =
    match Yaml.of_string (String.sub job 4 (String.length job - 4)) with
    | Ok (`O fields) ->
      (match List.assoc_opt "spec" fields with
       | Some (`O spec) ->
         (match List.assoc_opt "template" spec with
          | Some (`O template) ->
            (match List.assoc_opt "spec" template with
             | Some (`O pod) ->
               (match List.assoc_opt "containers" pod with
                | Some (`A [ `O container ]) ->
                  (match List.assoc_opt "envFrom" container with
                   | Some (`A [ `O [ ("secretRef", `O [ ("name", `String name) ]) ] ]) ->
                     Some name
                   | _ -> None)
                | _ -> None)
             | _ -> None)
          | _ -> None)
       | _ -> None)
    | _ -> None
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the Job's secretRef is the target's DDL class Secret"
    (Some ddl_creds)
    secret_ref
;;

let%test "infra-040: the substrate Secret carries the runtime identity" =
  test_substrate_secret_carries_the_runtime_identity ()
;;

let%test "infra-040: workload Secrets keep their own convention" =
  test_workload_secrets_keep_their_own_convention ()
;;

let%test "2b: the migration Job reads the target's DDL class Secret" =
  test_migration_job_reads_the_ddl_class_secret ()
;;
