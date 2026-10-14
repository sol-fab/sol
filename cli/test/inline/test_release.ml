let facts () =
  match Sol_cli_workspace_model.load ~root:(Sys.getcwd ()) with
  | Ok facts -> facts
  | Error e -> Windtrap.fail ("workspace model failed to load: " ^ e)
;;

let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

module R = Sol_cli_release

let test_sanitize_label () =
  check_string "target path" "dev-aws-us-east-1" (R.sanitize_label "dev/aws/us-east-1");
  check_string "unit scope" "payments-charge_svc" (R.sanitize_label "payments/charge_svc");
  check_string "uppercase lowers" "prod" (R.sanitize_label "PROD");
  check_string "all separators collapses to none" "none" (R.sanitize_label "///")
;;

let sample_workload : R.workload =
  { domain = "payments"
  ; name = "charge_svc"
  ; primitive = "svc"
  ; image = "reg/myworkspace/charge-svc:abc1234"
  ; config = [ "LOG_LEVEL", "info" ]
  ; secrets = [ "DATABASE_URL", "db-secret" ]
  ; uses = []
  ; external_secret_refs =
      [ "PAYMENT_API_KEY", "payments-vault", "production/payment-api" ]
  ; schedule = None
  ; scheduled_concurrency = "forbid"
  ; backoff_limit = 0
  ; replicas = 2
  ; availability = "single"
  ; consumes_kafka = false
  ; cpu = "100m"
  ; memory = "128Mi"
  ; extra_labels = [ "team", "payments" ]
  ; volumes = [ "pgdata", "/var/lib/postgresql/data", "1Gi", "read_write_once" ]
  ; rollout = "canary:w10,p30,w100"
  ; ingress_host = Some "charge.example.com"
  ; ingress_path = Some "/"
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = [ "CHECKOUT_SVC_URL", "checkout", "checkout-svc", "myworkspace-checkout" ]
  }
;;

let sample_record : R.t =
  let placeholder =
    { R.release_id = ""
    ; workspace = "myworkspace"
    ; environment = Some "dev"
    ; workloads = [ R.applied_by "" sample_workload ]
    ; migrations = [ "0001_notifications.sql" ]
    ; contract = []
    ; apply_mode = R.Direct
    ; encoding_version = Some Sol_cli_release_id.encoding_version
    }
  in
  let release_id =
    Sol_cli_release_id.to_string
      (Sol_cli_release_id.of_content
         { workspace = placeholder.workspace
         ; environment = placeholder.environment
         ; workloads = [ sample_workload ]
         ; contract = []
         })
  in
  { placeholder with release_id; workloads = [ R.applied_by release_id sample_workload ] }
;;

let test_json_round_trip () =
  match R.of_json (R.to_json sample_record) with
  | Error msg -> Windtrap.fail msg
  | Ok r ->
    check_string "workspace preserved" "myworkspace" r.workspace;
    check_string "environment preserved" "dev" (Option.value r.environment ~default:"");
    check_int "one workload" 1 (List.length r.workloads);
    let recorded = List.hd r.workloads in
    let w = Sol_cli_release.workload_identity recorded in
    check_string
      "provenance preserved"
      sample_record.release_id
      recorded.Sol_cli_release_id.applied_by;
    check_string "image preserved" "reg/myworkspace/charge-svc:abc1234" w.image;
    check_string "config value preserved" "info" (List.assoc "LOG_LEVEL" w.config);
    check_string
      "secret reference preserved"
      "db-secret"
      (List.assoc "DATABASE_URL" w.secrets);
    check_bool
      "external secret reference preserved"
      true
      (List.mem
         ("PAYMENT_API_KEY", "payments-vault", "production/payment-api")
         w.external_secret_refs);
    check_int "replicas preserved" 2 w.replicas;
    check_string "scheduled concurrency preserved" "forbid" w.scheduled_concurrency;
    check_int "backoff limit preserved" 0 w.backoff_limit;
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"migrations preserved"
      [ "0001_notifications.sql" ]
      r.migrations;
    check_string
      "encoding version preserved"
      Sol_cli_release_id.encoding_version
      (Option.value r.encoding_version ~default:"")
;;

let test_configmap_object () =
  let json = Yojson.Safe.from_string (R.to_configmap_json sample_record) in
  let open Yojson.Safe.Util in
  check_string "kind" "ConfigMap" (member "kind" json |> to_string);
  check_bool "immutable" true (member "immutable" json |> to_bool);
  check_string
    "name is the release id"
    (R.configmap_name sample_record)
    (member "metadata" json |> member "name" |> to_string);
  check_string
    "type label"
    "release"
    (member "metadata" json |> member "labels" |> member "sol.dev/type" |> to_string);
  let data = member "data" json in
  check_string
    "release_id in data"
    sample_record.release_id
    (member "release_id" data |> to_string);
  let record = member "record" data |> to_string in
  check_string
    "digest is the record's own digest"
    (R.record_digest sample_record)
    (member "record_digest" data |> to_string);
  check_bool
    "workspace in body"
    true
    (Sol_cli_string.contains ~needle:"myworkspace" record);
  check_bool "workload in body" true (Sol_cli_string.contains ~needle:"charge_svc" record);
  check_bool
    "secret reference in body"
    true
    (Sol_cli_string.contains ~needle:"db-secret" record);
  check_bool
    "no unrelated secret value"
    false
    (Sol_cli_string.contains ~needle:"hunter2" record)
;;

let test_current_pointer_is_minimal () =
  let json = Yojson.Safe.from_string (R.to_current_configmap_json sample_record) in
  let open Yojson.Safe.Util in
  check_string
    "name"
    "sol-release-current-myworkspace"
    (member "metadata" json |> member "name" |> to_string);
  check_string
    "underscore workspace yields a valid name"
    "sol-release-current-ci-smoke"
    (R.current_configmap_name ~workspace:"ci_smoke");
  let data = member "data" json |> to_assoc in
  check_int "payload is release_id only" 1 (List.length data);
  check_string
    "points at the release"
    sample_record.release_id
    (List.assoc "release_id" data |> to_string)
