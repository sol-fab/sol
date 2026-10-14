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
     && Sol_cli_string.contains ~needle:"name: sol:deployers" (List.nth docs 1));
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
      [ "kind: Deployment"
      ; "kind: Service"
      ; "kind: PodDisruptionBudget"
      ; "kind: Ingress"
      ; "kind: Secret"
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
      ~manages_database:false
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
      present)
        echo '{"data":{"database-egress-cidrs":"10.0.0.0/16","database-port":"5432"}}'
        exit 0 ;;
      forbidden)
        echo 'Error from server (Forbidden): configmaps "sol-platform-network" is forbidden: cannot get resource "configmaps"' >&2
        exit 1 ;;
      *)
        echo 'Error from server (NotFound): configmaps "sol-platform-network" not found' >&2
        exit 1 ;;
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

(* The database-egress fact. It used to be read with its errors collapsed to [None], so a
   refused or absent ConfigMap looked exactly like "this target has no managed database":
   the deploy proceeded and the workloads had no route to it. The two are now distinguished
   by the target's ownership. *)
let test_ensure_distinguishes_no_database_from_a_broken_fact () =
  let run ~egress_fact ~manages_database =
    with_fake_kubectl ~egress_fact (fun _log ->
      S.ensure
        ~workloads:[ "pluto-checkout", "checkout-svc" ]
        ~ctx:Sol_cli_kube_destination.local_context
        ~namespaces:[ "pluto-checkout" ]
        ~manages_database)
  in
  (match run ~egress_fact:"absent" ~manages_database:true with
   | Ok () ->
     Windtrap.fail
       "a managed database with no published egress fact must refuse the substrate"
   | Error message ->
     check_bool
       "the refusal names the fact"
       true
       (Sol_cli_string.contains ~needle:"sol-platform-network" message);
     check_bool
       "the refusal says the workloads would have no route"
       true
       (Sol_cli_string.contains ~needle:"no route" message));
  (match run ~egress_fact:"forbidden" ~manages_database:true with
   | Ok () -> Windtrap.fail "a refused fact read must not pass as no database"
   | Error message ->
     check_bool
       "the read error is preserved"
       true
       (Sol_cli_string.contains ~needle:"Forbidden" message));
  match run ~egress_fact:"absent" ~manages_database:false with
  | Ok () -> ()
  | Error message ->
    Windtrap.fail ("a target with no managed database needs no egress fact: " ^ message)
;;

let test_ensure_applies_the_published_allowance () =
  with_fake_kubectl ~egress_fact:"present" (fun log ->
    (match
       S.ensure
         ~workloads:[ "pluto-checkout", "checkout-svc" ]
         ~ctx:Sol_cli_kube_destination.local_context
         ~namespaces:[ "pluto-checkout" ]
         ~manages_database:true
     with
     | Ok () -> ()
     | Error message -> Windtrap.fail message);
    let manifests =
      try read_file (log ^ ".manifests") with
      | Sys_error _ -> Windtrap.fail "the allowance was not applied"
    in
    check_bool
      "the published range is admitted as an ipBlock"
      true
      (Sol_cli_string.contains ~needle:"ipBlock" manifests
       && Sol_cli_string.contains ~needle:"10.0.0.0/16" manifests);
    check_bool
      "on the published port"
      true
      (Sol_cli_string.contains ~needle:"port: 5432" manifests))
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
    "workspace substrate (FND-0075): a managed database with no egress fact fails \
     closed, a target without one does not"
  =
  test_ensure_distinguishes_no_database_from_a_broken_fact ()
;;

let%test
    "workspace substrate (FND-0075): the published egress range is applied as an ipBlock"
  =
  test_ensure_applies_the_published_allowance ()
;;
