open Qual_domain

let get = function
  | Ok x -> x
  | Error e -> Alcotest.fail e
;;

let rejects = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "mutation was accepted"
;;

let reference = sha256 "explicit offline fixture evidence"

let contract =
  `Assoc
    [ "schema", `Int 1
    ; "ca_key", `String "ca.pem"
    ; "ca_path", `String "/etc/sol/db-ca/ca.pem"
    ; "credential_key", `String "POSTGRES_URL"
    ; "dml_class", `String "dml"
    ; "capabilities", `List (List.map (fun s -> `String s) [ "ca"; "dml"; "tls" ])
    ]
;;

let bind
      ?(scenario = Aws)
      ?(assessment = "a1")
      ?(candidate = String.make 40 'a')
      ?(specimen = "cluster-1")
      ?(contract = contract)
      ()
  =
  Fixture.bind
    ~scenario
    ~attempt:"fixture-1"
    ~assessment
    ~candidate_revision:candidate
    ~specimen
    ~contract
  |> get
;;

let intent_json () = Yojson.Safe.from_file "intent.json"

let setup ?(scenario = Aws) ?(contract = contract) () =
  let run = bind ~scenario ~contract () in
  let intent = Fixture.intent (intent_json ()) |> get in
  let selection = select run intent |> get in
  run, selection, bind_obligations run scenario selection |> get
;;

let golden name =
  In_channel.with_open_text name (fun ch -> In_channel.input_all ch)
  |> String.split_on_char '\n'
  |> List.filter (fun s -> s <> "")
;;

let keys o = List.map instance_key (instances o)
let subject i = List.rev (String.split_on_char '/' (instance_key i)) |> List.hd

let observed run i state =
  Fixture.observe run ~subject:(subject i) ~evidence:[ reference ] state |> get
;;

let verdict run request =
  let i = requested request in
  let workload = subject i in
  match request with
  | Ca_delivery r ->
    evaluate
      (Ca_checked
         ( r
         , observed
             run
             i
             (Present
                { namespace = "apps"
                ; workload
                ; configmap = "declared-ledger-ca"
                ; key = "ca.pem"
                ; mount_path = "/etc/sol/db-ca/ca.pem"
                ; nonempty = true
                }) ))
  | Dml_delivery r ->
    evaluate
      (Dml_checked
         ( r
         , observed
             run
             i
             (Present
                { namespace = "apps"
                ; workload
                ; credential_class = "dml"
                ; key = "POSTGRES_URL"
                ; nonempty = true
                }) ))
  | No_master_copy r ->
    evaluate
      (No_master_checked
         ( r
         , observed
             run
             i
             (Present
                { namespace = "apps"
                ; workload
                ; references = [ { namespace = "apps"; name = "ledger-dml" } ]
                }) ))
  | Tls_connectivity r ->
    evaluate
      (Tls_checked
         (r, observed run i (Present { namespace = "apps"; workload; verified = true })))
  | Migration_input r ->
    evaluate
      (Migration_checked
         ( r
         , observed
             run
             i
             (Present { database = "ledger"; key = "POSTGRES_URL"; nonempty = true }) ))
;;

let ca_request o =
  List.find_map
    (fun i ->
       match plan i with
       | Ca_delivery r -> Some (i, r)
       | _ -> None)
    (instances o)
  |> Option.get
;;

let ca_facts : ca_facts =
  { namespace = "apps"
  ; workload = "w1"
  ; configmap = "declared-ledger-ca"
  ; key = "ca.pem"
  ; mount_path = "/etc/sol/db-ca/ca.pem"
  ; nonempty = true
  }
;;

let is_unknown = function
  | Unknown _ -> ()
  | _ -> Alcotest.fail "expected UNKNOWN"
;;

let is_fail = function
  | Fail _ -> ()
  | _ -> Alcotest.fail "expected FAIL"
;;

let test_golden () =
  let run, selection, o = setup () in
  Alcotest.(check int) "all consumers" 5 (List.length (consumers selection));
  Alcotest.(check int) "excluded nonconsumer" 1 (List.length (exclusions selection));
  reconcile_keys ~expected:(golden "aws.golden") ~actual:(keys o) |> get;
  let requests = List.map plan (instances o) in
  accept_mechanism o requests (List.map (verdict run) requests) |> get;
  let _, _, local = setup ~scenario:Local () in
  reconcile_keys ~expected:(golden "local.golden") ~actual:(keys local) |> get;
  Alcotest.(check int)
    "explicit local TLS exclusions plus nonconsumer"
    6
    (List.length (applicability local));
  let _, _, gcp = setup ~scenario:Gcp () in
  let expected =
    List.map
      (fun key -> "gcp" ^ String.sub key 3 (String.length key - 3))
      (golden "aws.golden")
  in
  reconcile_keys ~expected ~actual:(keys gcp) |> get
;;

