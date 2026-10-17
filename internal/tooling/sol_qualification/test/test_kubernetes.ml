module D = Qual_domain
module E = Qual_evidence
module K = Qual_kubernetes
module C = Qual_database_ca

let get = function
  | Ok x -> x
  | Error e -> Alcotest.fail e
;;

let stored = function
  | Ok x -> x
  | Error (e : E.error) -> Alcotest.fail (e.stage ^ ": " ^ e.diagnostic)
;;

let rejects = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unsafe result accepted"
;;

let json name = Yojson.Safe.from_file ("kubernetes/" ^ name)
let field name = Yojson.Safe.Util.member name
let string json = Yojson.Safe.Util.to_string json
let list json = Yojson.Safe.Util.to_list json

let set name value json =
  match json with
  | `Assoc xs -> `Assoc ((name, value) :: List.remove_assoc name xs)
  | _ -> Alcotest.fail "test expected object"
;;

let rec at path fn json =
  match path with
  | [] -> fn json
  | key :: rest -> set key (at rest fn (field key json)) json
;;

let items fn = at [ "items" ] (fun value -> `List (List.map fn (list value)))
let spec fn = at [ "spec"; "template"; "spec" ] fn
let containers fn = spec (at [ "containers" ] (fun xs -> `List (List.map fn (list xs))))
let app fn = containers (fun c -> if field "name" c = `String "app" then fn c else c)
let mounts fn = app (at [ "volumeMounts" ] fn)
let volumes fn = spec (at [ "volumes" ] fn)

let target provider : D.kube_target =
  { principal = provider ^ ":qual-reader"
  ; cluster = provider ^ "-fixture"
  ; endpoint = "https://" ^ provider ^ ".invalid"
  }
;;

let context provider : D.read_context =
  let value = json (provider ^ "-context.json") in
  let t = field "target" value in
  { target =
      { principal = string (field "principal" t)
      ; cluster = string (field "cluster" t)
      ; endpoint = string (field "endpoint" t)
      }
  ; verified_at = Yojson.Safe.Util.to_int (field "verified_at" value)
  ; started_at = Yojson.Safe.Util.to_int (field "started_at" value)
  ; finished_at = Yojson.Safe.Util.to_int (field "finished_at" value)
  ; expires_at = Some (Yojson.Safe.Util.to_int (field "expires_at" value))
  }
;;

let setup
      ?(provider = "aws")
      ?(intent = Yojson.Safe.from_file "intent.json")
      ?(contract = json "contract.json")
      ()
  =
  let scenario = if provider = "aws" then D.Aws else D.Gcp in
  let run =
    D.Fixture.bind
      ~scenario
      ~attempt:"i3-fixture"
      ~assessment:"a1"
      ~candidate_revision:(String.make 40 'a')
      ~specimen:(provider ^ "-fixture")
      ~kubernetes:(target provider)
      ~contract
    |> get
  in
  let selection = D.select run (D.Fixture.intent intent |> get) |> get in
  run, D.bind_obligations run scenario selection |> get
;;

let from_fixture provider fixture (q : K.query) =
  let selected =
    list (field "items" fixture)
    |> List.filter (fun obj ->
      field "name" (field "metadata" obj) = `String q.name
      && field "namespace" (field "metadata" obj) = `String q.namespace)
  in
  K.
    { context = context provider
    ; result =
        Exited
          { code = 0
          ; stdout = Yojson.Safe.to_string (set "items" (`List selected) fixture)
          ; stderr = ""
          }
    }
;;

let baseline provider (q : K.query) =
  from_fixture
    provider
    (json
       (match q.resource with
        | K.Job -> Alcotest.fail "application observer unexpectedly requested Job"
        | K.Deployment -> "deployments.json"
        | K.Configmap -> "configmaps.json"))
    q
;;

let modify_stdout fn (reply : K.reply) =
  match reply.result with
  | K.Exited output ->
    { reply with
      result =
        K.Exited
          { output with
            stdout = Yojson.Safe.to_string (fn (Yojson.Safe.from_string output.stdout))
          }
    }
  | _ -> Alcotest.fail "expected exited fixture"
;;

let mutate resource fn read q =
  let reply = read q in
  if q.K.resource = resource then modify_stdout fn reply else reply
