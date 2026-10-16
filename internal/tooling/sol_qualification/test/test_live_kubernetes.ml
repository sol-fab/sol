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
       write
         (root ^ "/world.json")
         (mutate (set "submitted_job" (str (root ^ "/submitted-job.json")) world));
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

module M = Sol_cli_migration_execution
module J = Sol_cli_migration_job

let product_execution
      ?(cli = false)
      ?(capture_failure = false)
      ?(close_receiver = false)
      ?(expect_event = true)
      ?(expect_exit = 0)
      mutate
      ()
  =
  let mutate world =
    set
      "configmaps"
      (str (Filename.concat (Sys.getcwd ()) "kubernetes/migration-configmap.json"))
      (mutate world)
  in
  let armed = ref false in
  let fault boundary =
    if !armed && boundary = E.Temp_written
    then raise (Sys_error "product execution capture interrupted")
  in
  with_fixture ~fault mutate (fun root ctx run _ obligations recorder ->
    let expected_target = if cli then "dev/aws/us-east-1" else "aws.staging" in
    let cli_binary =
      if cli then Some (Unix.realpath (Sys.getenv "SOL_TEST_SOL")) else None
    in
    let workspace = root ^ "/specimen" in
    if cli
    then (
      List.iter
        (fun path -> Sol_cli_fs.mkdir_p (workspace ^ path) |> get)
        [ "/sol"; "/app/payments/charge_svc"; "/db/migrations" ];
      List.iter
        (fun package ->
           let directory = root ^ "/fixture-assets/framework/ocaml/" ^ package ^ "/lib" in
           Sol_cli_fs.mkdir_p directory |> get;
           Out_channel.with_open_text (directory ^ "/dune") (fun _ -> ()))
        [ "sol-svc"; "kafka-eio-service" ];
      let write_text path text =
        Out_channel.with_open_text (workspace ^ path) (fun c -> output_string c text)
      in
      write_text
        "/sol.yml"
        "project: specimen\n\
         resources:\n\
        \  app_db:\n\
        \    type: postgres\n\
         services:\n\
        \  charge_svc:\n\
        \    type: http\n\
        \    path: app/payments/charge_svc\n\
        \    uses: [app_db]\n";
      write_text "/app/payments/charge_svc/sol.toml" "";
      write_text "/app/payments/charge_svc/Dockerfile" "FROM scratch\n";
      write_text "/db/migrations/0001_initial.sql" "-- migrate:up\nselect 1;\n";
      write_text
        "/sol/environments.yml"
        ("dev:\n\
         \  shape: local\n\
         \  targets:\n\
         \    aws/us-east-1:\n\
         \      registry: registry.invalid\n\
         \      kube_context: explicit-observer\n\
         \      kubeconfig: "
         ^ root
         ^ "/explicit.kubeconfig\n"));
    let committed_execution = ref None in
    let parent, child = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let binding = String.make 64 'b' in
    let pid = Unix.fork () in
    if pid = 0
    then (
      Unix.close parent;
      Unix.dup2 child Unix.stdin;
      Unix.close child;
      Unix.putenv M.environment binding;
      (match cli_binary with
       | None -> ()
       | Some program ->
         Unix.putenv "SOL_HOME" (root ^ "/fixture-assets");
         Unix.putenv
           Sol_cli_platform_assets.runner_image_env
           ("registry.invalid/runner@sha256:" ^ String.make 64 'b');
         Unix.chdir workspace;
         Unix.execv program [| program; "migrate"; "apply"; expected_target |]);
      let result =
        J.submit
          ~ctx
          ~namespace:"database-system"
          ~name_prefix:"sol-migrate"
          ~label:""
          ~image:"fixture.invalid/migrate"
          ~args:[ "migrate"; "apply" ]
          ~files:[ "0001.sql", "select 1" ]
          ~ddl_creds_name:"fixture-ddl"
          ~ca_configmap:"declared-ledger-ca"
          ~execution_target:"aws.staging"
          ()
      in
      let code =
        match result with
        | Error _ -> 1
        | Ok job ->
          let outcome = J.wait ~ctx ~interval_s:0. ~attempts:1 job in
          J.cleanup ~ctx job;
          if outcome = J.Succeeded then 0 else 2
      in
      Unix._exit code);
    Unix.close child;
    let joined = ref false in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.close parent with
         | Unix.Unix_error _ -> ());
        if not !joined
        then (
          Unix.kill pid Sys.sigkill;
          ignore (Unix.waitpid [] pid)))
      (fun () ->
         if close_receiver
         then Unix.close parent
         else (
           let message = M.receive ~timeout_s:20. parent |> get in
           if expect_event
           then (
             let receipt =
               match message with
               | M.Execution r -> r
               | M.Unavailable -> Alcotest.fail "actual execution unavailable"
             in
             check
               (receipt.binding = binding && receipt.target = expected_target)
               "submission binding lost";
             let observed = json (root ^ "/submitted-job.json") in
             check
               (Yojson.Safe.Util.member
                  "uid"
                  (Yojson.Safe.Util.member "metadata" observed)
                = str receipt.uid)
               "UID not from actual API response";
             check
               (Yojson.Safe.Util.member
                  "name"
                  (Yojson.Safe.Util.member "metadata" observed)
                = str receipt.name)
               "Job name reconstructed";
             let calls = Yojson.Safe.to_string (json (root ^ "/calls.json")) in
             check
               (not (Sol_cli_string.contains ~needle:"delete" calls))
               "cleanup raced capture";
             if not cli
             then (
               let requirement =
                 List.find_map
                   (fun i ->
                      match D.plan i with
                      | D.Migration_ca_delivery r -> Some r
                      | _ -> None)
                   (D.instances obligations)
                 |> Option.get
               in
               let context : D.read_context =
                 { target =
                     { principal = receipt.principal
                     ; cluster = receipt.cluster
                     ; endpoint = receipt.endpoint
                     }
                 ; verified_at = receipt.observed_at
                 ; started_at = receipt.observed_at
                 ; finished_at = receipt.observed_at
                 ; expires_at = Some (receipt.observed_at + 300)
                 }
               in
               let identity : D.job_identity =
                 { namespace = receipt.namespace; name = receipt.name; uid = receipt.uid }
               in
               armed := capture_failure;
               let capture =
                 C.Fixture.capture_execution recorder requirement ~context identity
               in
               if capture_failure
               then (
                 match capture with
                 | Error _ -> ()
                 | Ok _ -> Alcotest.fail "capture fault bypassed")
               else (
                 let execution = stored capture in
                 committed_execution := Some execution;
                 let transport = L.create ~ctx ~expected:target () in
                 let outcomes =
                   C.observe_migrations
                     ~directory:(root ^ "/evidence")
                     ~run
                     ~obligations
                     ~recorder
                     ~read:(L.read transport)
                     ~execution:(fun _ -> Ok execution)
                   |> get
                 in
                 check (List.length outcomes = 1) "migration omitted";
                 List.iter
                   (fun (o : C.outcome) ->
                      check
                        (pass (stored o.result).verdict.decision)
                        "independent Job/CA observation failed")
                   outcomes)))
           else check (message = M.Unavailable) "unestablished submission emitted receipt";
           M.acknowledge parent |> get);
         let _, status = Unix.waitpid [] pid in
         joined := true;
         check
           (status = Unix.WEXITED expect_exit)
           "receipt failure prevented normal lifecycle";
         let calls = Yojson.Safe.to_string (json (root ^ "/calls.json")) in
         check (Sol_cli_string.contains ~needle:"delete" calls) "cleanup skipped";
         check
           (not (Sys.file_exists (root ^ "/submitted-job.json")))
           "ephemeral Job survived fake cleanup";
         E.close recorder;
         let reopened =
           E.open_store ~directory:(root ^ "/evidence") ~run ~secrets:[] () |> stored
         in
         Fun.protect
           ~finally:(fun () -> E.close reopened)
           (fun () ->
              Option.iter
                (fun reference ->
                   let capture =
                     E.read_capture ~directory:(root ^ "/evidence") ~run reference
                     |> stored
                   in
                   check
                     (Yojson.Safe.Util.member "uid" capture.payload
                      = str "execution-uid-42")
                     "receipt did not survive cleanup/restart")
                !committed_execution;
              if capture_failure || close_receiver || not expect_event
              then (
                match
                  E.seal
                    reopened
                    ~obligations
                    ~requests:(List.map D.plan (D.instances obligations))
                    ~verdicts:[]
                    ~captures:[]
                with
                | Error _ -> ()
                | Ok _ -> Alcotest.fail "missing execution evidence sealed"));
         scan root))