let test_planner_mutations () =
  let _, _, o = setup () in
  let requests = List.map plan (instances o) in
  List.iter
    (fun kind ->
       let dropped = ref false in
       let mutated =
         List.filter
           (fun r ->
              if (not !dropped) && instance_kind (requested r) = kind
              then (
                dropped := true;
                false)
              else true)
           requests
       in
       rejects (reconcile_plan o mutated))
    [ Ca; Dml; No_master; Tls; Migration ];
  rejects
    (reconcile_plan
       o
       (List.filter (fun r -> instance_kind (requested r) <> Tls) requests));
  rejects (reconcile_plan o (List.hd requests :: requests));
  let foreign_run = bind ~assessment:"a2" () in
  let foreign =
    bind_obligations
      foreign_run
      Aws
      (select foreign_run (Fixture.intent (intent_json ()) |> get) |> get)
    |> get
  in
  rejects (reconcile_plan o (plan (List.hd (instances foreign)) :: List.tl requests))
;;

let test_request_semantics () =
  let _, _, expected = setup () in
  let requests = List.map plan (instances expected) in
  let run = bind () in
  let rec change field value = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (k, v) -> k, if k = field then value else change field value v)
           fields)
    | `List xs -> `List (List.map (change field value) xs)
    | v -> v
  in
  let altered_intents =
    [ change "namespace" (`String "another-namespace") (intent_json ())
    ; (match intent_json () with
       | `Assoc fields ->
         `Assoc
           (List.map
              (function
                | "workloads", `List (w :: ws) ->
                  "workloads", `List (change "name" (`String "another-workload") w :: ws)
                | pair -> pair)
              fields)
       | _ -> assert false)
    ; change "ca_configmap" (`String "another-ca") (intent_json ())
    ; change
        "administrative_secret"
        (`Assoc [ "namespace", `String "system"; "name", `String "other-admin" ])
        (intent_json ())
    ; (match intent_json () with
       | `Assoc fields ->
         `Assoc
           (( "databases"
            , `List
                [ `Assoc
                    [ "id", `String "other-db"
                    ; "ca_configmap", `String "declared-ledger-ca"
                    ; ( "administrative_secret"
                      , `Assoc
                          [ "namespace", `String "database-system"
                          ; "name", `String "ledger-admin"
                          ] )
                    ]
                ] )
            :: List.remove_assoc
                 "databases"
                 (match change "database" (`String "other-db") (`Assoc fields) with
                  | `Assoc xs -> xs
                  | _ -> assert false))
       | _ -> assert false)
    ]
  in
  List.iter
    (fun json ->
       let altered =
         bind_obligations run Aws (select run (Fixture.intent json |> get) |> get) |> get
       in
       (* The consumer CA key is unchanged, while its namespace/name/database binding is wrong. *)
       let forged =
         List.find
           (fun i -> instance_key i = instance_key (requested (List.hd requests)))
           (instances altered)
       in
       rejects (reconcile_plan expected (plan forged :: List.tl requests)))
    altered_intents;
  let altered_contract = change "ca_key" (`String "other.pem") contract in
  let foreign = bind ~contract:altered_contract () in
  let altered =
    bind_obligations
      foreign
      Aws
      (select foreign (Fixture.intent (intent_json ()) |> get) |> get)
    |> get
  in
  rejects
    (reconcile_plan expected (plan (List.hd (instances altered)) :: List.tl requests))
;;

let test_administrative_binding () =
  let run, _, obligations = setup () in
  let i, r =
    List.find_map
      (fun i ->
         match plan i with
         | No_master_copy r -> Some (i, r)
         | _ -> None)
      (instances obligations)
    |> Option.get
  in
  let check references =
    evaluate
      (No_master_checked
         (r, observed run i (Present { namespace = "apps"; workload = "w1"; references })))
  in
  (* A DML Secret may contain POSTGRES_URL/password; keys are deliberately not facts. *)
  Alcotest.(check bool)
    "ordinary DML binding permitted"
    true
    ((check [ { namespace = "apps"; name = "ledger-dml" } ]).decision = Pass);
  (check [ { namespace = "database-system"; name = "ledger-admin" } ]).decision |> is_fail;
  (evaluate
     (No_master_checked
        (r, observed run i (Unreadable "source of copied secret cannot be established"))))
    .decision
  |> is_unknown
;;

let test_catalog_oracle () =
  let _, _, o = setup () in
  let expected = golden "aws.golden" in
  (* This reviewed file is not derived from the production catalog. Removing a
     rule in per_consumer must make test_golden fail, even if planning follows it. *)
  List.iter
    (fun removed ->
       rejects (reconcile_keys ~expected ~actual:(List.filter (( <> ) removed) (keys o))))
    expected;
  let _, _, local = setup ~scenario:Local () in
  rejects
    (reconcile_keys
       ~expected:(golden "local.golden")
       ~actual:("local/a1/database/tls/w1" :: keys local));
  let json = intent_json () in
  let mutated =
    match json with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "workloads", `List (_ :: xs) -> "workloads", `List xs
             | pair -> pair)
           fields)
    | _ -> assert false
  in
  let run = bind () in
  let selected = select run (Fixture.intent mutated |> get) |> get in
  let smaller = bind_obligations run Aws selected |> get in
  rejects (reconcile_keys ~expected ~actual:(keys smaller))
;;

let test_receipt_matching () =
  let run, _, o = setup () in
  let i, r = ca_request o in
  List.iter
    (fun foreign ->
       let observation = observed foreign i (Present ca_facts) in
       (evaluate (Ca_checked (r, observation))).decision |> is_unknown)
    [ bind ~candidate:(String.make 40 'b') ()
    ; bind ~specimen:"other" ()
    ; bind ~assessment:"a2" ()
    ; bind ~scenario:Gcp ()
    ];
  let wrong =
    Fixture.observe run ~subject:"w2" ~evidence:[ reference ] (Present ca_facts) |> get
  in
  (evaluate (Ca_checked (r, wrong))).decision |> is_unknown;
  let wrong = observed run i (Present { ca_facts with namespace = "other" }) in
  (evaluate (Ca_checked (r, wrong))).decision |> is_unknown;
  List.iter
    (fun facts ->
       (evaluate (Ca_checked (r, observed run i (Present facts)))).decision |> is_fail)
    [ { ca_facts with key = "ca.crt" }
    ; { ca_facts with nonempty = false }
    ; { ca_facts with configmap = "other" }
    ; { ca_facts with mount_path = "/elsewhere" }
    ];
  (evaluate (Ca_checked (r, observed run i Absent))).decision |> is_fail;
  (evaluate (Ca_checked (r, observed run i (Unreadable "Forbidden")))).decision
  |> is_unknown;
  rejects (Fixture.observe run ~subject:"w1" ~evidence:[] (Present ca_facts))
;;

let test_capability_cannot_exclude () =
  let no_tls =
    match contract with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "capabilities", _ -> "capabilities", `List [ `String "ca"; `String "dml" ]
             | x -> x)
           fields)
    | _ -> assert false
  in
  let run, _, o = setup ~contract:no_tls () in
  reconcile_keys ~expected:(golden "aws.golden") ~actual:(keys o) |> get;
  let requests = List.map plan (instances o) in
  rejects (accept_mechanism o requests (List.map (verdict run) requests))
