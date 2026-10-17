(* Test driver only; fixture PASS is never a release verdict. The Python harness
   builds installed candidates and invokes the real verifier/producer. *)
module D = Qual_domain
module C = Qual_candidate
module B = Qual_candidate_obligations
module E = Qual_evidence
module K = Qual_kubernetes
module CA = Qual_database_ca
module MX = Qual_migration_execution

let get = function
  | Ok x -> x
  | Error e -> failwith e
;;

let evidence = function
  | Ok x -> x
  | Error (e : E.error) -> failwith (e.stage ^ ": " ^ e.diagnostic)
;;

let rejects = function
  | Error _ -> ()
  | Ok _ -> failwith "unsafe result accepted"
;;

let check condition message = if not condition then failwith message
let field name json = Yojson.Safe.Util.member name json
let text name json = field name json |> Yojson.Safe.Util.to_string

let kube : D.kube_target =
  { principal = "offline-reader"
  ; cluster = "offline-cluster"
  ; endpoint = "https://offline.invalid"
  }
;;

let context : D.read_context =
  { target = kube
  ; verified_at = 0
  ; started_at = 2
  ; finished_at = 3
  ; expires_at = Some 10
  }
;;

let obj xs = `Assoc xs
let str s = `String s
let strings xs = `List (List.map str xs)

let read_good (prepared : B.t) (q : K.query) =
  let ca_key, ca_path, configmap, containers =
    D.instances prepared.obligations
    |> List.find_map (fun i ->
      if D.instance_identity i <> q.requirement
      then None
      else (
        match D.plan i with
        | D.Ca_delivery r ->
          let b = D.ca_binding r in
          Some (b.ca_key, b.ca_path, b.configmap, b.consuming_containers)
        | D.Migration_ca_delivery r ->
          let b = D.migration_ca_binding r in
          Some (b.ca_key, b.ca_path, b.configmap, [ b.container ])
        | _ -> None))
    |> Option.get
  in
  let metadata =
    obj
      [ "namespace", str q.namespace
      ; "name", str q.name
      ; "uid", str "object-uid"
      ; "resourceVersion", str "1"
      ]
  in
  let document =
    match q.resource with
    | K.Configmap ->
      obj
        [ "apiVersion", str "v1"
        ; "kind", str "ConfigMap"
        ; "metadata", metadata
        ; "data", obj [ ca_key, str "offline-public-ca" ]
        ]
    | (K.Deployment | K.Job) as resource ->
      let mounts =
        `List
          [ obj
              [ "name", str "linked-volume"; "mountPath", str (Filename.dirname ca_path) ]
          ]
      in
      obj
        [ "apiVersion", str (if resource = K.Job then "batch/v1" else "apps/v1")
        ; "kind", str (if resource = K.Job then "Job" else "Deployment")
        ; "metadata", metadata
        ; ( "spec"
          , obj
              [ ( "template"
                , obj
                    [ ( "spec"
                      , obj
                          [ ( "containers"
                            , `List
                                (List.map
                                   (fun name ->
                                      obj [ "name", str name; "volumeMounts", mounts ])
                                   containers) )
                          ; ( "volumes"
                            , `List
                                [ obj
                                    [ "name", str "linked-volume"
                                    ; "configMap", obj [ "name", str configmap ]
                                    ]
                                ] )
                          ] )
                    ] )
              ] )
        ]
  in
  { K.context
  ; result = K.Exited { code = 0; stdout = Yojson.Safe.to_string document; stderr = "" }
  }
;;

(* Offline launcher probe: uses the real verified-candidate handle so the
   authority-bearing [Qual_migration_execution.run] path is exercised against the
   candidate the Python fixture built, never an arbitrary installation path. *)
let launcher_probe verified path =
  let binding = String.make 64 'b' in
  let now = int_of_float (Unix.gettimeofday ()) in
  let context : D.read_context =
    { target = kube
    ; verified_at = now
    ; started_at = now
    ; finished_at = now
    ; expires_at = Some (now + 300)
    }
  in
  let outcome =
    MX.run
      ~verified
      ~expected:kube
      ~binding
      ~timeout_s:10.
      ~completion_timeout_s:10.
      ~establish:(fun () -> Ok context)
      ~consume:(fun locator ->
        Ok (locator.MX.identity, locator.MX.receipt.Sol_cli_migration_execution.target))
  in
  let json =
    match outcome with
    | Error message -> obj [ "ok", `Bool false; "error", str message ]
    | Ok (identity, target) ->
      obj
        [ "ok", `Bool true
        ; "namespace", str identity.D.namespace
        ; "name", str identity.D.name
        ; "uid", str identity.D.uid
        ; "target", str target
        ]
  in
  Out_channel.with_open_text path (fun c -> output_string c (Yojson.Safe.to_string json))
