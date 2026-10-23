module S = Sol_cli_substrate

let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual

let docs_or_fail namespaces =
  S.docs_for_namespaces namespaces |> List.map (fun doc -> Sol_cli_yaml.render [ doc ])
;;

let test_substrate_is_namespace_and_role_bindings_only () =
  let docs = docs_or_fail [ "pluto-payments" ] in
  check_int "namespace + deploy RoleBinding + operator RoleBinding" 3 (List.length docs);
  check_bool
    "the namespace comes first"
    true
    (Sol_cli_string.contains ~needle:"kind: Namespace" (List.nth docs 0)
     && Sol_cli_string.contains ~needle:"pluto-payments" (List.nth docs 0));
  check_bool
    "then the deploy RoleBinding, scoped to this namespace"
    true
    (Sol_cli_string.contains ~needle:"kind: RoleBinding" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"namespace: pluto-payments" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"name: sol-deploy" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"name: sol:deployers" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"kind: ServiceAccount" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"name: sol-deploy" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"namespace: monitoring" (List.nth docs 1));
  check_bool
    "then the operator's read-only RoleBinding (DEC-038)"
    true
    (Sol_cli_string.contains ~needle:"kind: RoleBinding" (List.nth docs 2)
     && Sol_cli_string.contains ~needle:"namespace: pluto-payments" (List.nth docs 2)
     && Sol_cli_string.contains ~needle:"name: sol-operator-diagnostics" (List.nth docs 2)
     && Sol_cli_string.contains ~needle:"name: sol:operators" (List.nth docs 2));
  docs
  |> List.iter (fun doc ->
    List.iter
      (fun kind ->
         check_bool
           (Printf.sprintf "substrate carries no %s" kind)
           false
           (Sol_cli_string.contains ~needle:kind doc))
      [ "kind: Deployment\n"
      ; "kind: Service\n"
      ; "kind: PodDisruptionBudget\n"
      ; "kind: Ingress\n"
      ; "kind: Secret\n"
      ])
;;

let test_every_namespace_and_binding_is_present () =
  let docs = docs_or_fail [ "pluto-checkout"; "pluto-payments" ] in
  check_int
    "two namespaces + four RoleBindings (deploy and operator, per namespace)"
    6
    (List.length docs);
  check_bool
    "no substrate document is a Secret: ordinary deploy never writes one"
    true
    (not
       (List.exists (fun doc -> Sol_cli_string.contains ~needle:"kind: Secret" doc) docs));
  List.iter
    (fun ns ->
       check_bool
         (Printf.sprintf "namespace %s is established" ns)
         true
         (List.exists (fun doc -> Sol_cli_string.contains ~needle:ns doc) docs))
    [ "pluto-checkout"; "pluto-payments" ]
;;

let test_ensure_refuses_a_reserved_platform_namespace () =
  match
    S.ensure
      ~workloads:[]
      ~ctx:Sol_cli_kube_destination.local_context
      ~namespaces:[ "cert-manager" ]
  with
  | Ok () -> Windtrap.fail "expected ensure to refuse a reserved platform namespace"
  | Error msg ->
    check_bool
      "names the reserved namespace"
      true
      (Sol_cli_string.contains ~needle:"cert-manager" msg);
    check_bool "says it is reserved" true (Sol_cli_string.contains ~needle:"reserved" msg)
;;

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s
;;

let fake_kubectl ~log =
  Printf.sprintf
    {|#!/bin/sh
# Classify by the document's kind, record the verdict, then behave like the
# cluster the deploy identity actually talks to.
#
# Sol invokes kubectl as `kubectl --context <destination> <verb> ...`, so the
# destination's flags precede the verb -- find the verb by name, not position.
verb=""
for a in "$@"; do
  case "$a" in
    apply|create|delete|get|patch|replace|rollout|logs) verb="$a"; break ;;
  esac
done
file=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-f" ]; then file="$a"; fi
  prev="$a"
done
case "$*" in
  *"get configmap sol-platform-network"*)
    case "$EGRESS_FACT" in
      forbidden)
        echo 'Error from server (Forbidden): configmaps "sol-platform-network" is forbidden: cannot get resource "configmaps"' >&2
        exit 1 ;;
      absent)
        echo 'Error from server (NotFound): configmaps "sol-platform-network" not found' >&2
        exit 1 ;;
      *)
        printf '%%s' "$EGRESS_FACT"
        exit 0 ;;
    esac ;;
  *"get secret sol-secrets"*)
    echo '{"data":{"POSTGRES_URL":"cG9zdGdyZXM="}}'
    exit 0 ;;