;;

let test_validate_accepts_canonical_record () =
  R.validate ~name:(R.configmap_name sample_record) sample_record
  |> Result.iter_error (fun msg -> Windtrap.fail ("canonical record rejected: " ^ msg))
;;

let test_validate_rejects_wrong_name () =
  match R.validate ~name:"sol-release-r-deadbeefdeadbeef" sample_record with
  | Ok () -> Windtrap.fail "expected a name-direction failure"
  | Error msg ->
    check_bool
      "names the record"
      true
      (Sol_cli_string.contains ~needle:sample_record.release_id msg)
;;

let test_validate_rejects_corrupt_content () =
  let corrupt = { sample_record with workloads = [] } in
  match R.validate ~name:(R.configmap_name corrupt) corrupt with
  | Ok () -> Windtrap.fail "expected a content-direction failure"
  | Error msg ->
    check_bool "reports corruption" true (Sol_cli_string.contains ~needle:"corrupt" msg)
;;

let stale_record : R.t = { sample_record with encoding_version = Some "sol-release-v1" }

(* **#1422's old-record boundary.** A record written before workloads carried their declared
   requirements cannot answer "what did this version require?", so the version gate refuses it
   **by name** rather than letting a rollback reconstruct with an empty requirement set --
   which would be the fail-open defect wearing a different hat. v6 is the version that
   immediately precedes requirement recording, so it is what a real pre-change release carries;
   the boundary is asserted against v7, not against the older v1 the staleness test uses. *)
(* **#1422 Finding 3's soft spot, asserted rather than described.** `workload_of_json` defaults a
   missing `uses` to `[]`, which is the fail-open shape. In practice it is unreachable: the
   version gate refuses a pre-v7 record, and a v7 record whose field was stripped rederives a
   different content id. This exercises the second defence -- the record below is *valid* with a
   requirement, and removing one field from its JSON leaves a record claiming an identity its
   content no longer has. *)
let test_a_stripped_requirement_field_is_refused () =
  let placeholder =
    { sample_record with
      release_id = ""
    ; workloads =
        List.map
          (fun (w : Sol_cli_release_id.recorded_workload) ->
             { w with spec = { w.spec with Sol_cli_release_id.uses = [ "app_db" ] } })
          sample_record.workloads
    }
  in
  let record =
    { placeholder with
      release_id = Sol_cli_release_id.to_string (R.derived_release_id placeholder)
    }
  in
  (match R.validate ~name:(R.configmap_name record) record with
   | Ok () -> ()
   | Error message -> Windtrap.fail ("the control record must be valid: " ^ message));
  let strip = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "workloads", `List workloads ->
               ( "workloads"
               , `List
                   (List.map
                      (function
                        | `Assoc w ->
                          `Assoc
                            (List.filter (fun (k, _) -> not (String.equal k "uses")) w)
                        | other -> other)
                      workloads) )
             | other -> other)
           fields)
    | other -> other
  in
  match R.of_json (strip (R.to_json record)) with
  | Error message -> Windtrap.fail ("the stripped record should still decode: " ^ message)
  | Ok stripped ->
    (match R.validate ~name:(R.configmap_name stripped) stripped with
     | Ok () ->
       Windtrap.fail "a record whose requirement field was stripped must be refused"
     | Error message ->
       check_bool
         "refused as a record whose content does not rederive its identity, not as an \
          empty one"
         true
         (Sol_cli_string.contains ~needle:"corrupt" message))
;;

let test_a_pre_requirements_record_is_refused_by_name () =
  let record = { sample_record with encoding_version = Some "sol-release-v6" } in
  match R.validate ~name:(R.configmap_name record) record with
  | Ok () -> Windtrap.fail "a pre-requirements record must be refused, not reconstructed"
  | Error msg ->
    check_bool
      "names the version the record was written with"
      true
      (Sol_cli_string.contains ~needle:"sol-release-v6" msg);
    check_bool
      "and the version this CLI writes"
      true
      (Sol_cli_string.contains ~needle:"sol-release-v7" msg);
    check_bool
      "and says it is a format change, not damage"
      true
      (Sol_cli_string.contains ~needle:"format change" msg)
;;

let test_validate_reports_stale_encoding_version () =
  match R.validate ~name:(R.configmap_name stale_record) stale_record with
  | Ok () -> Windtrap.fail "expected a stale-encoding record to be refused"
  | Error msg ->
    check_bool
      "names the version the record was written with"
      true
      (Sol_cli_string.contains ~needle:"sol-release-v1" msg);
    check_bool
      "names the version this CLI writes"
      true
      (Sol_cli_string.contains ~needle:Sol_cli_release_id.encoding_version msg);
    check_bool
      "does not report corruption"
      false
      (Sol_cli_string.contains ~needle:"corrupt" msg)
;;

let test_validate_reports_undeclared_encoding_version () =
  let legacy = { sample_record with encoding_version = None; workloads = [] } in
  match R.validate ~name:(R.configmap_name legacy) legacy with
  | Ok () -> Windtrap.fail "expected an unmarked non-rederiving record to be refused"
  | Error msg ->
    check_bool
      "names the missing marker"
      true
      (Sol_cli_string.contains ~needle:"encoding_version" msg);
    check_bool
      "does not report corruption"
      false
      (Sol_cli_string.contains ~needle:"corrupt" msg)
;;

let test_of_json_without_encoding_version_is_unmarked () =
  let without =
    match R.to_json sample_record with
    | `Assoc fields ->
      `Assoc
        (List.filter (fun (key, _) -> not (String.equal key "encoding_version")) fields)
    | other -> other
  in
  match R.of_json without with
  | Error msg -> Windtrap.fail msg
  | Ok r ->
    check_bool "an absent marker stays absent" true (Option.is_none r.encoding_version)
;;

let item ?(name = R.configmap_name sample_record) ?digest json =
  let digest =
    match digest with
    | Some d -> d
    | None -> Digest.to_hex (Digest.string json)
  in
  `Assoc
    [ "metadata", `Assoc [ "name", `String name ]
    ; "data", `Assoc [ "record", `String json; "record_digest", `String digest ]
    ]
