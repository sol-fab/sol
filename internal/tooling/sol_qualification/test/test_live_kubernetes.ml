module D = Qual_domain
module E = Qual_evidence
module K = Qual_kubernetes
module L = Qual_kubernetes_live
module C = Qual_database_ca

let get = function
  | Ok x -> x
  | Error e -> Alcotest.fail e
;;

let stored = function
  | Ok x -> x
  | Error (e : E.error) -> Alcotest.fail (e.stage ^ ": " ^ e.diagnostic)
;;

let check b text = if not b then Alcotest.fail text
let json path = Yojson.Safe.from_file path

let set k v = function
  | `Assoc xs -> `Assoc ((k, v) :: List.remove_assoc k xs)
  | _ -> assert false
;;

let target : D.kube_target =
  { principal = "authenticated-reader"
  ; cluster = "server-cluster-uid"
  ; endpoint = "https://real-endpoint.invalid"
  }
;;

let obj xs = `Assoc xs
let str s = `String s

let config =
  obj
    [ "current-context", str "explicit-observer"
    ; ( "contexts"
      , `List
          [ obj
              [ "name", str "explicit-observer"
              ; ( "context"
                , obj
                    [ "cluster", str "local-cluster-alias"
                    ; "user", str "untrusted-label"
                    ] )
              ]
          ] )
    ; ( "clusters"
      , `List
          [ obj
              [ "name", str "local-cluster-alias"
              ; "cluster", obj [ "server", str target.endpoint ]
              ]
          ] )
    ; ( "users"
      , `List
          [ obj
              [ "name", str "untrusted-label"
              ; "user", obj [ "token", str "DISTINCTIVE_CONFIG_SECRET" ]
              ]
          ] )
    ]
;;

let whoami =
  obj
    [ "apiVersion", str "authentication.k8s.io/v1"
    ; "kind", str "SelfSubjectReview"
    ; "status", obj [ "userInfo", obj [ "username", str target.principal ] ]
    ]
;;

let cluster =
  obj
    [ "apiVersion", str "v1"
    ; "kind", str "Namespace"
    ; "metadata", obj [ "name", str "kube-system"; "uid", str target.cluster ]
    ]
;;

let write path json =
  Out_channel.with_open_text path (fun c -> output_string c (Yojson.Safe.to_string json))
;;

let setup ?fault root =
  let run =
    D.Fixture.bind
      ~scenario:D.Aws
      ~attempt:"live-boundary"
      ~assessment:"a1"
      ~candidate_revision:(String.make 40 'a')
      ~specimen:"offline-real-process-fixture"
      ~kubernetes:target
      ~contract:(json "kubernetes/contract.json")
    |> get
  in
  let selection = D.select run (D.Fixture.intent (json "intent.json") |> get) |> get in
  let obligations = D.bind_obligations run D.Aws selection |> get in
  let recorder =
    E.open_store
      ?fault
      ~directory:(root ^ "/evidence")
      ~run
      ~secrets:[ "DISTINCTIVE_PROCESS_SECRET"; "DISTINCTIVE_CONFIG_SECRET" ]
      ()
    |> stored
  in
  ignore
    (E.start_assessment
       recorder
       ~reason:"real kubectl process fixture"
       ~previous:[]
       ~required_captures:[]
     |> stored);
  run, selection, obligations, recorder
;;

let world =
  obj
    [ "config", config
    ; "whoami", whoami
    ; "cluster", cluster
    ; "deployments", str (Filename.concat (Sys.getcwd ()) "kubernetes/deployments.json")
    ; "configmaps", str (Filename.concat (Sys.getcwd ()) "kubernetes/configmaps.json")
    ; "jobs", str (Filename.concat (Sys.getcwd ()) "kubernetes/migration-job.json")
    ]
;;

let with_fixture ?fault mutate fn =
  let root = Filename.temp_dir "sol-live-boundary-" "" in
  let envs =
    [ "PATH"; "SOL_TEST_WORLD"; "SOL_TEST_CALLS"; "SOL_TEST_KUBECONFIG"; "KUBECONFIG" ]
  in
  let previous = List.map (fun k -> k, Sys.getenv_opt k) envs in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (k, v) ->
           match v with
           | Some v -> Unix.putenv k v
           | None -> Unix.putenv k "")
        previous;
      ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       let script =
         In_channel.with_open_text "fixture_live_kubectl.py" In_channel.input_all
       in
       Out_channel.with_open_text (root ^ "/kubectl") (fun c -> output_string c script);
       Unix.chmod (root ^ "/kubectl") 0o755;
       write (root ^ "/world.json") (mutate world);
       Unix.putenv "PATH" root;
       Unix.putenv "SOL_TEST_WORLD" (root ^ "/world.json");
       Unix.putenv "SOL_TEST_CALLS" (root ^ "/calls.json");
       Unix.putenv "SOL_TEST_KUBECONFIG" (root ^ "/explicit.kubeconfig");
       Unix.putenv "KUBECONFIG" "ambient-wrong";
       let ctx =
         Sol_cli_kube_destination.of_context
           ~kubeconfig:(root ^ "/explicit.kubeconfig")
           "explicit-observer"
         |> get
         |> Sol_cli_kube_destination.context_of_destination
       in
       let run, selection, obligations, recorder = setup ?fault root in
       Fun.protect
         ~finally:(fun () -> E.close recorder)
         (fun () -> fn root ctx run selection obligations recorder))
;;

let scan root =
  let rec loop path =
    if Sys.is_directory path
    then Array.iter (fun f -> loop (Filename.concat path f)) (Sys.readdir path)
    else (
      let text = In_channel.with_open_bin path In_channel.input_all in
      List.iter
        (fun secret ->
           check (not (Sol_cli_string.contains ~needle:secret text)) "secret persisted")
        [ "DISTINCTIVE_PROCESS_SECRET"
        ; "DISTINCTIVE_CONFIG_SECRET"
        ; "UNREGISTERED_ANNOTATION_SECRET"
        ])
  in
  loop (root ^ "/evidence")
;;

let observe mutate expect =
  with_fixture mutate (fun root ctx run selection obligations recorder ->
    let raw = ref [] in
    let transport =
      L.create
        ~ctx
        ~expected:target
        ~operator_diagnostics:(fun error -> raw := error :: !raw)
        ()
    in
    let outcomes =
      C.observe_all
        ~directory:(root ^ "/evidence")
        ~run
        ~obligations
        ~recorder
        ~read:(L.read transport)
      |> get
    in
    check (List.length outcomes = 5) "consumer omitted";
    check
      (D.exclusions selection = [ "unrelated", "no declared database dependency" ])
      "nonconsumer not accounted for";
    List.iter
      (fun (o : C.outcome) ->
         let r = stored o.result in
         check (expect r.verdict.decision) "wrong qualification decision")
      outcomes;
    scan root)
;;

let pass = function
  | D.Pass -> true
  | _ -> false
;;

let fail = function
  | D.Fail _ -> true
  | _ -> false
;;

let unknown = function
  | D.Unknown _ -> true
  | _ -> false
;;

let error k = set k (`Int 1)

let change_principal =
  set
    "whoami"
    (set "status" (obj [ "userInfo", obj [ "username", str "other-reader" ] ]) whoami)
;;

let test_query_mismatch () =
  with_fixture Fun.id (fun _ ctx _ _ obligations _ ->
    let requirement =
      List.find_map
        (fun i ->
           match D.plan i with
           | D.Ca_delivery r -> Some r
           | _ -> None)
        (D.instances obligations)
      |> Option.get
    in
    let query, _ = K.queries requirement in
    let transport =
      L.create ~ctx ~expected:{ target with cluster = "another-cluster" } ()
    in
    match K.classify query (L.read transport query) with
    | K.Deployment_read { state = D.Unreadable _; _ } -> ()
    | _ -> Alcotest.fail "wrong transport authority accepted")
;;

let test_auth_failure_classification () =
  with_fixture (error "read_error") (fun _root ctx _ _ obligations _ ->
    let requirement =
      List.find_map
        (fun i ->
           match D.plan i with
           | D.Ca_delivery r -> Some r
           | _ -> None)
        (D.instances obligations)
      |> Option.get
    in
    let _, query = K.queries requirement in
    let transport = L.create ~ctx ~expected:target () in
    match K.classify query (L.read transport query) with
    | K.Configmap_read { state = D.Unreadable _; _ } -> ()
    | _ -> Alcotest.fail "failed command became absence")
;;

let cluster_setting key value document =
  let open Yojson.Safe.Util in
  set
    "clusters"
    (`List
        (List.map
           (fun c -> set "cluster" (set key value (member "cluster" c)) c)
           (member "clusters" document |> to_list)))
    document
;;

let direct mutate action expect =
  with_fixture mutate (fun root ctx _ _ obligations _ ->
    let requirement =
      List.find_map
        (fun i ->
           match D.plan i with
           | D.Ca_delivery r -> Some r
           | _ -> None)
        (D.instances obligations)
      |> Option.get
    in
    let _, query = K.queries requirement in
    action root;
    let transport = L.create ~ctx ~expected:target () in
    match K.classify query (L.read transport query) with
    | K.Configmap_read r -> check (expect r.state) "wrong direct state"
    | _ -> assert false)
;;

let unreadable = function
  | D.Unreadable _ -> true
  | _ -> false
;;

let migration ?(uid = "execution-uid-42") mutate expect () =
  let mutate world =
    mutate
      (set
         "configmaps"
         (str (Filename.concat (Sys.getcwd ()) "kubernetes/migration-configmap.json"))
         world)
  in
  with_fixture mutate (fun root ctx run _ obligations recorder ->
    let transport = L.create ~ctx ~expected:target () in
    let execution requirement =
      let binding = D.migration_ca_binding requirement in
      let now = int_of_float (Unix.gettimeofday ()) in
      C.Fixture.capture_execution
        recorder
        requirement
        ~context:
          { D.target
          ; verified_at = now - 1
          ; started_at = now - 1
          ; finished_at = now - 1
          ; expires_at = Some (now + 300)
          }
        { D.namespace = binding.namespace; name = "receipt-random-981"; uid }
    in
    let outcomes =
      C.observe_migrations
        ~directory:(root ^ "/evidence")
        ~run
        ~obligations
        ~recorder
        ~read:(L.read transport)
        ~execution
      |> get
    in
    check (List.length outcomes = 1) "migration obligation omitted";
    List.iter
      (fun (o : C.outcome) ->
         check (expect (stored o.result).verdict.decision) "wrong migration decision")
      outcomes;
    let calls = Yojson.Safe.to_string (json (root ^ "/calls.json")) in
    check (Sol_cli_string.contains ~needle:"jobs.batch" calls) "Job transport bypassed";
    check (Sol_cli_string.contains ~needle:"configmaps" calls) "CA transport bypassed";
    scan root)
;;

let interrupted_capture () =
  let armed = ref false in
  let fault boundary =
    if !armed && boundary = E.Temp_written then raise (Sys_error "interrupted capture")
  in
  with_fixture ~fault Fun.id (fun root ctx run _ obligations recorder ->
    let transport = L.create ~ctx ~expected:target () in
    let read query =
      let reply = L.read transport query in
      armed := true;
      reply
    in
    let outcomes =
      C.observe_all ~directory:(root ^ "/evidence") ~run ~obligations ~recorder ~read
      |> get
    in
    check (List.length outcomes = 5) "capture failure omitted consumers";
    List.iter
      (fun (o : C.outcome) ->
         match o.result with
         | Error _ -> ()
         | Ok _ -> Alcotest.fail "unpersisted observation established verdict")
      outcomes;
    let calls = Yojson.Safe.to_string (json (root ^ "/calls.json")) in
    check (Sol_cli_string.contains ~needle:"deployments.apps" calls) "read never executed";
    E.close recorder;
    let reopened =
      E.open_store ~directory:(root ^ "/evidence") ~run ~secrets:[] () |> stored
    in
    Fun.protect
      ~finally:(fun () -> E.close reopened)
      (fun () ->
         match
           E.seal
             reopened
             ~obligations
             ~requests:(List.map D.plan (D.instances obligations))
             ~verdicts:[]
             ~captures:[]
         with
         | Error _ -> ()
         | Ok _ -> Alcotest.fail "restart erased missing observations");
    scan root)
;;

let () =
  Alcotest.run
    "Authenticated Kubernetes process boundary"
    [ ( "boundary"
      , [ ( "nonconsumer excluded; complete consumers pass"
          , `Quick
          , fun () -> observe Fun.id pass )
        ; ( "declared consumer missing CA fails"
          , `Quick
          , fun () -> observe (set "missing_ca" (`Bool true)) fail )
        ; ( "consumer wrong CA fails"
          , `Quick
          , fun () -> observe (set "wrong_ca" (`Bool true)) fail )
        ; ("wrong principal", `Quick, fun () -> observe change_principal unknown)
        ; ( "wrong cluster UID"
          , `Quick
          , fun () ->
              observe
                (set
                   "cluster"
                   (set
                      "metadata"
                      (obj [ "name", str "kube-system"; "uid", str "other" ])
                      cluster))
                unknown )
        ; ( "expired credentials after read"
          , `Quick
          , fun () -> observe (set "expired" (`Bool true)) unknown )
        ; ( "identity rotates during read"
          , `Quick
          , fun () ->
              direct
                (set
                   "after_whoami"
                   (set
                      "status"
                      (obj [ "userInfo", obj [ "username", str "other" ] ])
                      whoami))
                ignore
                unreadable )
        ; ( "cluster replaced during read"
          , `Quick
          , fun () ->
              direct
                (set
                   "after_cluster"
                   (set
                      "metadata"
                      (obj [ "name", str "kube-system"; "uid", str "new" ])
                      cluster))
                ignore
                unreadable )
        ; ( "malformed output"
          , `Quick
          , fun () -> observe (set "malformed" (`Bool true)) unknown )
        ; ("partial list", `Quick, fun () -> observe (set "partial" (`Bool true)) unknown)
        ; "migration Job and CA through process transport", `Quick, migration Fun.id pass
        ; ( "recreated migration Job cannot satisfy receipt"
          , `Quick
          , migration ~uid:"replaced-execution-uid" Fun.id unknown )
        ; ( "missing migration CA fails"
          , `Quick
          , migration (set "missing_ca" (`Bool true)) fail )
        ; ( "interrupted live capture cannot establish PASS after restart"
          , `Quick
          , interrupted_capture )
        ; "Forbidden never absence", `Quick, test_auth_failure_classification
        ; "unrelated transport authority", `Quick, test_query_mismatch
        ; ( "wrong identity is never a trusted Present"
          , `Quick
          , fun () -> direct change_principal ignore unreadable )
        ; ( "positive native absence"
          , `Quick
          , fun () ->
              direct
                (set "missing_ca" (`Bool true))
                ignore
                (function
                  | D.Absent -> true
                  | _ -> false) )
        ; ( "wrong endpoint"
          , `Quick
          , fun () ->
              observe
                (set
                   "config"
                   (cluster_setting "server" (str "https://another.invalid") config))
                unknown )
        ; ( "insecure TLS refused"
          , `Quick
          , fun () ->
              observe
                (set
                   "config"
                   (cluster_setting "insecure-skip-tls-verify" (`Bool true) config))
                unknown )
        ; ( "configuration changed during read"
          , `Quick
          , fun () ->
              direct
                (set
                   "after_config"
                   (cluster_setting "server" (str "https://another.invalid") config))
                ignore
                unreadable )
        ; ( "spawn failure"
          , `Quick
          , fun () ->
              direct Fun.id (fun root -> Unix.unlink (root ^ "/kubectl")) unreadable )
        ; ( "real process timeout"
          , `Quick
          , fun () -> direct (set "sleep" (`Bool true)) ignore unreadable )
        ] )
    ]
;;