esac
kind=other
if [ -n "$file" ] && grep -q 'kind: Namespace' "$file" 2>/dev/null; then
  kind=Namespace
fi
printf '%%s %%s\n' "$verb" "$kind" >> %s
if [ "$verb" = "apply" ] && [ -n "$file" ]; then
  cat "$file" >> %s.manifests
fi
if [ "$kind" = "Namespace" ]; then
  if [ "$verb" = "apply" ]; then
    echo 'Error from server (Forbidden): namespaces "pluto-checkout" is forbidden:' \
         'cannot patch resource "namespaces"' >&2
    exit 1
  fi
  if [ "$verb" = "create" ]; then
    echo 'Error from server (AlreadyExists): namespaces "pluto-checkout" already exists' >&2
    exit 1
  fi
fi
exit 0
|}
    log
    log
;;

let with_fake_kubectl ?(egress_fact = "absent") f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "kubectl" in
  let oc = open_out bin in
  output_string oc (fake_kubectl ~log);
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  let old_egress_fact =
    try Sys.getenv "EGRESS_FACT" with
    | Not_found -> ""
  in
  Unix.putenv "EGRESS_FACT" egress_fact;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      Unix.putenv "EGRESS_FACT" old_egress_fact;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      (try Sys.remove (log ^ ".manifests") with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f log)
;;

let test_namespace_is_created_not_applied () =
  with_fake_kubectl (fun log ->
    let ns_yaml =
      Sol_cli_yaml.render [ Sol_cli_manifest.namespace_doc ~ns:"pluto-checkout" ]
    in
    let workload_yaml =
      "---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: checkout-svc\n"
    in
    let ctx = Sol_cli_kube_destination.local_context in
    let bundle : Sol_cli_manifest.bundle =
      { namespace_yaml = ns_yaml; prerequisites_yaml = ""; workload_yaml }
    in
    let fail msg =
      Windtrap.failf
        "the namespace was applied instead of created; live error was: %s"
        msg
    in
    (match Sol_cli_manifest.apply_bundle_namespace ~ctx bundle with
     | Error msg -> fail msg
     | Ok () ->
       (match Sol_cli_manifest.apply_bundle_workload ~ctx bundle with
        | Error msg -> fail msg
        | Ok () -> ()));
    let calls = String.split_on_char '\n' (read_file log) in
    let call verb kind =
      List.exists (fun line -> String.equal (String.trim line) (verb ^ " " ^ kind)) calls
    in
    check_bool "the namespace is created" true (call "create" "Namespace");
    check_bool
      "the namespace is never applied (apply would need patch, which deploy lacks)"
      false
      (call "apply" "Namespace");
    check_bool
      "an AlreadyExists create on an existing namespace is tolerated, not fatal"
      true
      (call "create" "Namespace");
    check_bool "the workload is still applied" true (call "apply" "other"))
;;

let test_operator_bindings_cover_every_workload_namespace () =
  let svc domain name =
    { Sol_cli_manifest.domain; name; primitive = Sol_cli_manifest.Svc; dir = "/tmp" }
  in
  let docs =
    Sol_cli_substrate.operator_binding_docs
      ~workspace:"pluto"
      [ svc "checkout" "checkout_svc"
      ; svc "comms" "notify_worker"
      ; svc "checkout" "refunds"
      ]
    |> List.map (fun doc -> Sol_cli_yaml.render [ doc ])
  in
  check_int
    "one binding per distinct namespace, whoever the caller is"
    2
    (List.length docs);
  let has needle = List.exists (fun doc -> Sol_cli_string.contains ~needle doc) docs in
  check_bool
    "the namespace the caller was not operating on is covered"
    true
    (has "namespace: pluto-comms");
  check_bool "so is the caller's own" true (has "namespace: pluto-checkout");
  docs
  |> List.iter (fun doc ->
    check_bool
      "every document is a RoleBinding"
      true
      (Sol_cli_string.contains ~needle:"kind: RoleBinding" doc);
    check_bool
      "bound to the operator group"
      true
      (Sol_cli_string.contains ~needle:"name: sol:operators" doc);
    check_bool
      "referencing the read-only role"
      true
      (Sol_cli_string.contains ~needle:"name: sol-operator-diagnostics" doc);
    check_bool
      "no Secret is written"
      false
      (Sol_cli_string.contains ~needle:"kind: Secret" doc);
    check_bool
      "no workload document is written"
      false
      (Sol_cli_string.contains ~needle:"kind: Deployment" doc))