;;

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let temporary fn =
  let directory = Filename.temp_file "sol-qual-i3-" ".test" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> remove directory)
    (fun () -> fn (Filename.concat directory "evidence"))
;;

let open_store ?(secrets = []) ?fault directory run =
  let recorder = E.open_store ?fault ~directory ~run ~secrets () |> stored in
  ignore
    (E.start_assessment
       recorder
       ~reason:"I3 offline CA"
       ~previous:[]
       ~required_captures:[]
     |> stored);
  recorder
;;

let run_read ?(provider = "aws") ?intent ?contract ?(secrets = []) read fn =
  temporary (fun directory ->
    let run, obligations = setup ~provider ?intent ?contract () in
    let recorder = open_store ~secrets directory run in
    Fun.protect
      ~finally:(fun () -> E.close recorder)
      (fun () ->
         let outcomes =
           C.observe_all ~directory ~run ~obligations ~recorder ~read |> get
         in
         fn directory run obligations recorder outcomes))
;;

let recorded (o : C.outcome) = o.result |> stored

let decision kind verdict =
  match kind, verdict.D.decision with
  | "PASS", D.Pass | "FAIL", D.Fail _ | "UNKNOWN", D.Unknown _ -> ()
  | _ ->
    Alcotest.fail
      ("expected " ^ kind ^ ", got " ^ Yojson.Safe.to_string (D.verdict_json verdict))
;;

let all kind outcomes = List.iter (fun o -> decision kind (recorded o).verdict) outcomes

let test_shared () =
  List.iter
    (fun provider ->
       let calls = ref [] in
       let read q =
         calls := (q.K.resource, q.namespace, q.name) :: !calls;
         baseline provider q
       in
       run_read ~provider read (fun _ _ _ _ outcomes ->
         Alcotest.(check int) "every expected CA consumer" 5 (List.length outcomes);
         Alcotest.(check int) "two independent reads per consumer" 10 (List.length !calls);
         List.iter
           (fun name ->
              Alcotest.(check bool)
                "declared workload query"
                true
                (List.mem (K.Deployment, "apps", name) !calls))
           [ "w1"; "w2"; "w3"; "w4"; "w5" ];
         all "PASS" outcomes))
    [ "aws"; "gcp" ]
;;