;;

let test_parse_kubectl_list_reads_valid_items () =
  let json =
    `Assoc [ "items", `List [ item (Yojson.Safe.to_string (R.to_json sample_record)) ] ]
  in
  match R.parse_kubectl_list json with
  | Error msg -> Windtrap.fail msg
  | Ok records -> check_int "one record" 1 (List.length records)
;;

let test_parse_kubectl_list_with_creation () =
  let record_body = Yojson.Safe.to_string (R.to_json sample_record) in
  let json =
    `Assoc
      [ ( "items"
        , `List
            [ `Assoc
                [ ( "metadata"
                  , `Assoc
                      [ "name", `String (R.configmap_name sample_record)
                      ; "creationTimestamp", `String "2026-01-01T00:00:00Z"
                      ] )
                ; ( "data"
                  , `Assoc
                      [ "record", `String record_body
                      ; ( "record_digest"
                        , `String (Digest.to_hex (Digest.string record_body)) )
                      ] )
                ]
            ] )
      ]
  in
  match R.parse_kubectl_list_with_creation json with
  | Error msg -> Windtrap.fail msg
  | Ok [ (record, created_at) ] ->
    check_string "record id" sample_record.release_id record.release_id;
    check_string "creation timestamp" "2026-01-01T00:00:00Z" created_at
  | Ok _ -> Windtrap.fail "expected exactly one record"
;;

let test_parse_kubectl_list_fails_closed_on_corrupt () =
  let json =
    `Assoc
      [ ( "items"
        , `List
            [ item (Yojson.Safe.to_string (R.to_json sample_record))
            ; item
                ~name:"sol-release-r-deadbeefdeadbeef"
                (Yojson.Safe.to_string (R.to_json sample_record))
            ; item "not json"
            ; `Assoc []
            ] )
      ]
  in
  match R.parse_kubectl_list json with
  | Ok records ->
    Windtrap.fail
      (Printf.sprintf "expected an error, got %d records" (List.length records))
  | Error msg ->
    check_bool
      "names corruption"
      true
      (Sol_cli_string.contains ~needle:"invalid record" msg);
    check_bool "names the record" true (Sol_cli_string.contains ~needle:"sol-release" msg)
;;

let test_of_kubectl_item_accepts_canonical_record () =
  match R.of_kubectl_item (item (R.record_json_string sample_record)) with
  | Error msg -> Windtrap.fail msg
  | Ok r -> check_string "round-trips the id" sample_record.release_id r.release_id
;;

let test_of_kubectl_item_reports_stale_encoding_version () =
  match R.of_kubectl_item (item (R.record_json_string stale_record)) with
  | Ok _ -> Windtrap.fail "expected a stale record read from a ConfigMap to be refused"
  | Error msg ->
    check_bool
      "names the version the record was written with"
      true
      (Sol_cli_string.contains ~needle:"sol-release-v1" msg);
    check_bool
      "does not report corruption"
      false
      (Sol_cli_string.contains ~needle:"corrupt" msg)
;;

let test_of_kubectl_item_rejects_missing_digest () =
  let no_digest =
    `Assoc
      [ "metadata", `Assoc [ "name", `String (R.configmap_name sample_record) ]
      ; "data", `Assoc [ "record", `String (R.record_json_string sample_record) ]
      ]
  in
  match R.of_kubectl_item no_digest with
  | Ok _ -> Windtrap.fail "expected a missing digest to fail closed"
  | Error msg ->
    check_bool
      "names the format problem"
      true
      (Sol_cli_string.contains ~needle:"missing integrity digest" msg)
;;

let test_of_kubectl_item_rejects_tampered_body () =
  let tampered = { sample_record with migrations = [ "9999_evil.sql" ] } in
  let record_string = R.record_json_string tampered in
  match
    R.of_kubectl_item (item ~digest:(R.record_digest sample_record) record_string)
  with
  | Ok _ -> Windtrap.fail "expected a tampered body to fail closed"
  | Error msg ->
    check_bool
      "reports integrity failure"
      true
      (Sol_cli_string.contains ~needle:"integrity validation" msg)
;;

let test_migrations_tampering_is_caught_by_digest_not_validate () =
  let tampered = { sample_record with migrations = [ "9999_evil.sql" ] } in
  R.validate ~name:(R.configmap_name tampered) tampered
  |> Result.iter_error (fun msg ->
    Windtrap.fail ("a migrations-only change should still rederive the id: " ^ msg));
  match
    R.of_kubectl_item
      (item ~digest:(R.record_digest sample_record) (R.record_json_string tampered))
  with
  | Ok _ -> Windtrap.fail "expected the digest to catch a migrations-only change"
  | Error msg ->
    check_bool
      "reports integrity failure"
      true
      (Sol_cli_string.contains ~needle:"integrity validation" msg)
;;

let shuffled_workload : R.workload =
  { sample_workload with
    config = [ "B", "2"; "A", "1" ]
  ; secrets = [ "Y", "y"; "X", "x" ]
  ; extra_labels = [ "z", "26"; "a", "1" ]
  ; volumes = [ "v2", "/2", "2Gi", "ReadWriteMany"; "v1", "/1", "1Gi", "ReadWriteOnce" ]
  ; calls = [ "Z_URL", "z", "z-svc", "ns-z"; "A_URL", "a", "a-svc", "ns-a" ]
  }
;;

let ordered_workload : R.workload =
  { shuffled_workload with
    config = [ "A", "1"; "B", "2" ]
  ; secrets = [ "X", "x"; "Y", "y" ]
  ; extra_labels = [ "a", "1"; "z", "26" ]
  ; volumes = [ "v1", "/1", "1Gi", "ReadWriteOnce"; "v2", "/2", "2Gi", "ReadWriteMany" ]
  ; calls = [ "A_URL", "a", "a-svc", "ns-a"; "Z_URL", "z", "z-svc", "ns-z" ]
  }
;;

let earlier_workload : R.workload =
  { sample_workload with name = "aaa_svc"; image = "reg/myworkspace/aaa-svc:abc1234" }
;;

let test_record_digest_is_order_independent () =
  let forward =
    { sample_record with
      workloads =
        [ R.applied_by sample_record.release_id shuffled_workload
        ; R.applied_by sample_record.release_id earlier_workload
        ]
    ; migrations = [ "0002_b.sql"; "0001_a.sql" ]
    }
  in
  let reversed =
    { sample_record with
      workloads =
        [ R.applied_by sample_record.release_id earlier_workload
        ; R.applied_by sample_record.release_id ordered_workload
        ]
    ; migrations = [ "0001_a.sql"; "0002_b.sql" ]
    }
  in
  check_string
    "canonical body is order-independent"
    (R.record_json_string forward)
    (R.record_json_string reversed);
  check_string
    "canonical digest is order-independent"
    (R.record_digest forward)
    (R.record_digest reversed)
;;

let test_record_digest_is_total_for_duplicate_keys () =
  let with_config config =
    { sample_record with
      workloads =
        [ R.applied_by sample_record.release_id { sample_workload with config } ]
    }
  in
  check_string
    "duplicate-key order is total"
    (R.record_digest (with_config [ "K", "a"; "K", "b" ]))
    (R.record_digest (with_config [ "K", "b"; "K", "a" ]))
;;

(* The vector moved with `sol-release-v6 -> v7` (#1422): every workload now folds its declared
   requirements into the record content, so both the canonical form and the id derived from it
   change. A pinned vector that moves silently would be the thing this test exists to catch. *)
let test_record_digest_known_vector () =
  check_string
    "known canonical digest"
    "324a5c2836da571b448002ddaf915401"
    (R.record_digest sample_record)
;;

let test_contract_round_trips () =
  let fact : R.contract_fact =
    { subject = "payments.Charged"
    ; topic = "acme-charges"
    ; partitions = 3
    ; key = Some "id"
    ; schema_digest = "abc123"
    }
  in
  let record = { sample_record with contract = [ fact ] } in
  match R.of_json (R.to_json record) with
  | Error msg -> Windtrap.fail msg
  | Ok parsed -> check_bool "contract round trips" true (parsed.contract = [ fact ])
;;

let test_apply_mode_round_trips () =
  match R.of_json (R.to_json { sample_record with apply_mode = R.Gitops }) with
  | Error msg -> Windtrap.fail msg
  | Ok r -> check_bool "gitops preserved" true (r.apply_mode = R.Gitops)
;;

let without_field key json =
  match json with
  | `Assoc kvs -> `Assoc (List.filter (fun (k, _) -> k <> key) kvs)
  | other -> other
;;

let test_apply_mode_missing_fails_closed () =
  match R.of_json (without_field "apply_mode" (R.to_json sample_record)) with
  | Ok _ -> Windtrap.fail "expected a missing apply_mode to fail closed"
  | Error msg ->
    check_bool "names the field" true (Sol_cli_string.contains ~needle:"apply_mode" msg)
;;

let test_apply_mode_unknown_fails_closed () =
  let json =
    match R.to_json sample_record with
    | `Assoc kvs ->
      `Assoc
        (kvs
         |> List.map (fun (k, v) ->
           if k = "apply_mode" then k, `String "sideways" else k, v))
    | other -> other
  in
  match R.of_json json with
  | Ok _ -> Windtrap.fail "expected an unknown apply_mode to fail closed"
  | Error msg ->
    check_bool "names the field" true (Sol_cli_string.contains ~needle:"apply_mode" msg)
;;

let test_format_table_lists_the_id () =
  let table = R.format_table [ sample_record ] in
  check_bool
    "id column present"
    true
    (Sol_cli_string.contains ~needle:sample_record.release_id table);
  check_bool "header present" true (Sol_cli_string.contains ~needle:"ID" table)
;;

let mkdirs path =
  let rec go p =
    if p = "." || p = "/" || p = ""
    then ()
    else (
      go (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  go path
;;

let write_file path content =
  mkdirs (Filename.dirname path);
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let with_cwd dir f =
  let old = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir old) f
;;

let test_env : Sol_cli_deployment_plan.env_config =
  { name = "local"
  ; mode = Sol_cli_deployment_plan.Local
  ; registry = "sol-registry:5000"
  ; image_tag = "dev"
  ; env = None
  ; region = None
  ; base_domain = None
  ; cluster_issuer = "letsencrypt-prod"
  }
;;

let test_service : Sol_cli_manifest.service =
  { domain = "payments"
  ; name = "charge_svc"
  ; primitive = Sol_cli_manifest.Svc
  ; dir = "app/payments/charge_svc"
  }
;;

let with_plan ~requested_scope f =
  let tmp = Filename.temp_dir "sol_test_release_plan" "" in
  with_cwd tmp (fun () ->
    mkdirs "app/payments/charge_svc";
    write_file "app/payments/charge_svc/sol.toml" "";
    match
      Sol_cli_deployment_plan.of_services_result
        ~facts:(facts ())
        ~workspace:"myworkspace"
        ~env:test_env
        ~requested_scope
        [ test_service ]
    with
    | Error e -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string e)
    | Ok plan -> f plan)
;;

let second_service (spec : Sol_cli_deployment_plan.service_spec) =
  { spec with
    source_name = "ledger_svc"
  ; k8s_name =
      (match Sol_cli_deployment_plan.k8s_name_result "ledger-svc" with
       | Ok name -> name
       | Error e -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string e))
  ; image = "reg/myworkspace/ledger-svc:abc1234"
  }