;;

let rec lookup path (v : Yaml.value) =
  match path, v with
  | [], v -> Some v
  | key :: rest, `O members -> Option.bind (List.assoc_opt key members) (lookup rest)
  | _ -> None
;;

let string_at path v =
  match lookup path v with
  | Some (`String s) -> s
  | _ -> Windtrap.failf "no string at %s" (String.concat "." path)
;;

(* A plain YAML scalar resolves to a number, so a port is compared as its rendered number. *)
let scalar_at path v =
  match lookup path v with
  | Some (`String s) -> s
  | Some (`Float f) -> Printf.sprintf "%g" f
  | Some (`Bool b) -> string_of_bool b
  | _ -> Windtrap.failf "no scalar at %s" (String.concat "." path)
;;

let list_at path v =
  match lookup path v with
  | Some (`A items) -> items
  | _ -> Windtrap.failf "no list at %s" (String.concat "." path)
;;

let parse_document text =
  match Yaml.of_string text with
  | Ok value -> value
  | Error (`Msg message) ->
    Windtrap.failf "rendered YAML does not parse: %s\n%s" message text
;;

(* A fact body as the platform writes it. [port = None] omits the port, which is the
   malformed shape a partial publication can leave behind. *)
let fact ~cidrs ?port () =
  let port_field =
    match port with
    | None -> ""
    | Some port -> Printf.sprintf ",\"database-port\":\"%s\"" port
  in
  Printf.sprintf "{\"data\":{\"database-egress-cidrs\":\"%s\"%s}}" cidrs port_field
;;

let consumer = [ "pluto-checkout", "checkout-svc" ]

let with_fact ~egress_fact ~workloads f =
  with_fake_kubectl ~egress_fact (fun log ->
    let outcome =
      S.ensure
        ~workloads
        ~ctx:Sol_cli_kube_destination.local_context
        ~namespaces:[ "pluto-checkout" ]
    in
    f log outcome)
;;

(* **A consumer cannot deploy without a usable destination fact.** The fact used to be read
   with its errors collapsed to [None], so a refused, absent or malformed ConfigMap looked
   exactly like "no managed database": the deploy proceeded and the workloads had no route.
   Only the units that declared the managed database ask for the fact, so a target with no
   such consumer still deploys with no read and no allowance. *)
let test_ensure_fails_closed_without_a_usable_fact () =
  let expect_refusal ~label ~needle ~egress_fact =
    with_fact ~egress_fact ~workloads:consumer (fun log outcome ->
      match outcome with
      | Ok () -> Windtrap.failf "%s: the substrate must refuse" label
      | Error message ->
        check_bool
          (label ^ ": names the fact")
          true
          (Sol_cli_string.contains ~needle:"sol-platform-network" message);
        check_bool
          (label ^ ": says the workloads would have no route")
          true
          (Sol_cli_string.contains ~needle:"no route" message);
        check_bool
          (label ^ ": applies no allowance")
          false
          (Sys.file_exists (log ^ ".manifests"));
        check_bool
          (label ^ ": preserves the cause")
          true
          (Sol_cli_string.contains ~needle message))
  in
  (* The cause assertions are the specific reason; [no route] is the shared prefix. *)
  let expect_cause ~label ~needle ~egress_fact =
    with_fact ~egress_fact ~workloads:consumer (fun _log outcome ->
      match outcome with
      | Ok () -> Windtrap.failf "%s: the substrate must refuse" label
      | Error message ->
        check_bool
          (label ^ ": preserves the cause")
          true
          (Sol_cli_string.contains ~needle message))
  in
  expect_refusal ~label:"absent fact" ~needle:"no route" ~egress_fact:"absent";
  expect_cause ~label:"forbidden read" ~needle:"Forbidden" ~egress_fact:"forbidden";
  expect_refusal
    ~label:"empty ranges"
    ~needle:"no route"
    ~egress_fact:(fact ~cidrs:"" ~port:"5432" ());
  expect_cause
    ~label:"missing port"
    ~needle:"no database-port"
    ~egress_fact:(fact ~cidrs:"10.12.0.0/16" ());
  expect_cause
    ~label:"invalid port"
    ~needle:"invalid database-port"
    ~egress_fact:(fact ~cidrs:"10.12.0.0/16" ~port:"http" ());
  (* No declared consumer: even a published fact produces no allowance, and an absent one is
     not an error. *)
  with_fact
    ~egress_fact:(fact ~cidrs:"10.12.0.0/16" ~port:"5432" ())
    ~workloads:[]
    (fun log outcome ->
       (match outcome with
        | Ok () -> ()
        | Error message ->
          Windtrap.fail
            ("a plan with no managed-database consumer needs no fact: " ^ message));
       check_bool
         "no consumer means no allowance is applied"
         false
         (Sys.file_exists (log ^ ".manifests")));
  with_fact ~egress_fact:"absent" ~workloads:[] (fun _log outcome ->
    match outcome with
    | Ok () -> ()
    | Error message ->
      Windtrap.fail ("an absent fact is irrelevant without a consumer: " ^ message))
;;

let test_ensure_applies_the_published_allowance () =
  let egress_fact = fact ~cidrs:"10.12.0.0/16,10.13.0.0/16" ~port:"5432" () in
  with_fact ~egress_fact ~workloads:consumer (fun log outcome ->
    (match outcome with
     | Ok () -> ()
     | Error message -> Windtrap.fail message);
    let manifests =
      try read_file (log ^ ".manifests") with
      | Sys_error _ -> Windtrap.fail "the allowance was not applied"
    in
    let policy = parse_document manifests in
    Windtrap.equal
      Windtrap.string
      ~msg:"the allowance names the workload"
      "checkout-svc-managed-database-egress"
      (string_at [ "metadata"; "name" ] policy);
    Windtrap.equal
      Windtrap.string
      ~msg:"the allowance selects the workload's pods, not the namespace"
      "checkout-svc"
      (string_at [ "spec"; "podSelector"; "matchLabels"; "app" ] policy);
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the allowance is egress only"
      [ "Egress" ]
      (list_at [ "spec"; "policyTypes" ] policy |> List.map (string_at []));
    let rules = list_at [ "spec"; "egress" ] policy in
    Windtrap.equal Windtrap.int ~msg:"one egress rule" 1 (List.length rules);
    let rule = List.hd rules in
    let destinations =
      list_at [ "to" ] rule
      |> List.map (fun destination ->
        check_bool
          "a destination is a bare ipBlock, with no widening exception"
          true
          (lookup [ "ipBlock"; "except" ] destination = None);
        string_at [ "ipBlock"; "cidr" ] destination)
    in
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"every published destination, and only those"
      [ "10.12.0.0/16"; "10.13.0.0/16" ]
      destinations;
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the published port, on TCP"
      [ "5432/TCP" ]
      (list_at [ "ports" ] rule
       |> List.map (fun port ->
         scalar_at [ "port" ] port ^ "/" ^ scalar_at [ "protocol" ] port)))
;;

(* The platform policy is additive with the managed-database allowance, so the existing DNS,
   platform-namespace and declared-peer egress must remain exactly as they were. Parsing the
   rendered policy keeps this a contract assertion rather than a substring check. *)
let test_platform_policy_keeps_dns_platform_and_peer_egress () =
  let policy =
    Sol_cli_manifest.network_policy_doc
      ~egress_to:[ "myapp-orders", "order-svc" ]
      ~ingress_from:[ "myapp-orders", "order-svc" ]
      ~ns:"myapp-payments"
      ~name:"charge-svc"
      ()
    |> fun doc -> Sol_cli_yaml.render [ doc ] |> parse_document
  in
  let egress = list_at [ "spec"; "egress" ] policy in
  Windtrap.equal
    Windtrap.int
    ~msg:"DNS, platform namespaces and the declared peer"
    3
    (List.length egress);
  let dns = List.nth egress 0 in
  check_bool
    "the DNS rule is destination-free and names both protocols"
    true
    (lookup [ "to" ] dns = None
     && List.map
          (fun port -> scalar_at [ "port" ] port ^ "/" ^ scalar_at [ "protocol" ] port)
          (list_at [ "ports" ] dns)
        = [ "53/UDP"; "53/TCP" ]);
  let platform = List.nth egress 1 in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the platform rule keeps the three platform namespaces"
    [ "redpanda"; "postgresql"; Sol_cli_manifest.monitoring_namespace ]
    (list_at [ "to" ] platform
     |> List.filter_map (fun destination ->
       match
         lookup
           [ "namespaceSelector"; "matchLabels"; "kubernetes.io/metadata.name" ]
           destination
       with
       | Some (`String name) -> Some name
       | _ -> None));
  let peer = List.hd (list_at [ "to" ] (List.nth egress 2)) in
  Windtrap.equal
    Windtrap.string
    ~msg:"the declared peer keeps its namespace"
    "myapp-orders"
    (string_at [ "namespaceSelector"; "matchLabels"; "kubernetes.io/metadata.name" ] peer);
  Windtrap.equal
    Windtrap.string
    ~msg:"the declared peer keeps its pod selector"
    "order-svc"
    (string_at [ "podSelector"; "matchLabels"; "app" ] peer)
