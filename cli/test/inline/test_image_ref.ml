let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_str msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual
let digest hex = "registry.example.com/pluto/charge-svc@sha256:" ^ hex
let valid_digest = digest (String.make 64 'a')

let test_is_digest_accepts_well_formed () =
  check_bool "valid lowercase digest" true (Sol_cli_image_ref.is_digest valid_digest);
  check_bool
    "registry with port and path"
    true
    (Sol_cli_image_ref.is_digest ("localhost:5000/ws/svc@sha256:" ^ String.make 64 '0'))
;;

let test_is_digest_rejects_malformed () =
  check_bool "plain tag" false (Sol_cli_image_ref.is_digest "repo:tag");
  check_bool
    "empty repo"
    false
    (Sol_cli_image_ref.is_digest ("@sha256:" ^ String.make 64 'a'));
  check_bool "short hex" false (Sol_cli_image_ref.is_digest (digest (String.make 63 'a')));
  check_bool "too long" false (Sol_cli_image_ref.is_digest (digest (String.make 65 'a')));
  check_bool
    "uppercase hex rejected"
    false
    (Sol_cli_image_ref.is_digest (digest (String.make 64 'A')));
  check_bool
    "wrong algorithm"
    false
    (Sol_cli_image_ref.is_digest
       ("registry.example.com/pluto/charge-svc@sha512:" ^ String.make 64 'a'));
  check_bool
    "space in repository"
    false
    (Sol_cli_image_ref.is_digest ("bad repo@sha256:" ^ String.make 64 'a'));
  check_bool
    "uppercase path component"
    false
    (Sol_cli_image_ref.is_digest
       ("registry.example.com/Pluto/charge-svc@sha256:" ^ String.make 64 'a'));
  check_bool
    "tag plus digest is a valid reference"
    true
    (Sol_cli_image_ref.is_digest
       ("registry.example.com/pluto/charge-svc:v1@sha256:" ^ String.make 64 'a'))
;;

let test_split_flag_value () =
  let name, ref = Sol_cli_image_ref.split_flag_value ("charge_svc=" ^ valid_digest) in
  check_bool "service prefix parsed" true (name = Some "charge_svc");
  check_str "reference preserved" valid_digest ref;
  let name, ref = Sol_cli_image_ref.split_flag_value valid_digest in
  check_bool "bare reference has no service" true (name = None);
  check_str "bare reference preserved" valid_digest ref
;;

let resolve = Sol_cli_image_ref.resolve

let test_resolve_named () =
  match resolve ~service_names:[ "a"; "b" ] [ Some "b", valid_digest ] with
  | Ok [ ("b", ref) ] -> check_str "resolved" valid_digest ref
  | Ok _ -> Windtrap.fail "expected a single resolved reference"
  | Error msg -> Windtrap.fail msg
;;

let test_resolve_bare_requires_one_service () =
  (match resolve ~service_names:[ "only" ] [ None, valid_digest ] with
   | Ok [ ("only", _) ] -> ()
   | Ok _ -> Windtrap.fail "expected the only service to be resolved"
   | Error msg -> Windtrap.fail msg);
  match resolve ~service_names:[ "a"; "b" ] [ None, valid_digest ] with
  | Ok _ -> Windtrap.fail "an ambiguous bare reference must fail"
  | Error msg -> check_bool "names the ambiguity" true (String.length msg > 0)
;;

let test_resolve_rejects_unknown_service () =
  match resolve ~service_names:[ "a" ] [ Some "typo", valid_digest ] with
  | Ok _ -> Windtrap.fail "an unknown service must fail"
  | Error msg -> check_bool "explains the failure" true (String.length msg > 0)
;;

let test_resolve_rejects_duplicates () =
  match
    resolve ~service_names:[ "a" ] [ Some "a", valid_digest; Some "a", valid_digest ]
  with
  | Ok _ -> Windtrap.fail "a duplicate service must fail"
  | Error _ -> ()
;;

let test_resolve_rejects_mutable_reference () =
  match resolve ~service_names:[ "a" ] [ Some "a", "repo:tag" ] with
  | Ok _ -> Windtrap.fail "a mutable reference must fail"
  | Error _ -> ()
;;

let test_plan_is_immutable () =
  check_bool "all digests" true (Sol_cli_image_ref.plan_is_immutable [ valid_digest ]);
  check_bool
    "one tag fails"
    false
    (Sol_cli_image_ref.plan_is_immutable [ valid_digest; "repo:tag" ]);
  check_bool "empty plan fails" false (Sol_cli_image_ref.plan_is_immutable [])
;;

let%test "is_digest: well formed" = test_is_digest_accepts_well_formed ()
let%test "is_digest: malformed" = test_is_digest_rejects_malformed ()
let%test "split_flag_value: service prefix" = test_split_flag_value ()
let%test "resolve: named" = test_resolve_named ()
let%test "resolve: bare requires one service" = test_resolve_bare_requires_one_service ()
let%test "resolve: unknown service" = test_resolve_rejects_unknown_service ()
let%test "resolve: duplicates" = test_resolve_rejects_duplicates ()
let%test "resolve: mutable reference" = test_resolve_rejects_mutable_reference ()
let%test "plan_is_immutable: predicate" = test_plan_is_immutable ()