;;

let recorded_of (r : R.t) name =
  List.find
    (fun (w : R.recorded_workload) -> String.equal w.Sol_cli_release_id.spec.name name)
    r.workloads
;;

let reconstruct release =
  match Sol_cli_rollback.service_specs_of_release release with
  | Ok specs -> specs
  | Error msg -> Windtrap.failf "reconstruction failed: %s" msg
;;

let live_of release =
  reconstruct release
  |> List.map (fun (spec, identity) -> Sol_cli_rollback.identity_of_spec spec, identity)
;;

(* The `release` label a workload's objects carry: its own immutable identity, derived
   from its effective spec ([Sol_cli_deployment_plan.workload_release_id]), not the
   recorded deploy id. *)
let workload_identity ~release spec =
  Sol_cli_release_id.to_string
    (Sol_cli_deployment_plan.workload_release_id
       ~workspace:release.Sol_cli_release.workspace
       ~environment:release.Sol_cli_release.environment
       spec)
;;

let plan_with_services plan ~services ~requested_scope =
  let release_id =
    Sol_cli_release_id.of_content
      { workspace = plan.Sol_cli_deployment_plan.workspace
      ; environment = plan.environment.env
      ; workloads = List.map R.workload_of_spec services
      ; contract = []
      }
  in
  { plan with services; requested_scope; release_id }
