(* Temporary migration comparison: no production library depends on this module.
   Invoke real extracted Bash predicates, never copied/reimplemented predicates. *)
module D = Qual_domain
module E = Qual_evidence
module K = Qual_kubernetes
module C = Qual_database_ca
module R = Sol_cli_database_setup_render
module M = Sol_cli_manifest_cluster_env
module N = Sol_cli_kubernetes_name

let get = function
  | Ok x -> x
  | Error e -> Alcotest.fail e
;;

let stored = function
  | Ok x -> x
  | Error (e : E.error) -> Alcotest.fail (e.stage ^ ": " ^ e.diagnostic)
;;

let field name = Yojson.Safe.Util.member name
let str = Yojson.Safe.Util.to_string
let list = Yojson.Safe.Util.to_list

let set key value = function
  | `Assoc xs -> `Assoc ((key, value) :: List.remove_assoc key xs)
  | _ -> Alcotest.fail "expected object"
;;

let rec at keys fn value =
  match keys with
  | [] -> fn value
  | key :: rest -> set key (at rest fn (field key value)) value
;;

let strings xs = `List (List.map (fun s -> `String s) xs)
let root = Unix.realpath (Sys.getenv "I4_REPO_ROOT")
let path relative = Filename.concat root relative

let scenario = function
  | "aws" -> D.Aws
  | "gcp" -> D.Gcp
  | _ -> assert false
;;

let target provider = "comparison/" ^ provider ^ "/region"

let identity provider =
  R.database_identity ~workspace:"pluto" ~target:(target provider) ~resource:"app_db"
;;

let principal provider : D.kube_target =
  { principal = provider ^ ":fixture-reader"
  ; cluster = provider ^ "-fixture"
  ; endpoint = "https://" ^ provider ^ ".invalid"
  }
;;

let read_context provider : D.read_context =
  { target = principal provider
  ; verified_at = 100
  ; started_at = 101
  ; finished_at = 102
  ; expires_at = Some 400
  }
;;

let selected = function
  | "aws" ->
    [ "checkout_svc"; "charge_svc"; "notify_worker"; "orders_svc"; "fulfilment_worker" ]
  | "gcp" -> [ "orders_svc"; "fulfilment_worker"; "order_svc"; "fulfillment_worker" ]
  | _ -> assert false
;;

let declared =
  match Sol_cli_config.load_declared ~root:(path "examples/pluto") with
  | Ok declared -> declared
  | Error error -> Alcotest.fail (Sol_cli_config.error_to_string error)
;;

let service name =
  List.find (fun (s : Sol_cli_config.service) -> s.name = name) declared.services
;;

let domain (s : Sol_cli_config.service) =
  match s.path with
  | Some value ->
    (match String.split_on_char '/' value with
     | [ "app"; domain; _ ] -> domain
     | _ -> Alcotest.fail "fixture path must declare domain")
  | None -> Alcotest.fail "fixture requires declared path"
;;

let namespace service =
  N.namespace_of_parts ~workspace:"pluto" ~domain:(domain service)
  |> get
  |> N.namespace_to_string
;;

let workload (s : Sol_cli_config.service) =
  N.k8s_name_of_source s.name |> get |> N.k8s_name_to_string
;;

let consumers provider =
  List.map service (selected provider)
  |> List.filter (fun s -> List.mem "app_db" s.Sol_cli_config.uses)
;;