;;

let exercise ~scenario verified prepared directory =
  List.iter
    (fun scenario ->
       rejects
         (B.prepare
            ~verified
            ~scenario
            ~attempt:"offline"
            ~assessment:"a1"
            ~kubernetes:kube))
    [ D.Local; (if scenario = D.Aws then D.Gcp else D.Aws) ];
  let fault = ref false in
  let recorder =
    E.open_store
      ~directory
      ~run:prepared.B.run
      ~secrets:[ "DISTINCTIVE-SECRET-CANNOT-APPEAR" ]
      ~fault:(fun boundary ->
        if !fault && boundary = E.Temp_written
        then raise (Sys_error "injected persistence failure"))
      ()
    |> evidence
  in
  ignore
    (E.start_assessment
       recorder
       ~reason:"offline binding exercise"
       ~previous:[]
       ~required_captures:prepared.required_captures
     |> evidence);
  let later =
    B.prepare ~verified ~scenario ~attempt:"offline" ~assessment:"a2" ~kubernetes:kube
    |> get
  in
  rejects (B.capture_binding later recorder);
  fault := true;
  rejects (B.capture_binding prepared recorder);
  E.close recorder;
  (* Required slot remains in the committed assessment after process/store restart. *)
  let recorder = E.open_store ~directory ~run:prepared.run ~secrets:[] () |> evidence in
  rejects
    (E.start_assessment
       recorder
       ~reason:"offline binding exercise"
       ~previous:[]
       ~required_captures:[]);
  ignore
    (E.start_assessment
       recorder
       ~reason:"offline binding exercise"
       ~previous:[]
       ~required_captures:prepared.required_captures
     |> evidence);
  let receipt = B.capture_binding prepared recorder |> evidence in
  let captured = E.read_capture ~directory ~run:prepared.run receipt |> evidence in
  check
    (get (D.canonical_json captured.payload)
     = get (D.canonical_json (D.run_json prepared.run)))
    "binding capture changed";
  rejects (E.read_capture ~directory ~run:later.run receipt);
  let other_identity =
    B.prepare
      ~verified
      ~scenario
      ~attempt:"offline"
      ~assessment:"a1"
      ~kubernetes:{ kube with principal = "other-reader" }
    |> get
  in
  rejects (B.capture_binding other_identity recorder);
  rejects (E.read_capture ~directory ~run:other_identity.run receipt);
  let ca_bindings =
    List.filter_map
      (fun i ->
         match D.plan i with
         | D.Ca_delivery r -> Some (D.ca_binding r)
         | _ -> None)
      (D.instances prepared.obligations)
  in
  let definition = C.definition verified in
  List.iter
    (fun request ->
       let i = D.requested request in
       let source =
         List.find_opt
           (fun (b : D.ca_binding) ->
              String.ends_with ~suffix:("/" ^ b.subject) (D.instance_key i))
           ca_bindings
       in
       match request, source with
       | D.Dml_delivery requirement, Some b ->
         let observation =
           D.Fixture.observe
             prepared.run
             ~subject:b.subject
             ~evidence:[ E.digest receipt ]
             (D.Present
                D.
                  { namespace = b.namespace
                  ; workload = b.workload
                  ; credential_class = definition.dml_class
                  ; key = definition.credential_key
                  ; nonempty = true
                  })
           |> get
         in
         check
           ((D.evaluate (D.Dml_checked (requirement, observation))).decision <> D.Pass)
           "unsupported DML verification gained authority"
       | D.Tls_connectivity requirement, Some b ->
         let observation =
           D.Fixture.observe
             prepared.run
             ~subject:b.subject
             ~evidence:[ E.digest receipt ]
             (D.Present
                D.{ namespace = b.namespace; workload = b.workload; verified = true })
           |> get
         in
         check
           ((D.evaluate (D.Tls_checked (requirement, observation))).decision <> D.Pass)
           "unsupported TLS verification gained authority"
       | _ -> ())
    prepared.requests;
  let outcomes =
    CA.observe_all
      ~directory
      ~run:prepared.run
      ~obligations:prepared.obligations
      ~recorder
      ~read:(read_good prepared)
    |> get
  in
  check (List.length outcomes = 2) "incomplete CA selection";
  let verdicts =
    List.map
      (fun (o : CA.outcome) ->
         let r = evidence o.result in
         check (r.verdict.decision = D.Pass) "expected CA mechanism PASS";
         r.verdict)
      outcomes
  in
  let migration uid requirement =
    let b = D.migration_ca_binding requirement in
    CA.Fixture.capture_execution
      recorder
      requirement
      ~context:{ context with started_at = 0; finished_at = 1 }
      D.{ namespace = b.namespace; name = "actual-execution-receipt-71"; uid }
  in
  let migration_outcomes =
    CA.observe_migrations
      ~directory
      ~run:prepared.run
      ~obligations:prepared.obligations
      ~recorder
      ~read:(read_good prepared)
      ~execution:(migration "object-uid")
    |> get
  in
  check (List.length migration_outcomes = 1) "missing migration CA obligation";
  let verdicts =
    verdicts
    @ List.map
        (fun (o : CA.outcome) ->
           let recorded = evidence o.result in
           check
             (recorded.verdict.decision = D.Pass)
             "candidate-bound migration CA failed";
           recorded.verdict)
        migration_outcomes
  in
  let substituted =
    CA.observe_migrations
      ~directory
      ~run:prepared.run
      ~obligations:prepared.obligations
      ~recorder
      ~read:(read_good prepared)
      ~execution:(migration "another-execution-uid")
    |> get
  in
  List.iter
    (fun (o : CA.outcome) ->
       match o.result with
       | Error _ -> ()
       | Ok r -> check (r.verdict.decision <> D.Pass) "another migration execution passed")
    substituted;
  rejects (D.accept_mechanism prepared.obligations prepared.requests verdicts);
  rejects (D.reconcile_plan prepared.obligations (List.tl prepared.requests));
  rejects
    (D.reconcile_plan
       prepared.obligations
       (List.hd prepared.requests :: prepared.requests));
  rejects (D.reconcile_plan prepared.obligations later.requests);
  let unrelated_intent =
    D.Fixture.intent
      (`Assoc
          [ ( "databases"
            , `List
                [ `Assoc
                    [ "id", str "other"
                    ; "ca_configmap", str "other-ca"
                    ; ( "administrative_secret"
                      , obj [ "namespace", str "db"; "name", str "master" ] )
                    ; ( "migration"
                      , obj
                          [ "namespace", str "db"
                          ; "container", str "migrate"
                          ; "configmap", str "other-ca"
                          ] )
                    ]
                ] )
          ; ( "workloads"
            , `List
                [ obj
                    [ "id", str "another/consumer"
                    ; "namespace", str "apps"
                    ; "name", str "another"
                    ; "database", str "other"
                    ; "consuming_containers", strings [ "app" ]
                    ]
                ] )
          ])
    |> get
  in
  rejects (D.select prepared.run unrelated_intent);
  (* K owns classification; this composed path must reject failed-command PASS
     and preserve the earlier immutable assessment decision. *)
  let bad =
    CA.observe_all
      ~directory
      ~run:prepared.run
      ~obligations:prepared.obligations
      ~recorder
      ~read:(fun _ ->
        { K.context
        ; result =
            K.Exited
              { code = 1
              ; stdout = "{\"kind\":\"List\",\"items\":[]}"
              ; stderr = "Forbidden"
              }
        })
    |> get
  in
  List.iter
    (fun (o : CA.outcome) ->
       match o.result with
       | Error _ -> ()
       | Ok r -> check (r.verdict.decision <> D.Pass) "failed provider command passed")
    bad;
  (match Sys.getenv_opt "SOL_LAUNCHER_RESULT" with
   | Some path -> launcher_probe verified path
   | None -> ());
  E.close recorder