;;

let two_service_plan plan =
  match plan.Sol_cli_deployment_plan.services with
  | [ charge ] ->
    plan_with_services
      plan
      ~services:[ charge; second_service charge ]
      ~requested_scope:"workspace"
  | specs -> Windtrap.failf "expected one planned service, got %d" (List.length specs)
;;

let scoped_update plan =
  match plan.Sol_cli_deployment_plan.services with
  | [ charge ] ->
    plan_with_services
      plan
      ~services:[ { charge with image = "reg/myworkspace/charge-svc:def5678" } ]
      ~requested_scope:"payments/charge_svc"
  | specs -> Windtrap.failf "expected one planned service, got %d" (List.length specs)
;;

let test_scoped_deploy_records_a_complete_boundary () =
  with_plan ~requested_scope:"workspace" (fun plan ->
    let full = two_service_plan plan in
    let boundary_a = R.of_plan_with_boundary ~apply_mode:R.Direct ~retained:[] full in
    check_int
      "a full boundary records every workload"
      2
      (List.length boundary_a.workloads);
    check_string
      "a full boundary's id is exactly its content id"
      (Sol_cli_release_id.to_string
         (Sol_cli_release_id.of_content
            { Sol_cli_release_id.workspace = full.Sol_cli_deployment_plan.workspace
            ; environment = full.environment.env
            ; workloads = List.map R.workload_of_spec full.services
            ; contract = []
            }))
      boundary_a.release_id;
    check_string
      "a full boundary's content rederives its id"
      boundary_a.release_id
      (Sol_cli_release_id.to_string (R.derived_release_id boundary_a));
    let boundary_b =
      R.of_plan_with_boundary
        ~apply_mode:R.Direct
        ~retained:boundary_a.workloads
        (scoped_update plan)
    in
    check_int "a scoped boundary stays complete" 2 (List.length boundary_b.workloads);
    check_bool
      "a scoped boundary is a new identity"
      false
      (String.equal boundary_a.release_id boundary_b.release_id);
    check_string
      "a scoped boundary's content rederives its id"
      boundary_b.release_id
      (Sol_cli_release_id.to_string (R.derived_release_id boundary_b));
    let charge = recorded_of boundary_b "charge_svc"
    and ledger = recorded_of boundary_b "ledger_svc" in
    check_bool
      "the in-scope workload carries the new spec"
      true
      (Sol_cli_string.contains ~needle:"def5678" charge.Sol_cli_release_id.spec.image);
    check_string
      "the in-scope workload is applied by this deploy"
      (Sol_cli_release_id.to_string (scoped_update plan).release_id)
      charge.Sol_cli_release_id.applied_by;
    let scoped = scoped_update plan in
    let rendered =
      match scoped.services with
      | [ spec ] ->
        (match
           Sol_cli_deployment_render.render_spec
             ~workspace:scoped.workspace
             ~release_id:scoped.release_id
             spec
         with
         | Ok bundle -> bundle.prerequisites_yaml ^ bundle.workload_yaml
         | Error msg -> Windtrap.fail msg)
      | _ -> Windtrap.fail "expected one scoped service"
    in
    check_bool
      "the live manifest carries the recorded provenance"
      true
      (Sol_cli_string.contains
         ~needle:("release: \"" ^ charge.applied_by ^ "\"")
         rendered);
    check_string
      "the untouched workload keeps its spec"
      (recorded_of boundary_a "ledger_svc").Sol_cli_release_id.spec.image
      ledger.Sol_cli_release_id.spec.image;
    check_string
      "the untouched workload keeps its provenance"
      boundary_a.release_id
      ledger.Sol_cli_release_id.applied_by)
;;

let test_selected_plan_builder_preserves_scoped_provenance () =
  with_plan ~requested_scope:"workspace" (fun _ ->
    let ledger : Sol_cli_manifest.service =
      { domain = "payments"
      ; name = "ledger_svc"
      ; primitive = Sol_cli_manifest.Svc
      ; dir = "app/payments/ledger_svc"
      }
    in
    write_file "app/payments/ledger_svc/sol.toml" "";
    let build ~services ~requested_scope ~env =
      match
        Sol_cli_deployment_plan.of_services_result
          ~facts:(facts ())
          ~workspace:"myworkspace"
          ~env
          ~requested_scope
          services
      with
      | Ok plan -> plan
      | Error e -> Windtrap.fail (Sol_cli_deployment_plan.plan_error_to_string e)
    in
    let full =
      build ~services:[ test_service; ledger ] ~requested_scope:"workspace" ~env:test_env
    in
    let scoped =
      build
        ~services:[ test_service ]
        ~requested_scope:"payments/charge_svc"
        ~env:{ test_env with image_tag = "updated" }
    in
    let previous = R.of_plan_with_boundary ~apply_mode:R.Direct ~retained:[] full in
    let current =
      R.of_plan_with_boundary ~apply_mode:R.Direct ~retained:previous.workloads scoped
    in
    let selected = recorded_of current "charge_svc" in
    let inherited = recorded_of current "ledger_svc" in
    check_string
      "selected plan id is live provenance"
      (Sol_cli_release_id.to_string scoped.release_id)
      selected.applied_by;
    check_string "inherited provenance remains" previous.release_id inherited.applied_by;
    check_string
      "complete boundary rederives"
      current.release_id
      (Sol_cli_release_id.to_string (R.derived_release_id current));
    match R.validate ~name:(R.configmap_name current) current with
    | Ok () -> ()
    | Error msg -> Windtrap.fail msg)