;;

(* **The claim the target-derived database namespace rests on**: `ensure` establishes any
   namespace it is given, together with the deploy identity's scoped RoleBinding -- it does not
   require the `<workspace>-<domain>` shape a workload apply creates. Without this, the database
   operations namespace would be one the deploy identity cannot write into (#1424). *)
let test_a_target_derived_namespace_gets_the_same_substrate () =
  let ns = "sol-db-pluto-qual-2b-a33-aws-us-east-1" in
  let docs = docs_or_fail [ ns ] in
  check_int "namespace + deploy RoleBinding + operator RoleBinding" 3 (List.length docs);
  check_bool
    "the namespace is the target-derived one, not a domain's"
    true
    (Sol_cli_string.contains ~needle:"kind: Namespace" (List.nth docs 0)
     && Sol_cli_string.contains ~needle:ns (List.nth docs 0));
  check_bool
    "and the deploy identity gets its scoped RoleBinding there"
    true
    (Sol_cli_string.contains ~needle:"kind: RoleBinding" (List.nth docs 1)
     && Sol_cli_string.contains ~needle:("namespace: " ^ ns) (List.nth docs 1)
     && Sol_cli_string.contains ~needle:"name: sol-deploy" (List.nth docs 1));
  check_bool
    "and the operator's diagnostic RoleBinding too"
    true
    (Sol_cli_string.contains ~needle:"kind: RoleBinding" (List.nth docs 2)
     && Sol_cli_string.contains ~needle:("namespace: " ^ ns) (List.nth docs 2)
     && Sol_cli_string.contains ~needle:"name: sol-operator-diagnostics" (List.nth docs 2)
    )
;;

let%test "workspace substrate: a target-derived namespace gets the same substrate" =
  test_a_target_derived_namespace_gets_the_same_substrate ()
;;

let%test "workspace substrate: namespace and RoleBindings only" =
  test_substrate_is_namespace_and_role_bindings_only ()
;;

let%test "workspace substrate: every namespace and binding is present" =
  test_every_namespace_and_binding_is_present ()
;;

let%test "workspace substrate: ensure refuses a reserved platform namespace" =
  test_ensure_refuses_a_reserved_platform_namespace ()
;;

let%test
    "workspace substrate: an existing namespace is created, never applied (INFRA-048)"
  =
  test_namespace_is_created_not_applied ()
;;

let%test
    "operator diagnostic bindings (INFRA-058): every workload namespace is covered, RBAC \
     only"
  =
  test_operator_bindings_cover_every_workload_namespace ()
;;

let%test
    "workspace substrate (FND-0075): a managed-database consumer with no usable egress \
     fact fails closed; no consumer reads no fact"
  =
  test_ensure_fails_closed_without_a_usable_fact ()
;;

let%test
    "workspace substrate (FND-0075): the published destinations and port are applied as \
     one bounded ipBlock rule"
  =
  test_ensure_applies_the_published_allowance ()
;;

let%test
    "workspace substrate (FND-0075): DNS, platform-namespace and declared-peer egress \
     are unchanged"
  =
  test_platform_policy_keeps_dns_platform_and_peer_egress ()
;;