let test_namespaces_and_objects () =
  let intent =
    at
      [ "workloads" ]
      (fun xs ->
         `List
           (List.map
              (fun w ->
                 if field "id" w = `String "w2"
                 then set "namespace" (`String "payments") w
                 else w)
              (list xs)))
      (Yojson.Safe.from_file "intent.json")
  in
  let deployments =
    items
      (fun d ->
         if field "name" (field "metadata" d) = `String "w2"
         then at [ "metadata" ] (set "namespace" (`String "payments")) d
         else d)
      (json "deployments.json")
  in
  let configmaps =
    at
      [ "items" ]
      (fun xs ->
         let existing = list xs in
         `List
           (existing
            @ [ at
                  [ "metadata" ]
                  (fun metadata ->
                     metadata
                     |> set "namespace" (`String "payments")
                     |> set "uid" (`String "payments-ca"))
                  (List.hd existing)
              ]))
      (json "configmaps.json")
  in
  let read (q : K.query) =
    from_fixture
      "aws"
      (match q.resource with
       | K.Job -> Alcotest.fail "application observer unexpectedly requested Job"
       | K.Deployment -> deployments
       | K.Configmap -> configmaps)
      q
  in
  run_read ~intent read (fun _ _ _ _ -> all "PASS");
  let direct q =
    modify_stdout (fun value -> List.hd (list (field "items" value))) (baseline "aws" q)
  in
  run_read direct (fun _ _ _ _ -> all "PASS")
;;

let test_mounts () =
  let cases =
    [ "missing volume", volumes (fun _ -> `List [])
    ; ( "wrong ConfigMap source"
      , volumes (fun xs ->
          `List
            (List.map (set "configMap" (`Assoc [ "name", `String "other-ca" ])) (list xs)))
      )
    ; ( "mount redirected"
      , mounts (fun xs ->
          `List (List.map (set "mountPath" (`String "/elsewhere")) (list xs))) )
    ; ( "CA only in sidecar"
      , spec
          (at [ "containers" ] (fun xs ->
             `List
               (List.map
                  (fun c ->
                     if field "name" c = `String "app"
                     then set "name" (`String "sidecar") c
                     else c)
                  (list xs)))) )
    ; "missing app mount", app (set "volumeMounts" (`List []))
    ; ( "dangling mount"
      , mounts (fun xs ->
          `List (List.map (set "name" (`String "missing-volume")) (list xs))) )
    ; ( "wrong subPath"
      , mounts (fun xs ->
          `List (List.map (set "subPath" (`String "different.pem")) (list xs))) )
    ; ( "key omitted from items"
      , volumes (fun xs ->
          `List
            (List.map
               (set
                  "configMap"
                  (`Assoc [ "name", `String "declared-ledger-ca"; "items", `List [] ]))
               (list xs))) )
    ; ( "key renamed in items"
      , volumes (fun xs ->
          `List
            (List.map
               (set
                  "configMap"
                  (`Assoc
                      [ "name", `String "declared-ledger-ca"
                      ; ( "items"
                        , `List
                            [ `Assoc
                                [ "key", `String "ca.pem"; "path", `String "other.pem" ]
                            ] )
                      ]))
               (list xs))) )
    ; ( "path prefix is not parent"
      , mounts (fun xs ->
          `List (List.map (set "mountPath" (`String "/etc/sol/db")) (list xs))) )
    ; ( "nested mount shadows CA"
      , fun d ->
          d
          |> volumes (fun xs ->
            `List
              (list xs @ [ `Assoc [ "name", `String "shadow"; "emptyDir", `Assoc [] ] ]))
          |> mounts (fun xs ->
            `List
              (list xs
               @ [ `Assoc
                     [ "name", `String "shadow"
                     ; "mountPath", `String "/etc/sol/db-ca/ca.pem"
                     ]
                 ])) )
    ]
  in
  List.iter
    (fun (name, change) ->
       run_read
         (mutate K.Deployment (items change) (baseline "aws"))
         (fun _ _ _ _ outcomes ->
            Alcotest.(check int) name 5 (List.length outcomes);
            all "FAIL" outcomes))
    cases
;;

(* A healthy neighbour cannot satisfy a missing or miswired declared consumer. *)
let test_single_consumer_failure () =
  let changes =
    [ set "items" (`List [])
    ; items (volumes (fun _ -> `List []))
    ; items
        (volumes (fun xs ->
           `List
             (List.map
                (set "configMap" (`Assoc [ "name", `String "neighbour-ca" ]))
                (list xs))))
    ]
  in
  List.iter
    (fun change ->
       let read q =
         let reply = baseline "aws" q in
         if q.K.resource = K.Deployment && q.name = "w3"
         then modify_stdout change reply
         else reply
       in
       run_read read (fun _ _ _ _ outcomes ->
         Alcotest.(check int) "complete consumer set" 5 (List.length outcomes);
         let failed =
           List.filter
             (fun outcome -> (recorded outcome).verdict.D.decision <> D.Pass)
             outcomes
         in
         Alcotest.(check int) "exactly the broken consumer refuses" 1 (List.length failed);
         all "FAIL" failed))
    changes
;;

let test_projection () =
  List.iter
    (fun change ->
       run_read
         (mutate K.Configmap (items change) (baseline "aws"))
         (fun _ _ _ _ -> all "FAIL"))
    [ set "data" (`Assoc [ "ca.crt", `String "not the declared key" ])
    ; set "data" (`Assoc [ "ca.pem", `String "" ])
    ; set "data" (`Assoc [])
    ];
  let contract = set "ca_key" (`String "ca.crt") (json "contract.json") in
  run_read ~contract (baseline "aws") (fun _ _ _ _ -> all "FAIL");
  List.iter
    (fun change ->
       run_read
         (mutate K.Configmap (items change) (baseline "aws"))
         (fun _ _ _ _ -> all "UNKNOWN"))
    [ at [ "metadata" ] (set "namespace" (`String "migration-only"))
    ; at [ "metadata" ] (set "name" (`String "other-consumer-ca"))
    ]
;;

let test_valid_subpaths () =
  let file_mount =
    mounts (fun xs ->
      `List
        (List.map
           (fun m ->
              m
              |> set "mountPath" (`String "/etc/sol/db-ca/ca.pem")
              |> set "subPath" (`String "ca.pem"))
           (list xs)))
  in
  let remapped d =
    d
    |> volumes (fun xs ->
      `List
        (List.map
           (set
              "configMap"
              (`Assoc
                  [ "name", `String "declared-ledger-ca"
                  ; ( "items"
                    , `List
                        [ `Assoc
                            [ "key", `String "ca.pem"; "path", `String "tls/root.pem" ]
                        ] )
                  ]))
           (list xs)))
    |> mounts (fun xs ->
      `List
        (List.map
           (fun m ->
              m
              |> set "mountPath" (`String "/etc/sol/db-ca/ca.pem")
              |> set "subPath" (`String "tls/root.pem"))
           (list xs)))
  in
  List.iter
    (fun change ->
       run_read
         (mutate K.Deployment (items change) (baseline "aws"))
         (fun _ _ _ _ -> all "PASS"))
    [ file_mount; remapped ]
;;

let test_failures () =
  let cases =
    [ K.Exited
        { code = 1; stdout = ""; stderr = "Error from server (Forbidden): forbidden" }
    ; K.Exited
        { code = 1; stdout = ""; stderr = "Error from server (NotFound): not found" }
    ; K.Exited
        { code = 1
        ; stdout = Yojson.Safe.to_string (json "configmaps.json")
        ; stderr = "Forbidden despite stdout"
        }
    ; K.Timed_out "deadline exceeded"
    ; K.Spawn_failed "kubectl: executable not found"
    ; K.Signaled (9, "terminated")
    ; K.Exited { code = 0; stdout = ""; stderr = "" }
    ; K.Exited { code = 0; stdout = "{}"; stderr = "" }
    ; K.Exited { code = 0; stdout = "invalid JSON"; stderr = "" }
    ]
  in
  List.iter
    (fun result ->
       let read q =
         let reply = baseline "aws" q in
         if q.K.resource = K.Configmap then { reply with result } else reply
       in
       run_read read (fun _ _ _ _ -> all "UNKNOWN"))
    cases;
  let incomplete = set "items" (`List []) in
  List.iter
    (fun change ->
       run_read
         (mutate K.Configmap change (baseline "aws"))
         (fun _ _ _ _ -> all "UNKNOWN"))
    [ (fun value ->
        value |> incomplete |> at [ "metadata" ] (set "continue" (`String "next-page")))
    ; (fun value ->
        value |> incomplete |> at [ "metadata" ] (set "remainingItemCount" (`Int 1)))
    ];
  (* A substituted successful empty list still cannot satisfy required presence. *)
  run_read (mutate K.Configmap incomplete (baseline "aws")) (fun _ _ _ _ -> all "FAIL");
  let mixed q =
    match q.K.resource with
    | K.Job -> Alcotest.fail "application observer unexpectedly requested Job"
    | K.Deployment -> modify_stdout incomplete (baseline "aws" q)
    | K.Configmap ->
      { (baseline "aws" q) with
        result = K.Exited { code = 1; stdout = ""; stderr = "Forbidden" }
      }
  in
  (* Preserve both reads: an unreadable required peer leaves the compound claim UNKNOWN. *)
  run_read mixed (fun _ _ _ _ -> all "UNKNOWN")
;;

let test_schema () =
  let changes =
    [ items (at [ "metadata" ] (set "namespace" (`String "wrong")))
    ; set "apiVersion" (`String "wrong")
    ; items (set "kind" (`String "StatefulSet"))
    ; items (at [ "metadata" ] (set "uid" `Null))
    ; items
        (volumes (fun xs ->
           `List (List.map (fun v -> `Assoc [ "name", field "name" v ]) (list xs))))
    ; items (volumes (fun xs -> `List (list xs @ list xs)))
    ; items (app (at [ "volumeMounts" ] (fun xs -> `List (list xs @ list xs))))
    ; items
        (mounts (fun xs ->
           `List (List.map (set "subPathExpr" (`String "$(CA_FILE)")) (list xs))))
    ; items
        (mounts (fun xs ->
           `List (List.map (set "subPath" (`String "../ca.pem")) (list xs))))
    ]
  in
  List.iter
    (fun change ->
       run_read
         (mutate K.Deployment change (baseline "aws"))
         (fun _ _ _ _ -> all "UNKNOWN"))
    changes;
  let read q =
    let reply = baseline "aws" q in
    match q.K.resource, reply.result with
    | K.Configmap, K.Exited output ->
      { reply with
        result =
          K.Exited
            { output with
              stdout = "{\"kind\":\"ConfigMapList\",\"kind\":\"ConfigMapList\"}"
            }
      }
    | _ -> reply
  in
  run_read read (fun _ _ _ _ -> all "UNKNOWN")