;;

let test_scoped_rollback_keeps_untouched_workloads () =
  with_plan ~requested_scope:"workspace" (fun plan ->
    let boundary_a =
      R.of_plan_with_boundary ~apply_mode:R.Direct ~retained:[] (two_service_plan plan)
    in
    let boundary_b =
      R.of_plan_with_boundary
        ~apply_mode:R.Direct
        ~retained:boundary_a.workloads
        (scoped_update plan)
    in
    let expected_b = reconstruct boundary_b in
    check_int
      "a scoped boundary's rollback set covers the untouched workload"
      2
      (List.length expected_b);
    let report =
      Sol_cli_rollback.verify_workloads ~expected:expected_b ~live:(live_of boundary_b)
    in
    check_bool
      "the scoped boundary verifies against its own live state"
      true
      (Sol_cli_rollback.workload_report_ok report);
    check_int
      "rolling back to the scoped boundary prunes nothing"
      0
      (List.length report.Sol_cli_rollback.unexpected);
    let ledger_spec =
      List.assoc
        "ledger_svc"
        (List.map
           (fun (spec, _) -> spec.Sol_cli_deployment_plan.source_name, spec)
           expected_b)
    in
    check_string
      "the untouched workload is verified under its own immutable identity"
      (workload_identity ~release:boundary_b ledger_spec)
      (List.assoc
         "ledger_svc"
         (List.map
            (fun (spec, identity) -> spec.Sol_cli_deployment_plan.source_name, identity)
            expected_b));
    check_int
      "rolling back to the full boundary covers both workloads"
      2
      (List.length (reconstruct boundary_a));
    let expected_a = reconstruct boundary_a in
    let report_a =
      Sol_cli_rollback.verify_workloads ~expected:expected_a ~live:(live_of boundary_a)
    in
    check_bool
      "rolling back to the full boundary prunes nothing"
      true
      (Sol_cli_rollback.workload_report_ok report_a))
;;

let test_full_deploy_removes_a_dropped_workload () =
  with_plan ~requested_scope:"workspace" (fun plan ->
    let boundary_a =
      R.of_plan_with_boundary ~apply_mode:R.Direct ~retained:[] (two_service_plan plan)
    in
    let boundary_b =
      R.of_plan_with_boundary
        ~apply_mode:R.Direct
        ~retained:boundary_a.workloads
        (scoped_update plan)
    in
    let dropped =
      match plan.Sol_cli_deployment_plan.services with
      | [ charge ] -> { plan with services = [ charge ]; requested_scope = "workspace" }
      | specs -> Windtrap.failf "expected one planned service, got %d" (List.length specs)
    in
    let boundary_c =
      R.of_plan_with_boundary ~apply_mode:R.Direct ~retained:boundary_b.workloads dropped
    in
    check_int
      "a full deploy supersedes every workload"
      1
      (List.length boundary_c.workloads);
    let report =
      Sol_cli_rollback.verify_workloads
        ~expected:(reconstruct boundary_c)
        ~live:(live_of boundary_b)
    in
    check_int
      "the removed workload is surplus for that boundary"
      1
      (List.length report.Sol_cli_rollback.unexpected))
;;

let with_failing_kubectl f =
  let dir = Filename.temp_file "sol-fake-kubectl" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let path = Filename.concat dir "kubectl" in
  let oc = open_out path in
  output_string oc "#!/bin/sh\nexit 1\n";
  close_out oc;
  Unix.chmod path 0o755;
  let old = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" (dir ^ ":" ^ Option.value old ~default:"");
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" (Option.value old ~default:"");
      Sys.remove path;
      Unix.rmdir dir)
    f
;;

let read_boundary () =
  Sol_cli_release_store.retained_for_plan
    ~ctx:Sol_cli_kube_destination.local_context
    ~workspace:"myworkspace"
;;

let test_whole_target_deploy_tolerates_an_unreadable_boundary () =
  with_plan ~requested_scope:"workspace" (fun _plan ->
    with_failing_kubectl (fun () ->
      match read_boundary () with
      | Ok [] -> ()
      | Ok retained ->
        Windtrap.failf
          "expected an unreadable boundary to retain nothing, got %d"
          (List.length retained)
      | Error msg -> Windtrap.failf "expected a whole-target deploy to proceed: %s" msg))
;;

let test_of_plan_rederives_the_plan_identity () =
  with_plan ~requested_scope:"payments" (fun plan ->
    let r = R.of_plan ~apply_mode:R.Direct plan in
    check_string
      "record id is the plan id"
      (Sol_cli_release_id.to_string plan.release_id)
      r.release_id;
    check_string
      "record content rederives the plan id"
      (Sol_cli_release_id.to_string plan.release_id)
      (Sol_cli_release_id.to_string (R.derived_release_id r));
    check_int "one resolved workload" 1 (List.length r.workloads);
    let recorded = List.hd r.workloads in
    let w = R.workload_identity recorded in
    check_string "workload name" "charge_svc" w.name;
    check_bool
      "image recorded"
      true
      (Sol_cli_string.contains ~needle:"charge-svc" w.image);
    check_string
      "the deploy records itself as the applier"
      (Sol_cli_release_id.to_string plan.release_id)
      recorded.Sol_cli_release_id.applied_by)
;;

let test_same_content_same_record () =
  with_plan ~requested_scope:"payments" (fun plan_a ->
    with_plan ~requested_scope:"workspace" (fun plan_b ->
      let a = R.of_plan ~apply_mode:R.Direct plan_a
      and b = R.of_plan ~apply_mode:R.Direct plan_b in
      check_string "same id" a.release_id b.release_id;
      check_string "same record bytes" (R.to_configmap_json a) (R.to_configmap_json b)))
