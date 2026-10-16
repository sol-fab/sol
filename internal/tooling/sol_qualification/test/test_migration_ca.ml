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

let field = Yojson.Safe.Util.member

let set key value = function
  | `Assoc xs -> `Assoc ((key, value) :: List.remove_assoc key xs)
  | _ -> Alcotest.fail "expected test object"
;;

let rec at keys fn value =
  match keys with
  | [] -> fn value
  | key :: rest -> set key (at rest fn (field key value)) value
;;

let json name = Yojson.Safe.from_file ("kubernetes/" ^ name)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let temporary fn =
  let path = Filename.temp_file "sol-migration-ca-" ".fixture" in
  Unix.unlink path;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then remove path)
    (fun () -> fn path)
;;

let setup provider =
  let target : D.kube_target =
    { principal = provider ^ ":reader"
    ; cluster = provider ^ "-cluster"
    ; endpoint = "https://" ^ provider ^ ".invalid"
    }
  in
  let scenario = if provider = "aws" then D.Aws else D.Gcp in
  let run =
    D.Fixture.bind
      ~scenario
      ~attempt:"migration-offline"
      ~assessment:"a1"
      ~candidate_revision:(String.make 40 'a')
      ~specimen:"specimen"
      ~kubernetes:target
      ~contract:(json "contract.json")
    |> get
  in
  let selection =
    D.select run (D.Fixture.intent (Yojson.Safe.from_file "intent.json") |> get) |> get
  in
  let obligations = D.bind_obligations run scenario selection |> get in
  let requirement =
    D.instances obligations
    |> List.find_map (fun i ->
      match D.plan i with
      | D.Migration_ca_delivery r -> Some r
      | _ -> None)
    |> Option.get
  in
  let context : D.read_context =
    { target
    ; verified_at = 98
    ; started_at = 101
    ; finished_at = 102
    ; expires_at = Some 300
    }
  in
  run, obligations, requirement, context
;;

let identity : D.job_identity =
  { namespace = "database-system"; name = "receipt-random-981"; uid = "execution-uid-42" }
;;

