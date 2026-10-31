let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let wl
      ?(domain = "payments")
      ?(primitive = "svc")
      ?(config = [])
      ?(secrets = [])
      ?(schedule = None)
      ?(replicas = 1)
      ?(availability = "single")
      ?(consumes_kafka = false)
      ?(cpu = "100m")
      ?(memory = "128Mi")
      ?(extra_labels = [])
      ?(volumes = [])
      ?(rollout = "rolling_update")
      ?(ingress_host = None)
      ?(ingress_path = None)
      ?(cluster_issuer = "letsencrypt-prod")
      ?(calls = [])
      ?(schedule_timezone = None)
      ?(scheduled_concurrency = "allow")
      ?(backoff_limit = 3)
      name
      image
  =
  { Sol_cli_release_id.domain
  ; name
  ; primitive
  ; image
  ; config
  ; secrets
  ; uses = []
  ; external_secret_refs = []
  ; schedule
  ; schedule_timezone
  ; scheduled_concurrency
  ; backoff_limit
  ; replicas
  ; availability
  ; consumes_kafka
  ; cpu
  ; memory
  ; extra_labels
  ; volumes
  ; rollout
  ; ingress_host
  ; ingress_path
  ; cluster_issuer
  ; calls
  }
;;

let content ?(workspace = "acme") ?(environment = Some "prod") workloads
  : Sol_cli_release_id.content
  =
  { Sol_cli_release_id.workspace; environment; workloads; contract = [] }
;;

let id c = Sol_cli_release_id.to_string (Sol_cli_release_id.of_content c)

let test_deterministic () =
  let c = content [ wl "charge_svc" "acme/charge:1" ] in
  check_string "same content, same id" (id c) (id c)
;;

let test_workload_order_is_not_semantic () =
  let a = wl "charge_svc" "acme/charge:1" in
  let b = wl "settle_worker" "acme/settle:1" in
  check_string
    "workload order does not change identity"
    (id (content [ a; b ]))
    (id (content [ b; a ]))
;;