;;

let stalled_channel () =
  let left, right = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close left;
      Unix.close right)
    (fun () ->
       Unix.setsockopt_int left Unix.SO_SNDBUF 1024;
       let now = Unix.gettimeofday () in
       let result =
         M.send
           left
           (M.Execution
              { binding = String.make 64 'b'
              ; target = String.make 6000 't'
              ; namespace = "db"
              ; name = "job"
              ; uid = "uid"
              ; principal = "principal"
              ; cluster = "uid"
              ; endpoint = "https://cluster"
              ; observed_at = 0
              })
       in
       check (Unix.gettimeofday () -. now < 7.) "stalled peer blocked past deadline";
       match result with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "stalled channel accepted full message")
;;

let protocol_rejects_malformed () =
  let receipt : M.receipt =
    { binding = String.make 64 'b'
    ; target = "aws.staging"
    ; namespace = "db"
    ; name = "job"
    ; uid = "uid"
    ; principal = "reader"
    ; cluster = "cluster"
    ; endpoint = "https://endpoint"
    ; observed_at = 1
    }
  in
  check
    (M.decode (M.encode (M.Execution receipt)) = Ok (M.Execution receipt))
    "receipt roundtrip";
  check (M.decode (M.encode M.Unavailable) = Ok M.Unavailable) "unavailable roundtrip";
  let valid = Yojson.Safe.from_string (M.encode (M.Execution receipt)) in
  let reject input =
    match M.decode input with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "malformed protocol accepted"
  in
  List.iter
    (fun j -> reject (Yojson.Safe.to_string j))
    [ set "schema" (`Int 2) valid
    ; set "uid" (str "") valid
    ; set "binding" (str "another-assessment") valid
    ; set "secret" (str "PRIVATE") valid
    ];
  reject "{\"schema\":1,\"schema\":1,\"kind\":\"Unavailable\"}"
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
        ; ( "product API receipt precedes independent capture and cleanup"
          , `Quick
          , product_execution Fun.id )
        ; ( "missing API UID stays unestablished"
          , `Quick
          , product_execution ~expect_event:false (set "missing_uid" (`Bool true)) )
        ; ( "wrong submission namespace stays unestablished"
          , `Quick
          , product_execution
              ~expect_event:false
              (set "wrong_submission_namespace" (`Bool true)) )
        ; ( "failed submission permits cleanup without receipt"
          , `Quick
          , product_execution
              ~expect_event:false
              ~expect_exit:1
              (set "apply_error" (`Bool true)) )
        ; ( "closed receiver does not kill migration or cleanup"
          , `Quick
          , product_execution ~close_receiver:true Fun.id )
        ; ( "capture unavailable still permits normal cleanup"
          , `Quick
          , product_execution ~capture_failure:true Fun.id )
        ; "stalled receipt peer respects deadline", `Quick, stalled_channel
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
        ; ( "submission authority rotation cannot emit execution receipt"
          , `Quick
          , product_execution
              ~expect_event:false
              (set
                 "after_whoami"
                 (set
                    "status"
                    (obj [ "userInfo", obj [ "username", str "another" ] ])
                    whoami)) )
        ; ( "actual migrate CLI emits canonical full target"
          , `Quick
          , product_execution ~cli:true Fun.id )
        ; "strict metadata protocol", `Quick, protocol_rejects_malformed
        ; ( "real process timeout"
          , `Quick
          , fun () -> direct (set "sleep" (`Bool true)) ignore unreadable )
        ] )
    ]
;;
