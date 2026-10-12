open Sol_cli_substrate_contract

let observed_cluster = { cluster = `Reachable; registry = None; base_domain = None }

let verdict_of input observations =
  match List.assoc_opt input (evaluate observations) with
  | Some verdict -> verdict
  | None -> Windtrap.failf "the contract has no verdict for %s" (name input)
;;

let check_verdict label expected actual =
  Windtrap.equal
    Windtrap.string
    ~msg:label
    expected
    (Sol_cli_installation.verdict_label actual)
;;

let test_every_input_is_answered_once () =
  let verdicts = evaluate observed_cluster in
  List.iter
    (fun input ->
       Windtrap.equal
         Windtrap.int
         ~msg:(Printf.sprintf "one verdict for %s" (name input))
         1
         (List.length (List.filter (fun (i, _) -> i = input) verdicts));
       Windtrap.equal
         Windtrap.bool
         ~msg:(Printf.sprintf "%s has a statement" (name input))
         true
         (String.trim (statement input) <> ""))
    all;
  Windtrap.equal
    Windtrap.int
    ~msg:"a verdict for every input"
    (List.length all)
    (List.length verdicts)
;;

let test_a_cluster_that_cannot_be_looked_at_is_unknown () =
  check_verdict "reachable" "Established" (verdict_of Cluster observed_cluster);
  check_verdict
    "unreachable names the reason"
    "Unmet: no such host"
    (verdict_of Cluster { observed_cluster with cluster = `Unmet "no such host" });
  check_verdict
    "unobservable is UNKNOWN, never satisfied"
    "UNKNOWN: kubectl is not installed"
    (verdict_of
       Cluster
       { observed_cluster with cluster = `Unknown "kubectl is not installed" })
;;

(* 2b: the database connection is no longer a substrate prerequisite an operator supplies
   as an environment variable. The deploy delivers it from the target's binding, so this
   surface reports it as unobservable rather than reading a copy that no longer exists. *)
let test_a_database_the_deploy_delivers_is_unobservable () =
  check_verdict
    "the database connection is unknown here, never Established or Unmet"
    "UNKNOWN: the database connection is delivered by the deploy from the target's \
     binding; this check reads the target surface, not whether the selected database \
     accepts it"
    (verdict_of Postgres observed_cluster)
;;

let test_unobservable_inputs_are_never_satisfied () =
  List.iter
    (fun input ->
       match verdict_of input observed_cluster with
       | Established ->
         Windtrap.failf
           "%s is reported satisfied from the target surface, which cannot observe it"
           (name input)
       | Unmet _ | Unknown _ -> ())
    [ Registry; Kafka; Postgres; Observability; Domain ]
;;

let test_an_unresolved_input_is_named () =
  let unresolved = unmet_or_unknown (evaluate observed_cluster) in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"only the cluster is established here"
    [ "container registry"
    ; "kafka and schema registry"
    ; "postgres connection"
    ; "observability endpoints"
    ; "base domain and tls"
    ]
    (List.map (fun (input, _) -> name input) unresolved);
  Windtrap.equal
    Windtrap.int
    ~msg:"and the unresolved count matches"
    5
    (List.length unresolved)
;;

let test_a_registry_prefix_is_named_in_its_verdict () =
  match verdict_of Registry { observed_cluster with registry = Some "ghcr.io/acme" } with
  | Unknown reason ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"names the prefix"
      true
      (Sol_cli_string.contains ~needle:"ghcr.io/acme" reason)
  | Established -> Windtrap.fail "a prefix Sol cannot verify is not Established"
  | Unmet reason -> Windtrap.failf "a configured prefix is not Unmet: %s" reason
;;

let%test "the contract (DEC-052): every input is answered once" =
  test_every_input_is_answered_once ()
;;

let%test "the contract (DEC-052): a cluster that cannot be looked at is UNKNOWN" =
  test_a_cluster_that_cannot_be_looked_at_is_unknown ()
;;

let%test "2b: the database connection the deploy delivers is UNKNOWN here" =
  test_a_database_the_deploy_delivers_is_unobservable ()
;;

let%test "the contract (DEC-052): unobservable inputs are never satisfied" =
  test_unobservable_inputs_are_never_satisfied ()
;;

let%test "the contract (DEC-052): an unresolved input is named" =
  test_an_unresolved_input_is_named ()
;;

let%test "the contract (DEC-052): a registry prefix is named in its verdict" =
  test_a_registry_prefix_is_named_in_its_verdict ()
;;
