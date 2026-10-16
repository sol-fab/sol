module C = Sol_cli_database_contract
module P = Sol_cli_deployment_plan
module R = Sol_cli_database_setup_render
module J = Sol_cli_json

let get = function
  | Ok x -> x
  | Error message -> Windtrap.fail message
;;

let field name = Yojson.Safe.Util.member name
let str = Yojson.Safe.Util.to_string
let list = Yojson.Safe.Util.to_list

let set key value = function
  | `Assoc xs -> `Assoc ((key, value) :: List.remove_assoc key xs)
  | _ -> assert false
;;

let rec at keys fn value =
  match keys with
  | [] -> fn value
  | key :: rest -> set key (at rest fn (field key value)) value
;;

let check msg value = Windtrap.equal Windtrap.bool ~msg true value
let revision = String.make 40 'a'
let definition () = C.definition ~revision |> get
let target provider = "dev/" ^ provider ^ "/region"

let services =
  [ "payments", "charge_svc", "http", true
  ; "comms", "notify_worker", "worker", true
  ; "reports", "report_fn", "function", true
  ; "checkout", "checkout_svc", "http", false
  ]
;;

let write path value = Out_channel.with_open_text path (fun c -> output_string c value)

let with_workspace ?(omission = "") provider fn =
  let root = Filename.temp_dir "sol-contract-" "" in
  let old = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () ->
      Sys.chdir old;
      ignore (Sol_cli_fs.remove_tree root))
    (fun () ->
       Sys.chdir root;
       let declarations =
         List.map
           (fun (domain, name, typ, uses) ->
              Targets_fixture.mkdir_p ("app/" ^ domain ^ "/" ^ name);
              write ("app/" ^ domain ^ "/" ^ name ^ "/Dockerfile") "FROM scratch\n";
              write
                ("app/" ^ domain ^ "/" ^ name ^ "/sol.toml")
                ((if typ = "function" then "[service]\nschedule = \"0 * * * *\"\n" else "")
                 ^ "[infra.env]\nconfig = {PRIVATE_MARKER = \"fixture-secret\"}\n");
              Printf.sprintf
                "  %s:\n    type: %s\n    path: app/%s/%s\n%s%s"
                name
                typ
                domain
                name
                (if uses then "    uses: [app_db]\n" else "")
                (if name = "notify_worker"
                 then "    language: typescript\n"
                 else "    language: ocaml\n"))
           services
       in
       write
         "sol.yml"
         ("project: fixture\nresources:\n  app_db:\n    type: postgres\nservices:\n"
          ^ String.concat "" declarations);
       Targets_fixture.write
         ~target:(target provider)
         ("shape: durable\nregistry: registry.invalid\nsecrets:\n"
          ^ String.concat
              ""
              (List.map
                 (fun (domain, name, _, _) ->
                    Printf.sprintf
                      "  %s/%s:\n\
                      \    KAFKA_SASL_PASSWORD:\n\
                      \      authority: sol\n\
                      \    KAFKA_SSL_CA_CERT:\n\
                      \      authority: sol\n"
                      domain
                      name)
                 services)
          ^ omission);
       let config =
         Sol_cli_config.load_for_target ~target:(target provider)
         |> Result.map_error Sol_cli_config.error_to_string
         |> get
       in
       let facts = Sol_cli_workspace_model.load ~root |> get in
       fn root config facts)
;;

let project provider config facts =
  C.project ~definition:(definition ()) ~requested_target:(target provider) ~config ~facts
  |> get
  |> C.projection_json
  |> field "declaration"
;;

let independently_plan config facts =
  let inventory = Sol_cli_workspace_model.services facts in
  let selected = Sol_cli_deploy_selection.select ~image_refs:[] inventory |> get in
  let selected =
    Sol_cli_deploy_selection.apply_target
      ~target:config.Sol_cli_config.target.name
      ~config
      selected
    |> get
  in
  Sol_cli_deploy_selection.target_plan
    { workspace =
        Sol_cli_workspace.workspace_name ~root:facts.Sol_cli_workspace_model.root
    ; registry = "registry.invalid"
    ; sha = "render-test"
    ; emit_to = None
    ; config
    ; facts
    ; inventory
    ; image_refs = []
    ; services = selected.services
    }
  |> Result.map_error (function
    | Sol_cli_deploy_selection.Refused s -> s
    | Preflight (p, f) -> Sol_cli_profile_preflight.report p f)
  |> get
  |> Sol_cli_deploy_selection.Target_plan.to_deployment_plan