;;

let test_bundle_files_are_deterministic () =
  let files = R.bundle_files sample_record in
  check_int "record + pointer" 2 (List.length files);
  check_bool
    "record file is named by the id"
    true
    (List.mem_assoc (R.configmap_name sample_record ^ ".yaml") files);
  check_bool "pointer file present" true (List.mem_assoc "sol-current-release.yaml" files);
  check_bool
    "record content is stable"
    true
    (List.assoc (R.configmap_name sample_record ^ ".yaml") files
     = R.to_configmap_json sample_record)
;;

let test_record_failure_fails_the_deployment () =
  let reported = ref false in
  let result =
    R.finish_deployment
      ~record_release:(fun () ->
        Error
          "error when patching \"sol-release-current-pluto\": configmaps \
           \"sol-release-current-pluto\" is forbidden")
      ~report_success:(fun () -> reported := true)
  in
  check_bool "no successful completion was reported" false !reported;
  match result with
  | Ok () -> Windtrap.fail "a deployment that could not record its release must fail"
  | Error msg -> assert (Sol_cli_string.contains ~needle:"sol-release-current-pluto" msg)
;;

let test_recorded_release_reports_success () =
  let reported = ref false in
  match
    R.finish_deployment
      ~record_release:(fun () -> Ok ())
      ~report_success:(fun () -> reported := true)
  with
  | Error msg -> Windtrap.fail ("unexpected failure: " ^ msg)
  | Ok () -> check_bool "success was reported" true !reported
;;

let%test "sanitization" = test_sanitize_label ()
let%test "record: json round trip" = test_json_round_trip ()
let%test "record: configmap object" = test_configmap_object ()
let%test "record: pointer is minimal" = test_current_pointer_is_minimal ()
let%test "record: apply_mode round-trips" = test_apply_mode_round_trips ()

let%test "record: missing apply_mode fails closed" =
  test_apply_mode_missing_fails_closed ()
;;

let%test "record: unknown apply_mode fails closed" =
  test_apply_mode_unknown_fails_closed ()
;;

let%test "validate: accepts a canonical record" =
  test_validate_accepts_canonical_record ()
;;

let%test "validate: rejects a wrong name" = test_validate_rejects_wrong_name ()
let%test "validate: rejects corrupt content" = test_validate_rejects_corrupt_content ()

let%test "validate: reports a stale encoding_version, not corruption" =
  test_validate_reports_stale_encoding_version ()
;;

let%test "release: a pre-requirements record is refused by name" =
  test_a_pre_requirements_record_is_refused_by_name ()
;;

let%test "release: a stripped requirement field is refused" =
  test_a_stripped_requirement_field_is_refused ()
;;

let%test "validate: reports an undeclared encoding_version, not corruption" =
  test_validate_reports_undeclared_encoding_version ()
;;

let%test "record: an absent encoding_version stays unmarked" =
  test_of_json_without_encoding_version_is_unmarked ()
;;

let%test "read: reports a stale encoding_version, not corruption" =
  test_of_kubectl_item_reports_stale_encoding_version ()
;;

let%test "read: reads valid items" = test_parse_kubectl_list_reads_valid_items ()

let%test "read: reads creation timestamps (FEAT-072 retention)" =
  test_parse_kubectl_list_with_creation ()
;;

let%test "read: fails closed on corrupt records" =
  test_parse_kubectl_list_fails_closed_on_corrupt ()
;;

let%test "read: accepts a canonical item" =
  test_of_kubectl_item_accepts_canonical_record ()
;;

let%test "read: rejects a missing integrity digest" =
  test_of_kubectl_item_rejects_missing_digest ()
;;

let%test "read: rejects a tampered body" = test_of_kubectl_item_rejects_tampered_body ()

let%test "read: catches migrations tampering that validate misses" =
  test_migrations_tampering_is_caught_by_digest_not_validate ()
;;

let%test "read: table lists the id" = test_format_table_lists_the_id ()

let%test "canonicalization: digest is order-independent" =
  test_record_digest_is_order_independent ()
;;

let%test "canonicalization: duplicate keys are totally ordered" =
  test_record_digest_is_total_for_duplicate_keys ()
;;

let%test "canonicalization: known canonical digest" = test_record_digest_known_vector ()

let%test "release record: the deployed contract round trips" =
  test_contract_round_trips ()
;;

let%test "scoped boundary (BUG-077): a scoped deploy records a complete boundary" =
  test_scoped_deploy_records_a_complete_boundary ()
;;

let%test "scoped boundary (BUG-077): selected plan builder preserves scoped provenance" =
  test_selected_plan_builder_preserves_scoped_provenance ()
;;

let%test
    "scoped boundary (BUG-077): rolling back to a scoped boundary keeps untouched \
     workloads"
  =
  test_scoped_rollback_keeps_untouched_workloads ()
;;

let%test "scoped boundary (BUG-077): a full deploy supersedes every workload" =
  test_full_deploy_removes_a_dropped_workload ()
;;

let%test "whole-target boundary: an unreadable boundary retains nothing" =
  test_whole_target_deploy_tolerates_an_unreadable_boundary ()
;;

let%test "of_plan: rederives the plan identity" =
  test_of_plan_rederives_the_plan_identity ()
;;

let%test "of_plan: same content, same record" = test_same_content_same_record ()

let%test "of_plan: bundle files are deterministic" =
  test_bundle_files_are_deterministic ()
;;

let%test "deployment outcome (DEC-037): a failed release record fails the deployment" =
  test_record_failure_fails_the_deployment ()
;;

let%test "deployment outcome (DEC-037): a recorded release reports success" =
  test_recorded_release_reports_success ()
;;

(* Ownership evidence is captured at apply and recorded per workload. Its absence
   must read as "no evidence", never as a corrupt record: a release written before
   UID capture has no [owned] field and must still read. *)