;;

let test_outcomes () =
  let run, _, o = setup () in
  let requests = List.map plan (instances o) in
  let outcomes = List.map (verdict run) requests in
  rejects (reconcile_outcomes o (List.tl outcomes));
  rejects (reconcile_outcomes o (List.hd outcomes :: outcomes));
  let blocker =
    Fixture.blocked (List.hd (instances o)) ~evidence:[ reference ] "identity unreadable"
    |> get
  in
  rejects (accept_mechanism o requests (blocker :: List.tl outcomes))
;;

let test_ownership () =
  let claims = [ "db.ca"; "db.dml"; "lifecycle.destroy" ] in
  let owners =
    [ "db.ca", Typed_family "database"
    ; "db.dml", Typed_family "database"
    ; "lifecycle.destroy", Legacy_matrix "aws-matrix"
    ]
  in
  check_ownership ~claims ~assignments:owners |> get;
  rejects (check_ownership ~claims ~assignments:(List.tl owners));
  rejects
    (check_ownership ~claims ~assignments:(("db.ca", Legacy_matrix "old-ca") :: owners));
  rejects
    (check_ownership
       ~claims
       ~assignments:(("unknown", Typed_family "database") :: owners))
;;

let test_decoding () =
  let empty =
    Fixture.intent (`Assoc [ "databases", `List []; "workloads", `List [] ]) |> get
  in
  rejects (select (bind ()) empty);
  rejects (canonical_json (`Assoc [ "x", `Int 1; "x", `Int 2 ]));
  let reversed =
    match contract with
    | `Assoc fields -> `Assoc (List.rev fields)
    | _ -> assert false
  in
  Alcotest.(check bool)
    "canonical contract identity"
    true
    (same_run (bind ()) (bind ~contract:reversed ()))
;;

let () =
  Alcotest.run
    "qualification domain"
    [ ( "adversarial"
      , List.map
          (fun (name, test) -> Alcotest.test_case name `Quick test)
          [ "reviewed golden universes", test_golden
          ; "planner omissions and duplicates", test_planner_mutations
          ; "same-key request semantics", test_request_semantics
          ; "administrative binding identity", test_administrative_binding
          ; "independent catalog and consumer oracle", test_catalog_oracle
          ; "semantic receipt matching", test_receipt_matching
          ; "capability cannot exclude policy", test_capability_cannot_exclude
          ; "complete outcomes", test_outcomes
          ; "claim-family ownership", test_ownership
          ; "decoding", test_decoding
          ] )
    ]
;;