;;

let () =
  try
    let repository, candidate, install, workspace, pin_path, directory, scenario =
      match Array.to_list Sys.argv with
      | [ _; a; b; c; d; e; f; scenario ] ->
        let scenario =
          match scenario with
          | "aws" -> D.Aws
          | "gcp" -> D.Gcp
          | _ -> failwith "unsupported fixture scenario"
        in
        a, b, c, d, e, f, scenario
      | _ -> failwith "fixture driver arguments"
    in
    let pins = Yojson.Safe.from_file pin_path in
    let expected : C.expected =
      { revision = text "revision" pins
      ; bundle_digest = text "bundle_digest" pins
      ; definition_digest = text "definition_digest" pins
      ; specimen_digest = text "specimen_digest" pins
      ; target = text "target" pins
      ; requested_target = text "requested_target" pins
      }
    in
    let verified = C.verify ~repository ~candidate ~install ~workspace ~expected |> get in
    let prepared =
      B.prepare ~verified ~scenario ~attempt:"offline" ~assessment:"a1" ~kubernetes:kube
      |> get
    in
    if directory <> "-" then exercise ~scenario verified prepared directory;
    let selection = D.select prepared.run prepared.intent |> get in
    print_endline
      (Yojson.Safe.to_string
         (obj
            [ "run", D.run_json prepared.run
            ; "workloads", `List (D.expected_workloads prepared.intent)
            ; "consumers", strings (D.consumers selection)
            ; "obligations", D.obligations_json prepared.obligations
            ]))
  with
  | Failure message ->
    prerr_endline message;
    exit 2
;;
