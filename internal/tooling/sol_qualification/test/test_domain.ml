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

let kubernetes : Qual_domain.kube_target =
  { principal = "fixture-reader"
  ; cluster = "fixture-cluster"
  ; endpoint = "https://fixture.invalid"
  }
;;

(* Synthetic facts for domain/recorder mechanics, not observer agreement fixtures. *)
let synthetic_ca run instance workload : Qual_domain.ca_facts =
  let open Qual_domain in
  let context =
    { target = kubernetes
    ; verified_at = 0
    ; started_at = 1
    ; finished_at = 2
    ; expires_at = Some 300
    }
  in
  let wrap state =
    { requirement = instance_identity instance
    ; subject =
        (match String.split_on_char '/' (instance_key instance) |> List.rev with
         | x :: _ -> x
         | [] -> assert false)
    ; context
    ; state = Present state
    }
  in
  ignore run;
  { deployment =
      wrap
        { namespace = "apps"
        ; name = workload
        ; uid = "deployment-uid"
        ; resource_version = "1"
        ; volumes =
            [ { volume_name = "ca-volume"
              ; source_configmap = Some "declared-ledger-ca"
              ; items = None
              }
            ]
        ; containers =
            [ { container_name = "app"
              ; mounts =
                  [ { volume_name = "ca-volume"
                    ; path = "/etc/sol/db-ca"
                    ; sub_path = None
                    ; sub_path_expr = None
                    }
                  ]
              }
            ]
        }
  ; configmap =
      wrap
        { namespace = "apps"
        ; name = "declared-ledger-ca"
        ; uid = "configmap-uid"
        ; resource_version = "2"
        ; entries = [ "ca.pem", true ]
        }
  }
;;

(* Mechanism-only happy facts; hostile Job fixtures exercise the real decoder separately. *)
let synthetic_migration run instance =
  let open Qual_domain in
  let ca = synthetic_ca run instance "execution-job" in
  let template =
    match ca.deployment.state with
    | Present x -> x
    | _ -> assert false
  in
  let namespace = "database-system" in
  let job =
    { template with
      namespace
    ; containers =
        List.map (fun c -> { c with container_name = "migrate" }) template.containers
    }
  in
  let configmap =
    match ca.configmap.state with
    | Present x -> x
    | _ -> assert false
  in
  { execution =
      { requirement = instance_identity instance
      ; subject = "ledger"
      ; context = { ca.deployment.context with started_at = 0; finished_at = 0 }
      ; state = Present { namespace; name = job.name; uid = job.uid }
      }
  ; job = { ca.deployment with state = Present job }
  ; configmap = { ca.configmap with state = Present { configmap with namespace } }
  }
;;

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
    ~kubernetes
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
    evaluate (Ca_checked (r, observed run i (Present (synthetic_ca run i workload))))
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
  | Migration_ca_delivery r ->
    evaluate
      (Migration_ca_checked (r, observed run i (Present (synthetic_migration run i))))
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
    [ Ca; Dml; No_master; Tls; Migration; Migration_ca ];
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
           (fun (k, v) ->
              ( k
              , if k = field
                then if field = "database" && v = `Null then `Null else value
                else change field value v ))
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
    ; change "container" (`String "another-container") (intent_json ())
    ; change "configmap" (`String "another-migration-ca") (intent_json ())
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
                    ; ( "migration"
                      , `Assoc
                          [ "namespace", `String "database-system"
                          ; "container", `String "migrate"
                          ; "configmap", `String "declared-ledger-ca"
                          ] )
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
  (* Migration-context changes must also reject its own same-key typed request. *)
  List.iter
    (fun field ->
       let altered_intent =
         change field (`String "another-migration-value") (intent_json ())
       in
       let altered =
         bind_obligations
           run
           Aws
           (select run (Fixture.intent altered_intent |> get) |> get)
         |> get
       in
       let migration =
         List.find (fun i -> instance_kind i = Migration_ca) (instances altered)
       in
       let mutated =
         List.map
           (fun request ->
              if instance_kind (requested request) = Migration_ca
              then plan migration
              else request)
           requests
       in
       rejects (reconcile_plan expected mutated))
    [ "namespace"; "container"; "configmap" ];
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
  let ca_facts = synthetic_ca run i "w1" in
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
  let wrong =
    observed
      run
      i
      (Present
         { ca_facts with
           deployment =
             { ca_facts.deployment with
               state =
                 Present
                   { (match ca_facts.deployment.state with
                      | Present d -> d
                      | _ -> assert false)
                     with
                     namespace = "other"
                   }
             }
         })
  in
  (evaluate (Ca_checked (r, wrong))).decision |> is_unknown;
  List.iter
    (fun facts ->
       (evaluate (Ca_checked (r, observed run i (Present facts)))).decision |> is_fail)
    (let configmap =
       match ca_facts.configmap.state with
       | Present c -> c
       | _ -> assert false
     in
     let deployment =
       match ca_facts.deployment.state with
       | Present d -> d
       | _ -> assert false
     in
     [ { ca_facts with
         configmap =
           { ca_facts.configmap with
             state = Present { configmap with entries = [ "ca.crt", true ] }
           }
       }
     ; { ca_facts with
         configmap =
           { ca_facts.configmap with
             state = Present { configmap with entries = [ "ca.pem", false ] }
           }
       }
     ; { ca_facts with
         deployment =
           { ca_facts.deployment with
             state =
               Present
                 { deployment with
                   volumes =
                     [ { volume_name = "ca-volume"
                       ; source_configmap = Some "other"
                       ; items = None
                       }
                     ]
                 }
           }
       }
     ; { ca_facts with
         deployment =
           { ca_facts.deployment with
             state =
               Present
                 { deployment with
                   containers = [ { container_name = "app"; mounts = [] } ]
                 }
           }
       }
     ]);
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