let metadata ~namespace ~name =
  `Assoc
    [ "namespace", `String namespace
    ; "name", `String name
    ; "uid", `String ("fixture-" ^ name)
    ; "resourceVersion", `String "42"
    ]
;;

let deployment provider (service : Sol_cli_config.service) =
  let name = workload service in
  `Assoc
    [ "apiVersion", `String "apps/v1"
    ; "kind", `String "Deployment"
    ; "metadata", metadata ~namespace:(namespace service) ~name
    ; ( "spec"
      , `Assoc
          [ ( "template"
            , `Assoc
                [ ( "spec"
                  , `Assoc
                      [ ( "volumes"
                        , `List
                            [ `Assoc
                                [ "name", `String M.db_ca_volume
                                ; ( "configMap"
                                  , `Assoc
                                      [ ( "name"
                                        , `String
                                            (R.ca_configmap_name
                                               (identity provider).target) )
                                      ] )
                                ]
                            ] )
                      ; ( "containers"
                        , `List
                            [ `Assoc
                                [ "name", `String "application"
                                ; ( "volumeMounts"
                                  , `List
                                      [ `Assoc
                                          [ "name", `String M.db_ca_volume
                                          ; "mountPath", `String M.db_ca_mount_path
                                          ]
                                      ] )
                                ]
                            ] )
                      ] )
                ] )
          ] )
    ]
;;

let configmap provider namespace =
  `Assoc
    [ "apiVersion", `String "v1"
    ; "kind", `String "ConfigMap"
    ; ( "metadata"
      , metadata ~namespace ~name:(R.ca_configmap_name (identity provider).target) )
    ; "data", `Assoc [ M.db_ca_file_name, `String "fixture CA bytes" ]
    ]
;;

let resource kind namespace name obj =
  `Assoc
    [ "resource", `String kind
    ; "namespace", `String namespace
    ; "name", `String name
    ; "object", obj
    ]
;;

let workload_json s =
  `Assoc
    [ "id", `String s.Sol_cli_config.name
    ; "namespace", `String (namespace s)
    ; "name", `String (workload s)
    ; ("database", if List.mem "app_db" s.uses then `String "app_db" else `Null)
    ; ( "consuming_containers"
      , if List.mem "app_db" s.uses then strings [ "application" ] else strings [] )
    ]
;;