let baseline context (q : K.query) =
  let value =
    match q.resource with
    | K.Job -> json "migration-job.json"
    | K.Configmap -> json "migration-configmap.json"
    | K.Deployment -> Alcotest.fail "migration cannot become an application consumer"
  in
  (* Exact receipt name, never a reader's inferred deterministic Job name. *)
  Alcotest.(check string) "declared namespace" "database-system" q.namespace;
  if q.resource = K.Job then Alcotest.(check string) "execution name" identity.name q.name;
  K.
    { context
    ; result = Exited { code = 0; stdout = Yojson.Safe.to_string value; stderr = "" }
    }
;;

let mutate resource fn q reply =
  if q.K.resource <> resource
  then reply
  else (
    match reply.K.result with
    | K.Exited output ->
      { reply with
        result =
          K.Exited
            { output with
              stdout = Yojson.Safe.to_string (fn (Yojson.Safe.from_string output.stdout))
            }
      }
    | _ -> Alcotest.fail "test needs exited result")
;;

let execute
      ?(provider = "aws")
      ?(modify = fun _ r -> r)
      ?(execution_identity = identity)
      ?(execution_context = Fun.id)
      ?fault
      fn
  =
  temporary (fun directory ->
    let run, obligations, requirement, context = setup provider in
    let recorder =
      E.open_store
        ?fault
        ~directory
        ~run
        ~secrets:[ "PRIVATE-JOB-ENV"; "PRIVATE-CERTIFICATE-BYTES" ]
        ()
      |> stored
    in
    Fun.protect
      ~finally:(fun () -> E.close recorder)
      (fun () ->
         ignore
           (E.start_assessment
              recorder
              ~reason:"migration CA offline fixture"
              ~previous:[]
              ~required_captures:[]
            |> stored);
         let receipt =
           C.Fixture.capture_execution
             recorder
             requirement
             ~context:
               (execution_context { context with started_at = 99; finished_at = 100 })
             execution_identity
           |> stored
         in
         let read q = modify q (baseline context q) in
         let outcomes =
           C.observe_migrations
             ~directory
             ~run
             ~obligations
             ~recorder
             ~read
             ~execution:(fun _ -> Ok receipt)
           |> get
         in
         Alcotest.(check int)
           "one separate database CA obligation"
           1
           (List.length outcomes);
         fn directory run recorder requirement (List.hd outcomes)))
;;

let decision ?provider ?modify ?execution_identity ?execution_context expected () =
  execute ?provider ?modify ?execution_identity ?execution_context (fun _ _ _ _ outcome ->
    let decision = (stored outcome.C.result).verdict.D.decision in
    let actual =
      match decision with
      | D.Pass -> "PASS"
      | D.Fail _ -> "FAIL"
      | D.Unknown _ -> "UNKNOWN"
      | D.Not_run _ -> "NOT_RUN"
    in
    Alcotest.(check string) "migration CA classification" expected actual)
;;

let empty resource q reply =
  if q.K.resource <> resource
  then reply
  else (
    let kind, api =
      if resource = K.Job then "JobList", "batch/v1" else "ConfigMapList", "v1"
    in
    { reply with
      K.result =
        K.Exited
          { code = 0
          ; stderr = ""
          ; stdout =
              Yojson.Safe.to_string
                (`Assoc
                    [ "apiVersion", `String api
                    ; "kind", `String kind
                    ; "metadata", `Assoc [ "resourceVersion", `String "31" ]
                    ; "items", `List []
                    ])
          }
    })
;;

let test_persistence () =
  execute (fun directory run recorder requirement outcome ->
    let recorded = stored outcome.C.result in
    E.close recorder;
    match recorded.observations with
    | [ execution; job; configmap ] ->
      let verdict =
        C.evaluate_migration_recorded
          ~directory
          ~run
          ~requirement
          ~execution
          ~job
          ~configmap
        |> stored
      in
      Alcotest.(check bool)
        "persisted receipts support verdict"
        true
        (verdict.decision = D.Pass);
      (match
         C.evaluate_migration_recorded
           ~directory
           ~run
           ~requirement
           ~execution
           ~job:configmap
           ~configmap
       with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "ConfigMap receipt substituted for Job");
      let path =
        Filename.concat (Filename.concat directory "members") (E.digest execution)
      in
      Unix.chmod path 0o600;
      Out_channel.with_open_text path (fun ch -> output_string ch "corrupted receipt");
      (match
         C.evaluate_migration_recorded
           ~directory
           ~run
           ~requirement
           ~execution
           ~job
           ~configmap
       with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "corrupted execution established verdict")
    | _ -> Alcotest.fail "migration verdict must depend on three receipts")
;;

let test_missing_execution () =
  temporary (fun directory ->
    let run, obligations, _, _ = setup "aws" in
    let recorder = E.open_store ~directory ~run ~secrets:[] () |> stored in
    Fun.protect
      ~finally:(fun () -> E.close recorder)
      (fun () ->
         ignore
           (E.start_assessment
              recorder
              ~reason:"missing execution"
              ~previous:[]
              ~required_captures:[]
            |> stored);
         let outcomes =
           C.observe_migrations
             ~directory
             ~run
             ~obligations
             ~recorder
             ~read:(fun _ -> Alcotest.fail "missing execution must not infer a Job")
             ~execution:(fun _ ->
               Error E.{ stage = "execution"; diagnostic = "receipt missing" })
           |> get
         in
         List.iter
           (fun o ->
              match o.C.result with
              | Error _ -> ()
              | Ok _ -> Alcotest.fail "missing execution passed")
           outcomes))
;;

let test_capture_failure () =
  let fail = ref false in
  let fault boundary =
    if !fail && boundary = E.Temp_written
    then raise (Sys_error "capture persistence failed")
  in
  execute
    ~fault
    ~modify:(fun _ reply ->
      fail := true;
      reply)
    (fun _ _ _ _ outcome ->
       match outcome.C.result with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "unpersisted Job observation established verdict")
;;

let test_application_success_cannot_cover_migration () =
  execute ~modify:(empty K.Configmap) (fun directory run recorder _ outcome ->
    let _, obligations, _, context = setup "aws" in
    let application_read (q : K.query) =
      let fixture =
        json (if q.resource = K.Deployment then "deployments.json" else "configmaps.json")
      in
      let selected =
        field "items" fixture
        |> Yojson.Safe.Util.to_list
        |> List.filter (fun obj ->
          field "namespace" (field "metadata" obj) = `String q.namespace
          && field "name" (field "metadata" obj) = `String q.name)
      in
      K.
        { context
        ; result =
            Exited
              { code = 0
              ; stderr = ""
              ; stdout = Yojson.Safe.to_string (set "items" (`List selected) fixture)
              }
        }
    in
    let applications =
      C.observe_all ~directory ~run ~obligations ~recorder ~read:application_read |> get
    in
    Alcotest.(check int)
      "all five application consumers observed"
      5
      (List.length applications);
    List.iter
      (fun o ->
         Alcotest.(check bool)
           "application CA passes"
           true
           ((stored o.C.result).verdict.decision = D.Pass))
      applications;
    match (stored outcome.C.result).verdict.decision with
    | D.Fail _ -> ()
    | _ -> Alcotest.fail "healthy apps hid missing migration CA")
;;

let tests =
  [ "AWS receipt-bound CA", decision "PASS"
  ; "GCP receipt-bound CA", decision ~provider:"gcp" "PASS"
  ; "migration ConfigMap absent", decision ~modify:(empty K.Configmap) "FAIL"
  ; "ephemeral Job absent", decision ~modify:(empty K.Job) "FAIL"
  ; ( "recreated same-name Job"
    , decision
        ~modify:(mutate K.Job (at [ "metadata" ] (set "uid" (`String "replacement-uid"))))
        "UNKNOWN" )
  ; ( "wrong receipt namespace"
    , decision ~execution_identity:{ identity with namespace = "apps" } "UNKNOWN" )
  ; ( "wrong execution UID"
    , decision ~execution_identity:{ identity with uid = "other-execution" } "UNKNOWN" )
  ; ( "wrong Job namespace"
    , decision
        ~modify:(mutate K.Job (at [ "metadata" ] (set "namespace" (`String "apps"))))
        "UNKNOWN" )
  ; ( "wrong CA namespace"
    , decision
        ~modify:
          (mutate K.Configmap (at [ "metadata" ] (set "namespace" (`String "apps"))))
        "UNKNOWN" )
  ; ( "wrong CA key"
    , decision
        ~modify:(mutate K.Configmap (set "data" (`Assoc [ "ca.crt", `String "ca" ])))
        "FAIL" )
  ; ( "missing migration container"
    , decision
        ~modify:
          (mutate K.Job (at [ "spec"; "template"; "spec" ] (set "containers" (`List []))))
        "UNKNOWN" )
  ; ( "wrong consuming container"
    , decision
        ~modify:
          (mutate
             K.Job
             (at [ "spec"; "template"; "spec"; "containers" ] (function
                | `List [ c ] -> `List [ set "name" (`String "sidecar") c ]
                | _ -> assert false)))
        "FAIL" )
  ; ( "redirected mount"
    , decision
        ~modify:
          (mutate
             K.Job
             (at [ "spec"; "template"; "spec"; "containers" ] (function
                | `List [ c ] ->
                  `List
                    [ at
                        [ "volumeMounts" ]
                        (function
                          | `List [ m ] ->
                            `List [ set "mountPath" (`String "/elsewhere") m ]
                          | _ -> assert false)
                        c
                    ]
                | _ -> assert false)))
        "FAIL" )
  ; ( "stale execution identity"
    , decision ~execution_context:(fun c -> { c with verified_at = -1000 }) "UNKNOWN" )
  ; ( "identity changed since execution"
    , decision
        ~execution_context:(fun c ->
          { c with target = { c.target with principal = "another" } })
        "UNKNOWN" )
  ; ( "execution after observation"
    , decision
        ~execution_context:(fun c -> { c with started_at = 104; finished_at = 105 })
        "UNKNOWN" )
  ; ( "application success cannot cover migration"
    , test_application_success_cannot_cover_migration )
  ; ( "CA read predates migration execution"
    , decision
        ~modify:(fun q reply ->
          if q.K.resource = K.Configmap
          then
            { reply with
              K.context = { reply.context with started_at = 99; finished_at = 100 }
            }
          else reply)
        "UNKNOWN" )
  ; ( "incomplete migration discovery"
    , decision
        ~modify:(fun q reply ->
          if q.K.resource = K.Job
          then
            { reply with
              K.result =
                K.Exited
                  { code = 0
                  ; stderr = ""
                  ; stdout =
                      {|{"apiVersion":"batch/v1","kind":"JobList","metadata":{"resourceVersion":"1","continue":"page-2"},"items":[]}|}
                  }
            }
          else reply)
        "UNKNOWN" )
  ; "missing execution cannot infer name", test_missing_execution
  ; "durable receipt graph", test_persistence
  ; "unpersisted successful Job read", test_capture_failure
  ]
;;

let () =
  let failures =
    [ "Forbidden", K.Exited { code = 1; stdout = ""; stderr = "Forbidden" }
    ; ( "failed provider read with successful empty output"
      , K.Exited
          { code = 1
          ; stdout =
              "{\"apiVersion\":\"batch/v1\",\"kind\":\"JobList\",\"metadata\":{\"resourceVersion\":\"1\"},\"items\":[]}"
          ; stderr = "Unauthorized"
          } )
    ; "timeout", K.Timed_out "expired"
    ; "spawn", K.Spawn_failed "no executable"
    ; "malformed", K.Exited { code = 0; stdout = "not-json"; stderr = "" }
    ]
    |> List.concat_map (fun (name, result) ->
      List.map
        (fun resource ->
           ( (if resource = K.Job then "Job " else "ConfigMap ") ^ name
           , decision
               ~modify:(fun q reply ->
                 if q.K.resource = resource then { reply with K.result } else reply)
               "UNKNOWN" ))
        [ K.Job; K.Configmap ])
  in
  Alcotest.run
    "Offline migration CA"
    [ "hostile", List.map (fun (n, f) -> Alcotest.test_case n `Quick f) (tests @ failures)
    ]
;;