;;

let test_context () =
  let changes =
    [ (fun (c : D.read_context) ->
        { c with target = { c.target with principal = "operator" } })
    ; (fun c -> { c with target = { c.target with cluster = "another-cluster" } })
    ; (fun c -> { c with target = { c.target with endpoint = "https://other.invalid" } })
    ; (fun c -> { c with verified_at = 200 })
    ; (fun c -> { c with finished_at = 401 })
    ; (fun c -> { c with expires_at = Some 101 })
    ]
  in
  List.iter
    (fun change ->
       let read q =
         let reply = baseline "aws" q in
         { reply with context = change reply.context }
       in
       run_read read (fun _ _ _ _ -> all "UNKNOWN"))
    changes;
  let read q =
    let reply = baseline "aws" q in
    { reply with
      context =
        { reply.context with
          target = { (context "aws").target with principal = "operator" }
        }
    }
    |> modify_stdout (set "items" (`List []))
  in
  run_read read (fun _ _ _ _ -> all "UNKNOWN")
;;

let ca_requirement obligations instance =
  D.instances obligations
  |> List.find_map (fun i ->
    if D.instance_key i <> D.instance_key instance
    then None
    else (
      match D.plan i with
      | D.Ca_delivery r -> Some r
      | _ -> None))
  |> Option.get
;;

let test_receipt_substitution () =
  run_read (baseline "aws") (fun directory run obligations _ outcomes ->
    let first = List.hd outcomes
    and other = List.nth outcomes 1 in
    let requirement = ca_requirement obligations first.instance in
    let a = recorded first
    and b = recorded other in
    let deployment = List.hd a.observations in
    let configmap = List.nth b.observations 1 in
    C.evaluate_recorded ~directory ~run ~requirement ~deployment ~configmap
    |> stored
    |> decision "UNKNOWN";
    rejects
      (C.evaluate_recorded ~directory ~run ~requirement ~deployment ~configmap:deployment);
    let foreign, _ =
      setup ~contract:(set "ca_key" (`String "other.pem") (json "contract.json")) ()
    in
    rejects
      (C.evaluate_recorded ~directory ~run:foreign ~requirement ~deployment ~configmap))