let intent provider =
  `Assoc
    [ ( "databases"
      , `List
          [ `Assoc
              [ "id", `String "app_db"
              ; "ca_configmap", `String (R.ca_configmap_name (identity provider).target)
              ; ( "migration"
                , `Assoc
                    [ "namespace", `String (R.database_namespace (identity provider))
                    ; "container", `String M.migration_container_name
                    ; ( "configmap"
                      , `String (R.ca_configmap_name (identity provider).target) )
                    ] )
              ; ( "administrative_secret"
                , `Assoc
                    [ "namespace", `String (R.database_namespace (identity provider))
                    ; "name", `String (R.authority_name (identity provider).target)
                    ] )
              ]
          ] )
    ; ( "workloads"
      , `List (List.map (fun name -> workload_json (service name)) (selected provider)) )
    ]
;;

let contract =
  `Assoc
    [ "schema", `Int 1
    ; "ca_key", `String M.db_ca_file_name
    ; "ca_path", `String M.db_ca_file
    ; "credential_key", `String R.postgres_url_key
    ; "dml_class", `String R.dml_class
    ; "capabilities", strings [ "ca"; "dml"; "tls" ]
    ]
;;

let base_world provider =
  let id = identity provider in
  let namespaces =
    List.map (fun name -> namespace (service name)) (selected provider)
    |> List.sort_uniq compare
  in
  let all_namespaces = List.sort_uniq compare (R.database_namespace id :: namespaces) in
  let resources =
    List.map
      (fun name ->
         let s = service name in
         resource "Deployment" (namespace s) (workload s) (deployment provider s))
      (selected provider)
    @ List.map
        (fun ns ->
           resource "ConfigMap" ns (R.ca_configmap_name id.target) (configmap provider ns))
        all_namespaces
    @ [ resource
          "Secret"
          (R.database_namespace id)
          (R.ddl_creds_name id.target)
          (`Assoc [])
      ]
    @ List.map
        (fun ns -> resource "Secret" ns (R.dml_creds_name id.target) (`Assoc []))
        namespaces
    @ [ resource
          "Secret"
          "pluto-payments"
          (if provider = "aws" then "charge-svc-secrets" else "orders-svc-secrets")
          (`Assoc [ "data", `Assoc [] ])
      ]
  in
  resources
;;

let map_resource kind predicate fn resources =
  List.map
    (fun r -> if field "resource" r = `String kind && predicate r then fn r else r)
    resources
;;

let order_resource r = field "name" r = `String (workload (service "orders_svc"))
let orders_namespace = namespace (service "orders_svc")

let mutate_deployment fn =
  map_resource
    "Deployment"
    order_resource
    (at [ "object"; "spec"; "template"; "spec" ] fn)
;;

let app fn =
  at [ "containers" ] (function
    | `List [ c ] -> `List [ fn c ]
    | _ -> assert false)
;;

let volume fn = at [ "volumes" ] (fun xs -> `List (List.map fn (list xs)))
let mount fn = app (at [ "volumeMounts" ] (fun xs -> `List (List.map fn (list xs))))
let consumer_ca r = field "namespace" r = `String orders_namespace

let erase kind predicate resources =
  List.filter (fun r -> not (field "resource" r = `String kind && predicate r)) resources
;;

let failure code message r = r |> set "code" (`Int code) |> set "stderr" (`String message)
let omit_orders = List.filter (( <> ) "orders_svc")

type case =
  { name : string
  ; legacy_aws : bool
  ; legacy_gcp : bool
  ; i3 : string
  ; category : string
  ; change : string -> Yojson.Safe.t list -> Yojson.Safe.t list
  ; selection : bool
  ; empty : bool
  ; bad_binding : bool
  ; wrong_identity : bool
  }

let case
      ?(aws = true)
      ?(gcp = true)
      ?(i3 = "PASS")
      ?(category = "stronger")
      ?(selection = false)
      ?(empty = false)
      ?(bad_binding = false)
      ?(wrong_identity = false)
      name
      change
  =
  { name
  ; legacy_aws = aws
  ; legacy_gcp = gcp
  ; i3
  ; category
  ; change
  ; selection
  ; empty
  ; bad_binding
  ; wrong_identity
  }
;;

let unchanged _ resources = resources

let cases =
  [ case ~category:"baseline" "baseline" unchanged
  ; case ~aws:false ~i3:"UNKNOWN" ~category:"preserved" "consumer-ca-absent" (fun _ ->
      erase "ConfigMap" consumer_ca)
  ; case ~aws:false ~i3:"UNKNOWN" ~category:"preserved" "consumer-ca-forbidden" (fun _ ->
      map_resource
        "ConfigMap"
        consumer_ca
        (failure 1 "Error from server (Forbidden): denied"))
  ; case ~aws:false ~i3:"UNKNOWN" ~category:"preserved" "deployment-unreadable" (fun _ ->
      map_resource "Deployment" order_resource (failure 124 "timeout"))
  ; case ~aws:false ~i3:"UNKNOWN" ~category:"preserved" "deployment-malformed" (fun _ ->
      map_resource "Deployment" order_resource (set "stdout" (`String "invalid JSON")))
  ; case
      ~aws:false
      ~i3:"FAIL"
      ~category:"preserved"
      "one-of-several-wrong-volume-source"
      (fun _ ->
         mutate_deployment
           (volume (set "configMap" (`Assoc [ "name", `String "another-ca" ]))))
  ; case
      ~aws:false
      ~i3:"FAIL"
      ~category:"preserved"
      "one-of-several-no-ca-volume"
      (fun _ -> mutate_deployment (set "volumes" (`List [])))
  ; case
      ~aws:false
      ~i3:"REFUSED"
      ~category:"preserved"
      ~empty:true
      "empty-exercise"
      unchanged
  ; case
      ~aws:false
      ~i3:"REFUSED"
      ~category:"preserved"
      ~bad_binding:true
      "missing-ca-declaration"
      unchanged
  ; case ~i3:"FAIL" "wrong-ca-key" (fun _ ->
      map_resource
        "ConfigMap"
        consumer_ca
        (at [ "object" ] (set "data" (`Assoc [ "ca.crt", `String "wrong key" ]))))
  ; case ~i3:"FAIL" "empty-ca-key" (fun _ ->
      map_resource
        "ConfigMap"
        consumer_ca
        (at [ "object" ] (set "data" (`Assoc [ M.db_ca_file_name, `String "" ]))))
  ; case ~i3:"UNKNOWN" "wrong-configmap-object-identity" (fun _ ->
      map_resource
        "ConfigMap"
        consumer_ca
        (at [ "object"; "metadata" ] (set "name" (`String "other-ca"))))
  ; case ~i3:"UNKNOWN" "wrong-configmap-namespace" (fun _ ->
      map_resource
        "ConfigMap"
        consumer_ca
        (at [ "object"; "metadata" ] (set "namespace" (`String "migration-only"))))
  ; case ~i3:"UNKNOWN" "malformed-configmap-success" (fun _ ->
      map_resource "ConfigMap" consumer_ca (set "stdout" (`String "not-json")))
  ; case ~i3:"UNKNOWN" "successful-empty-configmap-output" (fun _ ->
      map_resource "ConfigMap" consumer_ca (set "stdout" (`String "")))
  ; case ~i3:"UNKNOWN" "wrong-deployment-namespace" (fun _ ->
      map_resource
        "Deployment"
        order_resource
        (at [ "object"; "metadata" ] (set "namespace" (`String "other"))))
  ; case ~i3:"FAIL" "redirected-mount" (fun _ ->
      mutate_deployment (mount (set "mountPath" (`String "/elsewhere"))))
  ; case ~i3:"FAIL" "sidecar-only-mount" (fun _ ->
      mutate_deployment (app (set "name" (`String "sidecar"))))
  ; case ~i3:"FAIL" "unmounted-ca-volume" (fun _ ->
      mutate_deployment (app (set "volumeMounts" (`List []))))
  ; case ~i3:"FAIL" "wrong-key-projection" (fun provider ->
      mutate_deployment
        (volume
           (set
              "configMap"
              (`Assoc
                  [ "name", `String (R.ca_configmap_name (identity provider).target)
                  ; "items", `List []
                  ]))))
  ; case ~i3:"UNKNOWN" ~selection:true "selector-omits-missing-consumer" (fun _ ->
      erase "Deployment" order_resource)
  ; case
      ~aws:false
      ~i3:"UNKNOWN"
      ~category:"preserved"
      "configmap-command-not-found"
      (fun _ ->
         map_resource "ConfigMap" consumer_ca (failure 127 "exec: kubectl unavailable"))
  ; case
      ~aws:false
      ~i3:"UNKNOWN"
      ~category:"preserved"
      "ca-only-in-migration-namespace"
      (fun provider ->
         erase "ConfigMap" (fun r ->
           field "namespace" r <> `String (R.database_namespace (identity provider))))
  ; case ~i3:"UNKNOWN" "wrong-deployment-name" (fun _ ->
      map_resource
        "Deployment"
        order_resource
        (at [ "object"; "metadata" ] (set "name" (`String "neighbour"))))
  ; case ~i3:"FAIL" "shadowed-ca-mount" (fun _ ->
      mutate_deployment
        (app
           (at [ "volumeMounts" ] (fun mounts ->
              `List
                (list mounts
                 @ [ `Assoc
                       [ "name", `String "shadow"; "mountPath", `String M.db_ca_file ]
                   ])))))
  ; case ~i3:"UNKNOWN" ~wrong_identity:true "wrong-observation-identity" unchanged
  ; case
      ~aws:false
      ~i3:"PASS"
      ~category:"adoption-gap"
      "migration-namespace-ca-absent"
      (fun provider ->
         erase "ConfigMap" (fun r ->
           field "namespace" r = `String (R.database_namespace (identity provider))))
  ; case
      ~aws:false
      ~i3:"PASS"
      ~category:"adoption-gap"
      "valid-ca-through-renamed-volume"
      (fun _ ->
         mutate_deployment (fun spec ->
           spec
           |> volume (set "name" (`String "another-volume"))
           |> mount (set "name" (`String "another-volume"))))
  ; case
      ~aws:false
      ~i3:"PASS"
      ~category:"not-applicable"
      "nonconsumer-without-ca"
      (fun _ ->
         map_resource
           "Deployment"
           (fun r -> field "name" r = `String (workload (service "checkout_svc")))
           (at [ "object"; "spec"; "template"; "spec" ] (set "volumes" (`List []))))
  ; case
      ~aws:false
      ~gcp:false
      ~i3:"PASS"
      ~category:"credential-control"
      "ddl-secret-absent"
      (fun provider ->
         erase "Secret" (fun r ->
           field "name" r = `String (R.ddl_creds_name (identity provider).target)))
  ; case
      ~aws:false
      ~gcp:false
      ~i3:"PASS"
      ~category:"credential-control"
      "dml-secrets-absent"
      (fun provider ->
         erase "Secret" (fun r ->
           field "name" r = `String (R.dml_creds_name (identity provider).target)))
  ; case ~i3:"FAIL" "redirected-key-projection" (fun provider ->
      mutate_deployment
        (volume
           (set
              "configMap"
              (`Assoc
                  [ "name", `String (R.ca_configmap_name (identity provider).target)
                  ; ( "items"
                    , `List
                        [ `Assoc
                            [ "key", `String M.db_ca_file_name
                            ; "path", `String "elsewhere.pem"
                            ]
                        ] )
                  ]))))
  ]
;;

let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR
  then (
    Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path
;;

let mkdir path = Unix.mkdir path 0o700

let write path value =
  let c = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out c) (fun () -> output_string c value)
;;

let read path =
  let c = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in c)
    (fun () -> really_input_string c (in_channel_length c))
;;

let temporary fn =
  let dir = Filename.temp_file "sol-qual-i4-" ".test" in
  Unix.unlink dir;
  mkdir dir;
  Fun.protect ~finally:(fun () -> remove dir) (fun () -> fn dir)
;;

let process dir ~env program args =
  let output = Filename.concat dir "process.stdout"
  and errors = Filename.concat dir "process.stderr" in
  let fd path = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let out = fd output
  and err = fd errors
  and input = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let pid =
    Unix.create_process_env
      program
      (Array.of_list (program :: args))
      (Array.of_list env)
      input
      out
      err
  in
  List.iter Unix.close [ input; out; err ];
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED n -> n
    | _ -> Alcotest.fail "fixture transport interrupted"
  in
  code, read output, read errors
;;

let prepare dir provider test =
  let bin = Filename.concat dir "bin" in
  mkdir bin;
  List.iter
    (fun name -> Unix.symlink ("/usr/bin/" ^ name) (Filename.concat bin name))
    [ "grep"; "tail"; "tr"; "sed"; "head"; "sort"; "cut"; "jq" ];
  Unix.symlink
    (path "internal/tooling/sol_qualification/test/comparison/kubectl")
    (Filename.concat bin "kubectl");
  let workspace = Filename.concat dir "workspace" in
  mkdir workspace;
  mkdir (workspace ^ "/app");
  let domains =
    List.map (fun name -> domain (service name)) (selected provider)
    |> List.sort_uniq compare
  in
  List.iter (fun domain -> mkdir (workspace ^ "/app/" ^ domain)) domains;
  List.iter
    (fun name ->
       let s = service name in
       let d = workspace ^ "/" ^ Option.get s.path in
       mkdir d;
       write (d ^ "/Dockerfile") "# offline path discovery only\n")
    (selected provider);
  mkdir (dir ^ "/logs");
  let report = R.database_identity_report (identity provider) in
  let report =
    if test.bad_binding
    then
      String.split_on_char ' ' report
      |> List.filter (fun x -> not (String.starts_with ~prefix:"ca-configmap=" x))
      |> String.concat " "
    else report
  in
  write (dir ^ "/logs/app-deploy.log") (report ^ "\n");
  let names =
    if test.empty
    then []
    else if test.selection
    then omit_orders (selected provider)
    else selected provider
  in
  let env =
    `Assoc
      [ "TARGET", `String (target provider)
      ; "APP_UNITS", `String (String.concat " " names)
      ; "APP_NS", `String "pluto-payments"
      ; "APP_SERVICE", `String "charge-svc"
      ; "DECLARED_NS", `String (R.database_namespace (identity provider))
      ]
  in
  let world =
    `Assoc
      [ "resources", `List (test.change provider (base_world provider))
      ; ( "legacy"
        , `Assoc
            [ "ca_only", `Bool (test.empty || test.bad_binding)
            ; "default_units", strings (selected provider)
            ; "env", env
            ] )
      ]
  in
  Yojson.Safe.to_file (dir ^ "/world.json") world
;;

let calls path =
  if not (Sys.file_exists path)
  then []
  else
    read path
    |> String.split_on_char '\n'
    |> List.filter (( <> ) "")
    |> List.map Yojson.Safe.from_string
;;

let assert_transport calls =
  List.iter
    (fun call ->
       if field "unsupported" call <> `Null || field "resource" call = `Null
       then Alcotest.fail ("unsupported query: " ^ Yojson.Safe.to_string call))
    calls
;;

let run_i3 dir provider test =
  let contract =
    if test.bad_binding then set "ca_key" (`String "") contract else contract
  in
  let intent =
    if test.empty then set "workloads" (`List []) (intent provider) else intent provider
  in
  let binding =
    D.Fixture.bind
      ~scenario:(scenario provider)
      ~attempt:"i4-fixture"
      ~assessment:"comparison"
      ~candidate_revision:(String.make 40 'a')
      ~specimen:(provider ^ "-fixture")
      ~kubernetes:(principal provider)
      ~contract
  in
  let bind () =
    let run = binding |> get in
    let selection = D.select run (D.Fixture.intent intent |> get) |> get in
    let obligations = D.bind_obligations run (scenario provider) selection |> get in
    run, obligations
  in
  (* Expected refusals are kept separate from assertion failures and subprocess failures. *)
  if test.bad_binding
  then (
    match binding with
    | Error _ -> "REFUSED"
    | Ok _ -> Alcotest.fail "invalid contract accepted")
  else if test.empty
  then (
    let run = binding |> get in
    match D.select run (D.Fixture.intent intent |> get) with
    | Error _ -> "REFUSED"
    | Ok _ -> Alcotest.fail "empty database universe accepted")
  else (
    let run, obligations = bind () in
    Alcotest.(check int)
      "independent canonical consumer count"
      4
      (List.length (consumers provider));
    let directory = dir ^ "/evidence" in
    let recorder = E.open_store ~directory ~run ~secrets:[] () |> stored in
    Fun.protect
      ~finally:(fun () -> E.close recorder)
      (fun () ->
         ignore
           (E.start_assessment
              recorder
              ~reason:"temporary offline legacy comparison"
              ~previous:[]
              ~required_captures:[]
            |> stored);
         let transport q =
           let resource =
             match q.K.resource with
             | K.Job ->
               Alcotest.fail "application comparison unexpectedly requested migration Job"
             | K.Deployment -> "deploy"
             | K.Configmap -> "configmap"
           in
           let env =
             [ "PATH=" ^ dir ^ "/bin"
             ; "HOME=" ^ dir
             ; "I4_WORLD=" ^ dir ^ "/world.json"
             ; "I4_CALLS=" ^ dir ^ "/i3-calls.jsonl"
             ]
           in
           let code, stdout, stderr =
             process
               dir
               ~env
               (dir ^ "/bin/kubectl")
               [ "get"; resource; q.name; "-n"; q.namespace; "-o"; "json" ]
           in
           let context = read_context provider in
           let context =
             if test.wrong_identity
             then
               { context with
                 target = { context.target with principal = "another-reader" }
               }
             else context
           in
           K.{ context; result = Exited { code; stdout; stderr } }
         in
         let outcomes =
           C.observe_all ~directory ~run ~obligations ~recorder ~read:transport |> get
         in
         Alcotest.(check int)
           "one persisted assessment per expected CA consumer"
           4
           (List.length outcomes);
         let verdicts =
           List.map (fun (o : C.outcome) -> (o.result |> stored).verdict) outcomes
         in
         let observations = calls (dir ^ "/i3-calls.jsonl") in
         assert_transport observations;
         Alcotest.(check int)
           "two reads per expected consumer"
           8
           (List.length observations);
         List.iter
           (fun s ->
              Alcotest.(check bool)
                ("observed " ^ s.Sol_cli_config.name)
                true
                (List.exists
                   (fun q ->
                      field "resource" q = `String "Deployment"
                      && field "name" q = `String (workload s)
                      && field "namespace" q = `String (namespace s))
                   observations))
           (consumers provider);
         if
           List.exists
             (fun v ->
                match v.D.decision with
                | D.Unknown _ -> true
                | _ -> false)
             verdicts
         then "UNKNOWN"
         else if List.for_all (fun v -> v.D.decision = D.Pass) verdicts
         then "PASS"
         else "FAIL"))
;;

let compare provider test () =
  temporary (fun dir ->
    prepare dir provider test;
    let source =
      path
        (if provider = "aws"
         then "internal/qualification/aws/live-row.sh"
         else "internal/qualification/gcp/live-qual.sh")
    in
    let status, stdout, stderr =
      process
        dir
        ~env:[]
        "/usr/bin/python3"
        [ path "internal/tooling/sol_qualification/test/comparison/legacy.py"
        ; source
        ; provider
        ; dir ^ "/world.json"
        ; dir
        ]
    in
    Alcotest.(check int) ("driver must execute, stderr=" ^ stderr) 0 status;
    let result = Yojson.Safe.from_string stdout in
    let legacy = field "status" result = `Int 0 in
    let expected = if provider = "aws" then test.legacy_aws else test.legacy_gcp in
    Alcotest.(check bool)
      ("actual legacy predicate: " ^ Yojson.Safe.to_string result)
      expected
      legacy;
    if test.name = "baseline"
    then (
      let expected =
        if provider = "aws"
        then
          List.map
            (fun name ->
               let s = service name in
               domain s ^ "/" ^ s.name)
            (selected provider)
        else selected provider
      in
      let actual = field "selected" result |> list |> List.map str in
      Alcotest.(check (list string))
        "actual legacy specimen membership"
        (List.sort compare expected)
        (List.sort compare actual));
    let observed = calls (dir ^ "/legacy-calls.jsonl") in
    assert_transport observed;
    if provider = "gcp"
    then
      Alcotest.(check bool)
        "GCP credential gate has no CA observation"
        false
        (List.exists
           (fun q ->
              field "resource" q = `String "Deployment"
              || field "resource" q = `String "ConfigMap")
           observed);
    if test.name = "baseline" && provider = "aws"
    then
      Alcotest.(check int)
        "actual AWS default selects five workloads, including nonconsumer"
        5
        (List.length
           (List.filter (fun q -> field "resource" q = `String "Deployment") observed));
    let actual = run_i3 dir provider test in
    Alcotest.(check string) "I3 classification" test.i3 actual;
    Printf.printf
      "comparison %s/%s: legacy=%s I3=%s [%s] source=%s\n%!"
      provider
      test.name
      (if legacy then "accept" else "reject")
      actual
      test.category
      (str (field "source_sha256" result)))
;;

let transport_rejects_unsupported () =
  temporary (fun dir ->
    prepare dir "aws" (List.hd cases);
    let queries =
      [ [ "get"; "configmap"; "x"; "-n"; "ns"; "-o"; "yaml" ]
      ; [ "get"; "secret"; "x"; "-n"; "ns"; "-o"; "jsonpath={.data.other}" ]
      ; [ "get"; "configmap"; "x"; "-n"; "ns"; "ignored" ]
      ; [ "get"; "configmap"; "x"; "-n"; "ns"; "--bad"; "json" ]
      ; [ "get"; "namespace"; "x"; "-n"; "ns" ]
      ; [ "apply"; "configmap"; "x"; "-n"; "ns" ]
      ]
    in
    List.iter
      (fun args ->
         let status, _, _ =
           process
             dir
             ~env:
               [ "I4_WORLD=" ^ dir ^ "/world.json"
               ; "I4_CALLS=" ^ dir ^ "/unsupported.jsonl"
               ]
             (dir ^ "/bin/kubectl")
             args
         in
         Alcotest.(check int) "unsupported transport is not provider absence" 126 status)
      queries;
    let records = calls (dir ^ "/unsupported.jsonl") in
    Alcotest.(check int)
      "every unsupported branch logged"
      (List.length queries)
      (List.length records);
    List.iter
      (fun record ->
         Alcotest.(check bool)
           "comparison recognizes unsupported query"
           true
           (field "unsupported" record <> `Null))
      records)
;;

let () =
  Alcotest.run
    "Temporary offline CA migration comparison"
    (( "transport"
     , [ Alcotest.test_case
           "unsupported queries fail comparison"
           `Quick
           transport_rejects_unsupported
       ] )
     :: List.map
          (fun provider ->
             ( provider
             , List.map
                 (fun test -> Alcotest.test_case test.name `Quick (compare provider test))
                 cases ))
          [ "aws"; "gcp" ])
;;