let test_config_key_order_is_not_semantic () =
  let a = [ "LOG_LEVEL", "info"; "POOL_SIZE", "10" ] in
  let b = [ "POOL_SIZE", "10"; "LOG_LEVEL", "info" ] in
  check_string
    "config key order does not change identity"
    (id (content [ wl ~config:a "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~config:b "charge_svc" "acme/charge:1" ]))
;;

let test_secret_reference_order_is_not_semantic () =
  let a = [ "DATABASE_URL", "db-prod"; "API_KEY", "api-prod" ] in
  let b = [ "API_KEY", "api-prod"; "DATABASE_URL", "db-prod" ] in
  check_string
    "secret reference order does not change identity"
    (id (content [ wl ~secrets:a "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~secrets:b "charge_svc" "acme/charge:1" ]))
;;

let test_extra_label_order_is_not_semantic () =
  let a = [ "team", "payments"; "tier", "edge" ] in
  let b = [ "tier", "edge"; "team", "payments" ] in
  check_string
    "extra label order does not change identity"
    (id (content [ wl ~extra_labels:a "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~extra_labels:b "charge_svc" "acme/charge:1" ]))
;;

let test_image_change_changes_identity () =
  check_bool
    "a different image is a different release"
    true
    (id (content [ wl "charge_svc" "acme/charge:2" ])
     <> id (content [ wl "charge_svc" "acme/charge:1" ]))
;;

let test_scaling_change_changes_identity () =
  check_bool
    "different replicas is a different release"
    true
    (id (content [ wl ~replicas:3 "charge_svc" "acme/charge:1" ])
     <> id (content [ wl ~replicas:1 "charge_svc" "acme/charge:1" ]))
;;

let test_config_value_change_changes_identity () =
  check_bool
    "a changed config value is a different release"
    true
    (id (content [ wl ~config:[ "POOL_SIZE", "20" ] "charge_svc" "acme/charge:1" ])
     <> id (content [ wl ~config:[ "POOL_SIZE", "10" ] "charge_svc" "acme/charge:1" ]))
;;

let test_workspace_and_environment_change_identity () =
  check_bool
    "a different workspace is a different release"
    true
    (id (content [ wl "charge_svc" "acme/charge:1" ])
     <> id (content ~workspace:"other" [ wl "charge_svc" "acme/charge:1" ]));
  check_bool
    "a different environment is a different release"
    true
    (id (content ~environment:(Some "prod") [ wl "charge_svc" "acme/charge:1" ])
     <> id (content ~environment:(Some "staging") [ wl "charge_svc" "acme/charge:1" ]));
  check_bool
    "no environment differs from an empty one"
    true
    (id (content ~environment:None [ wl "charge_svc" "acme/charge:1" ])
     <> id (content ~environment:(Some "") [ wl "charge_svc" "acme/charge:1" ]))
;;

let test_secret_references_count_and_values_do_not () =
  check_bool
    "a different secret reference is a different release"
    true
    (id
       (content
          [ wl ~secrets:[ "DATABASE_URL", "db-prod" ] "charge_svc" "acme/charge:1" ])
     <> id
          (content
             [ wl ~secrets:[ "DATABASE_URL", "db-other" ] "charge_svc" "acme/charge:1" ])
    );
  let with_reference =
    wl ~secrets:[ "DATABASE_URL", "db-prod" ] "charge_svc" "acme/charge:1"
  in
  check_bool
    "the projection carries the reference, not the material"
    true
    (let s = Sol_cli_release_id.canonical_string (content [ with_reference ]) in
     Sol_cli_string.contains ~needle:"DATABASE_URL" s
     && Sol_cli_string.contains ~needle:"db-prod" s)
;;

let test_external_secret_reference_changes_release_identity () =
  let base = wl "charge_svc" "acme/charge:1" in
  let with_ref remote =
    { base with external_secret_refs = [ "PAYMENT_API_KEY", "payments-vault", remote ] }
  in
  check_bool
    "an external remote reference changes release identity"
    true
    (id (content [ with_ref "production/payment-api" ])
     <> id (content [ with_ref "staging/payment-api" ]));
  check_string
    "external reference ordering is not semantic"
    (id
       (content
          [ { base with
              external_secret_refs =
                [ "PAYMENT_API_KEY", "payments-vault", "prod/api"
                ; "SMTP_KEY", "payments-vault", "prod/smtp"
                ]
            }
          ]))
    (id
       (content
          [ { base with
              external_secret_refs =
                [ "SMTP_KEY", "payments-vault", "prod/smtp"
                ; "PAYMENT_API_KEY", "payments-vault", "prod/api"
                ]
            }
          ]))
;;

let test_encoding_is_unambiguous () =
  check_bool
    "adjacent fields cannot bleed into each other"
    true
    (id (content [ wl "ab" "c" ]) <> id (content [ wl "a" "bc" ]))
;;

let test_id_is_a_legal_label_value () =
  let value = id (content [ wl "charge_svc" "acme/charge:1" ]) in
  check_bool "short enough for a label value" true (String.length value <= 63);
  check_bool
    "starts with an alphanumeric"
    true
    (match value.[0] with
     | 'a' .. 'z' | '0' .. '9' -> true
     | _ -> false);
  let legal =
    String.for_all
      (function
        | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> true
        | _ -> false)
      value
  in
  check_bool "only label-value characters" true legal
;;

let test_of_string_round_trips_and_validates () =
  let rendered = id (content [ wl "charge_svc" "acme/charge:1" ]) in
  (match Sol_cli_release_id.of_string rendered with
   | Ok parsed -> check_string "round trip" rendered (Sol_cli_release_id.to_string parsed)
   | Error msg -> Windtrap.fail ("valid id rejected: " ^ msg));
  List.iter
    (fun bad ->
       check_bool
         (Printf.sprintf "rejects %S" bad)
         true
         (match Sol_cli_release_id.of_string bad with
          | Ok _ -> false
          | Error _ -> true))
    [ ""
    ; "r-"
    ; "r-abc"
    ; "r-0123456789abcdefg"
    ; "R-0123456789abcdef"
    ; "0123456789abcdef"
    ; "r-0123456789ABCDEF"
    ]
;;

let test_known_vector () =
  check_string
    "known id for a fixed content"
    "r-25d3a8757f181091"
    (id
       (content
          [ wl
              ~config:[ "LOG_LEVEL", "info" ]
              ~secrets:[ "DATABASE_URL", "db-prod" ]
              "charge_svc"
              "acme/charge:1"
          ]))
;;

let fact ?(key = None) ?(schema_digest = "deadbeef") ~topic ~partitions subject =
  { Sol_cli_release_id.subject; topic; partitions; key; schema_digest }
;;

let test_contract_is_part_of_identity () =
  let base = content [ wl "charge_svc" "acme/charge:1" ] in
  let with_contract contract = { base with Sol_cli_release_id.contract } in
  check_bool
    "a declared contract is part of the release identity"
    true
    (id base
     <> id (with_contract [ fact ~topic:"acme-charges" ~partitions:3 "payments.Charged" ])
    );
  check_string
    "contract fact order does not change identity"
    (id
       (with_contract
          [ fact ~topic:"a" ~partitions:1 "t.A"; fact ~topic:"b" ~partitions:2 "t.B" ]))
    (id
       (with_contract
          [ fact ~topic:"b" ~partitions:2 "t.B"; fact ~topic:"a" ~partitions:1 "t.A" ]));
  check_bool
    "a partition change is a different release"
    true
    (id (with_contract [ fact ~topic:"a" ~partitions:1 "t.A" ])
     <> id (with_contract [ fact ~topic:"a" ~partitions:6 "t.A" ]))
;;

let test_environment_identity_counts_not_just_resolved_state () =
  let same_state =
    [ wl ~config:[ "FOO", "1" ] ~replicas:2 "charge_svc" "acme/charge:1" ]
  in
  check_bool
    "identical resolved state in two environments is two releases"
    true
    (id (content ~environment:(Some "staging") same_state)
     <> id (content ~environment:(Some "prod") same_state));
  check_string
    "identical resolved state in one environment is one release"
    (id (content ~environment:(Some "prod") same_state))
    (id (content ~environment:(Some "prod") same_state));
  check_bool
    "no environment is its own identity, not a wildcard"
    true
    (id (content ~environment:None same_state)
     <> id (content ~environment:(Some "prod") same_state))
;;

let test_manifest_affecting_fields_change_identity () =
  let base = id (content [ wl "charge_svc" "acme/charge:1" ]) in
  let moved label other = check_bool label true (base <> id (content [ other ])) in
  moved
    "volume change"
    (wl
       ~volumes:[ "data", "/data", "1Gi", "read_write_once" ]
       "charge_svc"
       "acme/charge:1");
  moved "rollout change" (wl ~rollout:"recreate" "charge_svc" "acme/charge:1");
  moved "canary steps change" (wl ~rollout:"canary:w10,w100" "charge_svc" "acme/charge:1");
  moved
    "ingress host change"
    (wl ~ingress_host:(Some "charge.example.com") "charge_svc" "acme/charge:1");
  moved
    "ingress path change"
    (wl ~ingress_path:(Some "/api") "charge_svc" "acme/charge:1");
  moved
    "cluster issuer change"
    (wl ~cluster_issuer:"other-issuer" "charge_svc" "acme/charge:1");
  moved
    "service call change"
    (wl ~calls:[ "X_URL", "x", "x-svc", "ns-x" ] "charge_svc" "acme/charge:1");
  moved
    "scheduled concurrency change"
    (wl ~scheduled_concurrency:"forbid" "charge_svc" "acme/charge:1");
  moved "backoff limit change" (wl ~backoff_limit:0 "charge_svc" "acme/charge:1")
;;

let test_canary_step_order_is_semantic () =
  check_bool
    "canary step order changes identity"
    true
    (id (content [ wl ~rollout:"canary:w10,w100" "charge_svc" "acme/charge:1" ])
     <> id (content [ wl ~rollout:"canary:w100,w10" "charge_svc" "acme/charge:1" ]))
;;

let test_volume_and_call_order_is_not_semantic () =
  let v1 = "a", "/a", "1Gi", "read_write_once"
  and v2 = "b", "/b", "2Gi", "read_only_many" in
  check_string
    "volume order does not change identity"
    (id (content [ wl ~volumes:[ v1; v2 ] "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~volumes:[ v2; v1 ] "charge_svc" "acme/charge:1" ]));
  let c1 = "A_URL", "a", "a-svc", "ns-a"
  and c2 = "B_URL", "b", "b-svc", "ns-b" in
  check_string
    "call order does not change identity"
    (id (content [ wl ~calls:[ c1; c2 ] "charge_svc" "acme/charge:1" ]))
    (id (content [ wl ~calls:[ c2; c1 ] "charge_svc" "acme/charge:1" ]))
;;

let%test "identity: deterministic" = test_deterministic ()

let%test "identity: workload order is not semantic" =
  test_workload_order_is_not_semantic ()
;;

let%test "identity: config key order is not semantic" =
  test_config_key_order_is_not_semantic ()
;;

let%test "identity: secret reference order is not semantic" =
  test_secret_reference_order_is_not_semantic ()
;;

let%test "identity: extra label order is not semantic" =
  test_extra_label_order_is_not_semantic ()
;;

let%test "identity: image change changes identity" = test_image_change_changes_identity ()

let%test "identity: scaling change changes identity" =
  test_scaling_change_changes_identity ()
;;

let%test "identity: config value change changes identity" =
  test_config_value_change_changes_identity ()
;;

let%test "identity: workspace and environment change identity" =
  test_workspace_and_environment_change_identity ()
;;

let%test "identity: secret references count, values do not" =
  test_secret_references_count_and_values_do_not ()
;;

let%test "identity: external secret references are release inputs" =
  test_external_secret_reference_changes_release_identity ()
;;

let%test "identity: encoding is unambiguous" = test_encoding_is_unambiguous ()

(* The id moved with `sol-release-v6 -> v7` (#1422): the content now carries each workload's
   declared requirements, so a release that declared them is a different boundary from one that
   did not. *)
let%test "identity: known vector" = test_known_vector ()
let%test "identity: contract is part of identity" = test_contract_is_part_of_identity ()

let%test "identity: environment identity counts, not just resolved state" =
  test_environment_identity_counts_not_just_resolved_state ()
;;

let%test "identity: manifest-affecting fields change identity" =
  test_manifest_affecting_fields_change_identity ()
;;

let%test "identity: canary step order is semantic" = test_canary_step_order_is_semantic ()

let%test "identity: volume and call order is not semantic" =
  test_volume_and_call_order_is_not_semantic ()
;;

let%test "value: id is a legal label value" = test_id_is_a_legal_label_value ()

let%test "value: of_string round trips and validates" =
  test_of_string_round_trips_and_validates ()
;;