;;

let test_explicit_containers () =
  let intent = Yojson.Safe.from_file "intent.json" in
  let intent =
    at
      [ "workloads" ]
      (fun xs ->
         `List
           (List.map
              (fun w ->
                 if field "database" w = `Null
                 then w
                 else
                   set
                     "consuming_containers"
                     (`List [ `String "app"; `String "metrics" ])
                     w)
              (list xs)))
      intent
  in
  run_read ~intent (baseline "aws") (fun _ _ _ _ -> all "FAIL");
  let missing =
    at
      [ "workloads" ]
      (fun xs -> `List (List.map (set "consuming_containers" (`List [])) (list xs)))
      intent
  in
  rejects (D.Fixture.intent missing)
;;

let test_persistence () =
  temporary (fun directory ->
    let run, obligations = setup () in
    let armed = ref false
    and writes = ref 0 in
    let fault boundary =
      if !armed && boundary = E.Temp_written
      then (
        incr writes;
        if !writes >= 2 then raise (Sys_error "injected capture failure"))
    in
    let recorder = open_store ~fault directory run in
    Fun.protect
      ~finally:(fun () -> E.close recorder)
      (fun () ->
         armed := true;
         let outcomes =
           C.observe_all ~directory ~run ~obligations ~recorder ~read:(baseline "aws")
           |> get
         in
         Alcotest.(check int)
           "capture failure still accounts for consumers"
           5
           (List.length outcomes);
         List.iter (fun (outcome : C.outcome) -> rejects outcome.result) outcomes;
         armed := false;
         rejects
           (E.seal
              recorder
              ~obligations
              ~requests:(List.map D.plan (D.instances obligations))
              ~verdicts:[]
              ~captures:[])))
;;

let rec files directory =
  Array.to_list (Sys.readdir directory)
  |> List.concat_map (fun name ->
    let path = Filename.concat directory name in
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then files path else [ path ])
;;

let contains text needle =
  let rec search i =
    i + String.length needle <= String.length text
    && (String.sub text i (String.length needle) = needle || search (i + 1))
  in
  search 0
;;

let test_error_secrecy () =
  let secret = "REGISTERED_AUTHENTICATION_FAILURE_SECRET" in
  let read q =
    match q.K.resource with
    | K.Job -> Alcotest.fail "application observer unexpectedly requested Job"
    | K.Deployment -> baseline "aws" q
    | K.Configmap ->
      { (baseline "aws" q) with
        result = K.Exited { code = 1; stdout = ""; stderr = "Forbidden: " ^ secret }
      }
  in
  run_read ~secrets:[ secret ] read (fun directory _ _ _ outcomes ->
    all "UNKNOWN" outcomes;
    List.iter
      (fun o ->
         match (recorded o).verdict.decision with
         | D.Unknown message ->
           Alcotest.(check bool)
             "original provider code/message retained"
             true
             (contains message "exit 1: Forbidden")
         | _ -> assert false)
      outcomes;
    List.iter
      (fun path ->
         let bytes = In_channel.with_open_bin path In_channel.input_all in
         Alcotest.(check bool)
           "diagnostic secret excluded from entire store"
           false
           (contains bytes secret))
      (files directory))
;;

let test_manifest_and_secrecy () =
  run_read (baseline "aws") (fun directory run obligations recorder outcomes ->
    let records = List.map recorded outcomes in
    let blocker =
      E.capture
        recorder
        ~subject:"I3-scope"
        ~payload:
          (`Assoc
              [ ( "unsupported"
                , `String "I3 observes CA only; other obligations remain required" )
              ])
      |> stored
    in
    let unsupported =
      D.instances obligations
      |> List.filter (fun i -> D.instance_kind i <> D.Ca)
      |> List.map (fun i ->
        let verdict =
          D.Fixture.blocked i ~evidence:[ E.digest blocker ] "not executed by I3" |> get
        in
        E.record_verdict recorder verdict ~observations:[ blocker ] |> stored)
    in
    let manifest =
      E.seal
        recorder
        ~obligations
        ~requests:(List.map D.plan (D.instances obligations))
        ~verdicts:(List.map (fun (r : C.recorded) -> r.receipt) records @ unsupported)
        ~captures:[]
      |> stored
    in
    let summary =
      E.verify_manifest ~directory ~run ~obligations ~required_captures:[] manifest
      |> stored
    in
    Alcotest.(check bool)
      "CA-only does not promote other requirements"
      false
      summary.passed;
    List.iter
      (fun path ->
         let bytes = In_channel.with_open_bin path In_channel.input_all in
         List.iter
           (fun secret ->
              Alcotest.(check bool)
                "raw Kubernetes values excluded"
                false
                (contains bytes secret))
           [ "CERTIFICATE_FIXTURE_BYTES_NEVER_CAPTURED"
           ; "UNREGISTERED_ENV_SECRET"
           ; "UNREGISTERED_ANNOTATION_SECRET"
           ])
      (files directory);
    let observation = List.hd (List.hd records).observations in
    Unix.unlink
      (Filename.concat (Filename.concat directory "members") (E.digest observation));
    rejects
      (E.verify_manifest ~directory ~run ~obligations ~required_captures:[] manifest))
;;

let () =
  Alcotest.run
    "Kubernetes CA qualification"
    [ ( "hostile"
      , List.map
          (fun (name, test) -> Alcotest.test_case name `Quick test)
          [ "one shared AWS/GCP observer", test_shared
          ; "multiple namespaces and direct object schemas", test_namespaces_and_objects
          ; "container and volume chain", test_mounts
          ; "one broken consumer among healthy neighbours", test_single_consumer_failure
          ; "candidate CA key and ConfigMap identity", test_projection
          ; "valid file and remapped subPaths", test_valid_subpaths
          ; "failed commands never establish absence (#1497)", test_failures
          ; "real-schema malformed and ambiguous objects", test_schema
          ; "per-read identity cluster and freshness", test_context
          ; "substituted durable receipts", test_receipt_substitution
          ; "explicit complete consuming containers", test_explicit_containers
          ; "successful reads without durable evidence", test_persistence
          ; "provider diagnostics and credential secrecy", test_error_secrecy
          ; "manifest scope integrity and safe projection", test_manifest_and_secrecy
          ] )
    ]
;;