;;

let rec json : Yaml.value -> Yojson.Safe.t = function
  | `O fields -> `Assoc (List.map (fun (k, v) -> k, json v) fields)
  | `A values -> `List (List.map json values)
  | `String s -> `String s
  | `Bool b -> `Bool b
  | `Null -> `Null
  | `Float f -> `Float f
;;

let documents text =
  Str.split (Str.regexp "^---\n") text
  |> List.filter (fun s -> String.trim s <> "")
  |> List.map (fun text ->
    match Yaml.of_string text with
    | Ok value -> json value
    | Error (`Msg message) -> Windtrap.fail message)
;;

let rendered ~plan spec =
  let bundle =
    Sol_cli_deployment_render.render_spec
      ~workspace:plan.P.workspace
      ~release_id:plan.release_id
      spec
    |> get
  in
  documents bundle.Sol_cli_manifest.workload_yaml
  |> List.find (fun doc ->
    List.mem
      (field "kind" doc)
      [ `String "Deployment"; `String "CronJob"; `String "Rollout" ])
;;

let pod doc =
  J.field
    (if field "kind" doc = `String "CronJob"
     then [ "spec"; "jobTemplate"; "spec"; "template"; "spec" ]
     else [ "spec"; "template"; "spec" ])
    doc
;;

let delivery_matches expected doc =
  let ca = field "ca" expected
  and spec = pod doc in
  let volumes = field "volumes" spec |> list
  and containers = field "containers" spec |> list in
  let metadata = field "metadata" doc in
  let identity =
    field "resource" expected = `String (String.lowercase_ascii (str (field "kind" doc)))
    && field "namespace" expected = field "namespace" metadata
    && field "name" expected = field "name" metadata
  in
  let expected_containers = field "consuming_containers" expected |> list in
  identity
  && List.for_all
       (fun name ->
          match List.find_opt (fun c -> field "name" c = name) containers with
          | None -> false
          | Some container ->
            let credential = field "credential" expected in
            let env = field "env" container |> list in
            let credential_ok =
              List.exists
                (fun env ->
                   field "name" env = `String R.postgres_url_key
                   && J.field [ "valueFrom"; "secretKeyRef"; "name" ] env
                      = field "name" credential
                   && J.field [ "valueFrom"; "secretKeyRef"; "key" ] env
                      = `String R.postgres_url_key)
                env
            in
            let mounts = field "volumeMounts" container |> list in
            credential_ok
            && List.exists
                 (fun mount ->
                    field "readOnly" mount = `Bool true
                    && str (field "mountPath" mount) ^ "/" ^ str (field "key" ca)
                       = str (field "file" ca)
                    && List.exists
                         (fun volume ->
                            field "name" volume = field "name" mount
                            && J.field [ "configMap"; "name" ] volume
                               = J.field [ "configmap"; "name" ] ca)
                         volumes)
                 mounts)
       expected_containers
;;

let test_definition () =
  let d = definition () in
  let expected =
    Yojson.Safe.from_string
      {|{"schema":1,"product_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ca":{"key":"ca.pem","file":"/etc/sol/db-ca/ca.pem"},"credentials":{"key":"POSTGRES_URL","dml_class":"dml","ddl_class":"ddl"},"rendering":{"ca_volume_name":"db-ca","volume_identity":"internal_linkage","migration_container":"migrate"}}|}
  in
  check
    "reviewed complete definition field set and values"
    (Yojson.Safe.equal expected (field "declaration" (C.definition_json d)));
  check "deterministic bytes" (C.definition_json d = C.definition_json (definition ()));
  ignore (C.read_definition (C.definition_json d) |> get);
  List.iter
    (fun mutated ->
       check
         "unsupported/forged declaration refused"
         (Result.is_error (C.read_definition mutated)))
    [ at [ "declaration" ] (set "schema" (`Int 2)) (C.definition_json d)
    ; at [ "declaration"; "ca" ] (set "key" (`String "ca.crt")) (C.definition_json d)
    ; set "digest" (`String (String.make 64 '0')) (C.definition_json d)
    ; `Assoc
        [ "declaration", field "declaration" (C.definition_json d)
        ; "declaration", `Null
        ; "digest", `String (C.digest d)
        ]
    ];
  check
    "different product revision changes identity"
    (C.digest d <> C.digest (C.definition ~revision:(String.make 40 'b') |> get))
;;

let test_render provider () =
  with_workspace provider (fun _ config facts ->
    let projection = project provider config facts in
    let workloads = field "workloads" projection |> list in
    check "all four canonical target members" (List.length workloads = 4);
    check
      "three database consumers including scheduled unit"
      (List.length (List.filter (fun w -> field "database" w <> `Null) workloads) = 3);
    check
      "logical resource identity is not its sanitized Kubernetes spelling"
      (List.for_all
         (fun w ->
            field "database" w = `Null
            || field "database" w = J.field [ "database"; "resource" ] projection)
         workloads);
    let plan = independently_plan config facts in
    List.iter
      (fun spec ->
         let expected =
           List.find
             (fun w -> field "name" w = `String (P.k8s_name_to_string spec.P.k8s_name))
             workloads
         in
         let doc = rendered ~plan spec in
         if spec.db_uses_target = None
         then
           check
             "nonconsumer declared explicitly"
             (field "ca" expected = `Null
              && field "consuming_containers" expected = `List [])
         else (
           check
             "actual rendered workload delivers declaration"
             (delivery_matches expected doc);
           check
             "mutation of projected CA path detected"
             (not
                (delivery_matches
                   (at [ "ca" ] (set "file" (`String "/wrong/ca.pem")) expected)
                   doc));
           let path =
             if field "kind" doc = `String "CronJob"
             then [ "spec"; "jobTemplate"; "spec"; "template"; "spec" ]
             else [ "spec"; "template"; "spec" ]
           in
           let mutated =
             at
               (path @ [ "volumes" ])
               (fun volumes ->
                  `List
                    (List.map
                       (fun volume ->
                          if field "configMap" volume <> `Null
                          then at [ "configMap" ] (set "name" (`String "wrong-ca")) volume
                          else volume)
                       (list volumes)))
               doc
           in
           check
             "mutation of rendered source detected"
             (not (delivery_matches expected mutated));
           let mutated =
             at
               (path @ [ "containers" ])
               (fun containers ->
                  `List (List.map (set "name" (`String "sidecar")) (list containers)))
               doc
           in
           check
             "mutation of consuming container detected"
             (not (delivery_matches expected mutated));
           let ca = field "ca" expected in
           let cm =
             R.ca_configmap_doc
               ~ns:(str (field "namespace" expected))
               ~target:(Option.get spec.db_ca_target)
               ~ca_cert:"fixture CA"
             |> fun doc -> Sol_cli_yaml.render [ doc ] |> documents |> List.hd
           in
           let matches expected cm =
             field "name" (field "configmap" expected) = J.field [ "metadata"; "name" ] cm
             && field "namespace" (field "configmap" expected)
                = J.field [ "metadata"; "namespace" ] cm
             && J.field [ "data"; str (field "key" expected) ] cm = `String "fixture CA"
           in
           check "actual ConfigMap key matches" (matches ca cm);
           check
             "mutation of projected key detected"
             (not (matches (set "key" (`String "ca.crt") ca) cm));
           check
             "mutation of rendered key detected"
             (not
                (matches ca (set "data" (`Assoc [ "ca.crt", `String "fixture CA" ]) cm)))))
      plan.services;
    let id =
      Sol_cli_database_setup_run.identity_of_config ~workspace:plan.workspace config
    in
    let database = field "database" projection in
    let migration = field "migration" database in
    check
      "migration is an independent context"
      (field "context" migration = `String "database_migration");
    let doc =
      Sol_cli_manifest.migration_job_doc
        ~name:"execution-receipt-job"
        ~namespace:(R.database_namespace id)
        ~image:"fixture-runner"
        ~args:[ "apply" ]
        ~configmap_name:"files"
        ~ddl_creds_name:(R.ddl_creds_name id.target)
        ~ca_configmap:(R.ca_configmap_name id.target)
        ()
      |> fun doc -> Sol_cli_yaml.render [ doc ] |> documents |> List.hd
    in
    let spec = pod doc in
    let container = field "containers" spec |> list |> List.hd in
    check
      "migration consuming container matches rendered Job"
      (field "container" migration = field "name" container);
    check
      "migration reads declared DDL Secret"
      (J.field [ "secretRef"; "name" ] (field "envFrom" container |> list |> List.hd)
       = J.field [ "credential"; "name" ] migration);
    let ca = field "ca" migration in
    let migration_matches migration doc =
      let spec = pod doc in
      let container = field "containers" spec |> list |> List.hd in
      let ca = field "ca" migration in
      field "namespace" migration = J.field [ "metadata"; "namespace" ] doc
      && field "container" migration = field "name" container
      && List.exists
           (fun mount ->
              field "readOnly" mount = `Bool true
              && str (field "mountPath" mount) ^ "/" ^ str (field "key" ca)
                 = str (field "file" ca)
              && List.exists
                   (fun volume ->
                      field "name" volume = field "name" mount
                      && J.field [ "configMap"; "name" ] volume
                         = J.field [ "configmap"; "name" ] ca)
                   (field "volumes" spec |> list))
           (field "volumeMounts" container |> list)
    in
    check
      "migration actually mounts declared CA source/file"
      (migration_matches migration doc);
    check
      "migration declaration mutation is detected"
      (not
         (migration_matches
            (at [ "ca" ] (set "file" (`String "/wrong.pem")) migration)
            doc));
    let mutated =
      at
        [ "spec"; "template"; "spec"; "volumes" ]
        (fun volumes ->
           `List
             (List.map
                (fun volume ->
                   if field "configMap" volume <> `Null
                   then at [ "configMap" ] (set "name" (`String "other-ca")) volume
                   else volume)
                (list volumes)))
        doc
    in
    check
      "migration renderer source mutation is detected"
      (not (migration_matches migration mutated));
    let master =
      Sol_cli_database_setup_url.with_tls
        ~sslmode:"verify-full"
        ~ca_cert_path:Sol_cli_manifest_cluster_env.db_ca_file
        "postgresql://admin:fixture-secret@db.invalid/app"
    in
    let dml =
      Sol_cli_database_setup_url.dml ~password:"fixture-dml" master |> Uri.of_string
    in
    check
      "runtime TLS root path agrees with projection"
      (Uri.get_query_param dml "sslrootcert" = Some (str (field "file" ca)));
    check
      "administrative references explicitly declared"
      (List.length (field "administrative_references" database |> list) = 1);
    let refs = field "administrative_references" database |> list in
    let as_object doc = Sol_cli_yaml.render [ doc ] |> documents |> List.hd in
    let authority =
      R.authority_secret_doc
        ~ns:(R.database_namespace id)
        ~target:id.target
        ~state:R.Established
        ~ddl_password:"fixture-ddl"
        ~dml_password:"fixture-dml"
      |> as_object
    in
    let admin =
      R.transient_secret_doc
        ~ns:(R.database_namespace id)
        ~target:id.target
        ~job_uid:"receipt-job-uid"
        ~service_file:"fixture-administrative-input"
        ~ddl_password:"fixture-ddl"
        ~dml_password:"fixture-dml"
      |> as_object
    in
    let matches_reference doc reference =
      field "name" reference = J.field [ "metadata"; "name" ] doc
      && field "namespace" reference = J.field [ "metadata"; "namespace" ] doc
    in
    check
      "password authority has its own rendered non-administrative binding"
      (matches_reference authority (field "credential_authority" database));
    check
      "transient setup master binding matches actual renderer"
      (List.exists (matches_reference admin) refs);
    check
      "runtime input values never appear in declaration"
      (not
         (List.exists
            (fun needle ->
               Sol_cli_string.contains ~needle (Yojson.Safe.to_string projection))
            [ "fixture-ddl"
            ; "fixture-dml"
            ; "fixture-administrative-input"
            ; "fixture-secret"
            ])))
;;

let test_selection () =
  with_workspace
    ~omission:"services:\n  notify_worker:\n    omit: true\n"
    "aws"
    (fun root config facts ->
       let projected = project "aws" config facts in
       check
         "target omission is authoritative"
         (List.length (field "workloads" projected |> list) = 3);
       Unix.unlink (Filename.concat root "app/payments/charge_svc/Dockerfile");
       let facts = Sol_cli_workspace_model.load ~root |> get in
       check
         "missing consumer cannot disappear during discovery"
         (Result.is_error
            (C.project
               ~definition:(definition ())
               ~requested_target:(target "aws")
               ~config
               ~facts)))
;;

let test_external () =
  with_workspace "aws" (fun _ config facts ->
    let external_binding : Sol_cli_config.resource_binding =
      { ownership = Sol_cli_config.Ownership_external
      ; store = Some "external-store"
      ; keys = []
      ; connection = []
      ; credentials = [ R.ddl_class, "external/ddl"; R.dml_class, "external/dml" ]
      }
    in
    let resources =
      List.map
        (fun (resource : Sol_cli_config.resource) ->
           { resource with binding = Some external_binding })
        config.Sol_cli_config.resources
    in
    let config = { config with resources } in
    let declaration = project "aws" config facts in
    let database = field "database" declaration in
    check
      "external ownership is a fact, not policy exemption"
      (field "ownership" database = `String "external");
    check
      "external database declares no invented Sol CA"
      (J.field [ "migration"; "ca" ] database = `Null);
    check
      "external database declares no Sol administrative reference"
      (field "administrative_references" database = `List []);
    check
      "all external DML consumers remain declared"
      (List.length
         (List.filter
            (fun w -> field "database" w <> `Null)
            (field "workloads" declaration |> list))
       = 3);
    check
      "projection contains no claim applicability catalog"
      (field "claims" declaration = `Null && field "capabilities" declaration = `Null))
;;

let test_profile_declaration_is_not_readiness () =
  with_workspace "aws" (fun _ config facts ->
    let config =
      { config with
        Sol_cli_config.target =
          { config.target with profile = Some Sol_cli_profile.Production_single_region }
      }
    in
    let declaration = project "aws" config facts in
    check
      "unmet readiness does not erase expected subjects"
      (List.length (field "workloads" declaration |> list) = 4);
    let inventory = Sol_cli_workspace_model.services facts in
    let selection = Sol_cli_deploy_selection.select ~image_refs:[] inventory |> get in
    let deployed =
      Sol_cli_deploy_selection.apply_target ~target:config.target.name ~config selection
      |> get
    in
    let input : Sol_cli_deploy_selection.Planning_input.t =
      { workspace = Sol_cli_workspace.workspace_name ~root:facts.root
      ; registry = "declaration.invalid"
      ; sha = "not-published"
      ; emit_to = None
      ; config
      ; facts
      ; inventory
      ; requested_scope = "workspace"
      ; image_refs = []
      ; services = deployed.services
      }
    in
    match Sol_cli_deploy_selection.plan input with
    | Error (Preflight (_, findings)) ->
      check
        "deployment still refuses unpublished images"
        (List.exists
           (fun (f : Sol_cli_profile_preflight.finding) ->
              f.capability = Sol_cli_profile.Immutable_artifacts)
           findings)
    | Error (Refused message) -> Windtrap.fail ("wrong refusal boundary: " ^ message)
    | Ok _ -> Windtrap.fail "declaration extraction bypassed deployment preflight")
;;

let () =
  Windtrap.run
    "product database declaration"
    [ Windtrap.group
        "offline"
        [ Windtrap.test "definition identity" test_definition
        ; Windtrap.test
            "declaration is not deployment readiness"
            test_profile_declaration_is_not_readiness
        ; Windtrap.test "AWS rendered/runtime contract" (test_render "aws")
        ; Windtrap.test "GCP rendered/runtime contract" (test_render "gcp")
        ; Windtrap.test "complete target selection" test_selection
        ; Windtrap.test "external binding facts preserve consumers" test_external
        ]
    ]
;;