let rec strip_owned_json = function
  | `Assoc fields ->
    `Assoc
      (List.filter_map
         (fun (k, v) ->
            if String.equal k "owned" then None else Some (k, strip_owned_json v))
         fields)
  | `List items -> `List (List.map strip_owned_json items)
  | other -> other
;;

let rec corrupt_owned_json = function
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (k, v) ->
            k, if String.equal k "owned" then `String "nonsense" else corrupt_owned_json v)
         fields)
  | `List items -> `List (List.map corrupt_owned_json items)
  | other -> other
;;

let test_owned_evidence_round_trips_and_absence_is_no_evidence () =
  let evidence =
    [ { Sol_cli_release_id.resource = "deployment"
      ; namespace = "myworkspace-charge"
      ; name = "charge-svc"
      ; uid = "0f6a1b2c-1111-2222-3333-444455556666"
      }
    ]
  in
  let with_evidence =
    { sample_record with
      workloads =
        List.map
          (fun (w : Sol_cli_release.recorded_workload) ->
             { w with Sol_cli_release_id.owned = evidence })
          sample_record.workloads
    }
  in
  (match R.of_json (R.to_json with_evidence) with
   | Error msg -> Windtrap.fail msg
   | Ok r ->
     let o = List.hd (List.hd r.workloads).Sol_cli_release_id.owned in
     check_string "uid preserved" "0f6a1b2c-1111-2222-3333-444455556666" o.uid;
     check_string "resource preserved" "deployment" o.resource);
  (match R.of_json (strip_owned_json (R.to_json sample_record)) with
   | Error msg -> Windtrap.fail ("a record with no UID evidence must still read: " ^ msg)
   | Ok r ->
     check_int
       "absence is no evidence"
       0
       (List.length (List.hd r.workloads).Sol_cli_release_id.owned));
  match R.of_json (corrupt_owned_json (R.to_json sample_record)) with
  | Error msg ->
    Windtrap.fail ("malformed ownership evidence must not fail the read: " ^ msg)
  | Ok r ->
    check_int
      "malformed is no evidence"
      0
      (List.length (List.hd r.workloads).Sol_cli_release_id.owned)
;;

let%test "release: UID evidence round-trips, absence is no evidence" =
  test_owned_evidence_round_trips_and_absence_is_no_evidence ()
;;

(* Ownership evidence is captured beside a workload, not part of its content: two
   records with the same intent and different applied UIDs share a record digest,
   and a record that carries evidence still reads back through the ConfigMap
   integrity check. *)
let test_record_digest_excludes_ownership_evidence () =
  let with_uid uid =
    { sample_record with
      workloads =
        List.map
          (fun (w : Sol_cli_release.recorded_workload) ->
             { w with
               Sol_cli_release_id.owned =
                 [ { Sol_cli_release_id.resource = "deployment"
                   ; namespace = "myworkspace-charge"
                   ; name = "charge-svc"
                   ; uid
                   }
                 ]
             })
          sample_record.workloads
    }
  in
  let uid = "0f6a1b2c-1111-2222-3333-444455556666" in
  check_string
    "different applied UIDs share a digest"
    (R.record_digest (with_uid uid))
    (R.record_digest (with_uid "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"));
  check_string
    "ownership evidence does not change the digest"
    (R.record_digest sample_record)
    (R.record_digest (with_uid uid));
  match
    R.of_kubectl_item
      (item
         ~digest:(R.record_digest (with_uid uid))
         (R.record_json_string (with_uid uid)))
  with
  | Error msg -> Windtrap.fail ("a record carrying ownership evidence must read: " ^ msg)
  | Ok r ->
    let o = List.hd (List.hd r.workloads).Sol_cli_release_id.owned in
    check_string "uid survives the ConfigMap read" uid o.uid
;;

let%test "release: record digest excludes ownership evidence" =
  test_record_digest_excludes_ownership_evidence ()
;;

(* Evidence binds to the full (kind, namespace, name) identity, not the name alone:
   two units can normalize to one k8s_name while projecting to different kinds (a
   Deployment and a CronJob both named [charge-svc]), and each must keep only its own
   UID — a shared name must not attach another object's evidence. *)
let test_ownership_evidence_binds_to_kind_and_name () =
  with_plan ~requested_scope:"workspace" (fun plan ->
    let charge =
      match plan.Sol_cli_deployment_plan.services with
      | [ charge ] -> charge
      | specs -> Windtrap.failf "expected one planned service, got %d" (List.length specs)
    in
    let charge_fn =
      { charge with Sol_cli_deployment_plan.primitive = Sol_cli_deployment_plan.Fn }
    in
    let plan =
      plan_with_services plan ~services:[ charge; charge_fn ] ~requested_scope:"workspace"
    in
    let namespace = Sol_cli_deployment_plan.namespace_to_string charge.namespace in
    let name = Sol_cli_deployment_plan.k8s_name_to_string charge.k8s_name in
    let owned =
      [ { Sol_cli_release_id.resource = "deployment"
        ; namespace
        ; name
        ; uid = "deploy-uid"
        }
      ; { Sol_cli_release_id.resource = "cronjob"; namespace; name; uid = "cronjob-uid" }
      ]
    in
    let boundary =
      R.of_plan_with_boundary ~owned ~apply_mode:R.Direct ~retained:[] plan
    in
    let owned_of primitive =
      boundary.workloads
      |> List.find_map (fun (w : R.recorded_workload) ->
        if String.equal w.Sol_cli_release_id.spec.primitive primitive
        then Some w.Sol_cli_release_id.owned
        else None)
      |> Option.value ~default:[]
    in
    match owned_of "svc", owned_of "fn" with
    | [ deployment ], [ cronjob ] ->
      check_string "the Deployment keeps only its own UID" "deploy-uid" deployment.uid;
      check_string "the CronJob keeps only its own UID" "cronjob-uid" cronjob.uid
    | _ -> Windtrap.fail "expected exactly one evidence entry per workload")
;;

let%test "release: ownership evidence binds to kind, not name alone" =
  test_ownership_evidence_binds_to_kind_and_name ()
;;
