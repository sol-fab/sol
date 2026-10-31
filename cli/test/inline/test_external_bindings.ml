let service name uses : Sol_cli_config.service =
  { name
  ; typ = None
  ; path = None
  ; uses
  ; scale_min = None
  ; scale_max = None
  ; language = None
  ; omit = false
  }
;;

let resource ?(keys = []) ?(credentials = []) typ connection name
  : Sol_cli_config.resource
  =
  { name
  ; typ = Some typ
  ; partition_key = None
  ; sort_key = None
  ; indexes = []
  ; size = None
  ; omit = false
  ; binding =
      Some
        { Sol_cli_config.ownership = Sol_cli_config.Ownership_external
        ; store = Some "external"
        ; keys
        ; connection
        ; credentials
        }
  }
;;

let config ?(target = "sched/aws/us-east-1") resources services : Sol_cli_config.t =
  { project = Some "ws"
  ; target = Result.get_ok (Sol_cli_config.parse_target target)
  ; resources
  ; services
  }
;;

let aws_resources =
  [ resource
      "queue"
      [ "QUEUE_ARN", "arn:aws:sqs:us-east-1:123:jobs"; "QUEUE_URL", "https://sqs" ]
      "jobs"
  ; resource
      "object_store"
      [ "OBJECT_ARN", "arn:aws:s3:::uploads/*"; "OBJECT_BUCKET", "uploads" ]
      "uploads"
  ]
;;

let aws_config ?(keys = []) ?(credentials = []) () =
  config
    [ resource
        ~keys
        ~credentials
        "queue"
        [ "QUEUE_ARN", "arn:aws:sqs:us-east-1:123:jobs"; "QUEUE_URL", "https://sqs" ]
        "jobs"
    ; resource
        ~keys
        ~credentials
        "object_store"
        [ "OBJECT_ARN", "arn:aws:s3:::uploads/*"; "OBJECT_BUCKET", "uploads" ]
        "uploads"
    ]
    [ service "charge_svc" [ "jobs"; "uploads" ] ]
;;

let test_positive () =
  match
    Sol_cli_resource_binding.external_requirements
      ~config:(aws_config ())
      ~service_name:"charge_svc"
  with
  | Error message -> Windtrap.fail message
  | Ok requirements ->
    let rendered =
      List.map
        (fun (r : Sol_cli_grant.requirement) ->
           Sol_cli_grant.capability_to_string r.capability ^ "|" ^ r.resource)
        requirements
    in
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"queue and object capabilities"
      [ "message.publish|arn:aws:sqs:us-east-1:123:jobs"
      ; "message.subscribe|arn:aws:sqs:us-east-1:123:jobs"
      ; "object.read|arn:aws:s3:::uploads/*"
      ; "object.write|arn:aws:s3:::uploads/*"
      ]
      rendered
;;

let test_missing_identifier () =
  let config =
    config
      [ resource "queue" [ "QUEUE_URL", "https://sqs" ] "jobs" ]
      [ service "charge_svc" [ "jobs" ] ]
  in
  match
    Sol_cli_resource_binding.external_requirements ~config ~service_name:"charge_svc"
  with
  | Ok _ -> Windtrap.fail "queue without QUEUE_ARN was accepted"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"missing identifier is named"
      true
      (Sol_cli_string.contains ~needle:"QUEUE_ARN" message)
;;

let test_secret_references_fail_closed () =
  match
    Sol_cli_resource_binding.external_requirements
      ~config:(aws_config ~keys:[ "AWS_ACCESS_KEY_ID", "store/key" ] ())
      ~service_name:"charge_svc"
  with
  | Ok _ -> Windtrap.fail "undeclared secret-reference auth was accepted"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"unsupported auth is named"
      true
      (Sol_cli_string.contains ~needle:"secret references" message)
;;

let test_gcp_fails_closed () =
  let config =
    config
      ~target:"sched/gcp/us-west1"
      [ resource
          "queue"
          [ "QUEUE_ARN", "arn:aws:sqs:us-east-1:123:jobs"; "QUEUE_URL", "https://pubsub" ]
          "jobs"
      ]
      [ service "charge_svc" [ "jobs" ] ]
  in
  let tmp = Filename.temp_file "sol-ext-auth" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let orig = Sys.getcwd () in
  Sys.chdir tmp;
  Fun.protect
    ~finally:(fun () -> Sys.chdir orig)
    (fun () ->
       let path = Filename.concat (Sys.getcwd ()) "charge_svc/sol.toml" in
       Result.get_ok (Sol_cli_fs.mkdir_p (Filename.dirname path));
       let oc = open_out path in
       output_string oc "";
       close_out oc;
       let workload : Sol_cli_workspace_model.workload =
         { service =
             { Sol_cli_manifest.domain = "payments"
             ; name = "charge_svc"
             ; primitive = Sol_cli_manifest.Svc
             ; dir = "charge_svc"
             }
         ; has_dockerfile = true
         ; language = None
         ; config = Sol_cli_toml.load_result path
         }
       in
       let model : Sol_cli_workspace_model.t =
         { root = Sys.getcwd ()
         ; app_dir = None
         ; workloads = [ workload ]
         ; unexpected = []
         ; declared = []
         ; topics = []
         ; schema_subjects = []
         ; migrations = []
         ; events = []
         ; targets = []
         }
       in
       match Sol_cli_authorization_reconcile.desired ~binding_config:config model with
       | Ok _ -> Windtrap.fail "GCP external capability was accepted without translation"
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           ~msg:"unsupported provider is named"
           true
           (Sol_cli_string.contains
              ~needle:"no implemented authorization translation"
              message))
;;

let test_authorization_grants () =
  let tmp = Filename.temp_file "sol-ext-auth" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  let orig = Sys.getcwd () in
  Sys.chdir tmp;
  Fun.protect
    ~finally:(fun () -> Sys.chdir orig)
    (fun () ->
       let path = Filename.concat (Sys.getcwd ()) "charge_svc/sol.toml" in
       Result.get_ok (Sol_cli_fs.mkdir_p (Filename.dirname path));
       let oc = open_out path in
       output_string oc "";
       close_out oc;
       let workload : Sol_cli_workspace_model.workload =
         { service =
             { Sol_cli_manifest.domain = "payments"
             ; name = "charge_svc"
             ; primitive = Sol_cli_manifest.Svc
             ; dir = "charge_svc"
             }
         ; has_dockerfile = true
         ; language = None
         ; config = Sol_cli_toml.load_result path
         }
       in
       let model : Sol_cli_workspace_model.t =
         { root = Sys.getcwd ()
         ; app_dir = None
         ; workloads = [ workload ]
         ; unexpected = []
         ; declared = []
         ; topics = []
         ; schema_subjects = []
         ; migrations = []
         ; events = []
         ; targets = []
         }
       in
       match
         Sol_cli_authorization_reconcile.desired ~binding_config:(aws_config ()) model
       with
       | Error message -> Windtrap.fail message
       | Ok grants ->
         Windtrap.equal
           (Windtrap.list Windtrap.string)
           ~msg:"queue/object capabilities reach the authorization plan"
           [ "charge-svc|message.publish|arn:aws:sqs:us-east-1:123:jobs"
           ; "charge-svc|message.subscribe|arn:aws:sqs:us-east-1:123:jobs"
           ; "charge-svc|object.read|arn:aws:s3:::uploads/*"
           ; "charge-svc|object.write|arn:aws:s3:::uploads/*"
           ]
           (List.map
              (fun (g : Sol_cli_authorization.grant) ->
                 g.unit ^ "|" ^ g.capability ^ "|" ^ g.resource)
              (Sol_cli_authorization.normalize grants)))
;;

let%test "external queue/object capabilities" = test_positive ()
let%test "missing external resource identifier fails closed" = test_missing_identifier ()
let%test "external secret references fail closed" = test_secret_references_fail_closed ()
let%test "unsupported external provider fails closed" = test_gcp_fails_closed ()
let%test "external grants reach authorization" = test_authorization_grants ()

let test_plan_validation_missing_identifier () =
  let declared =
    Sol_cli_config.declared_of_config
      (config
         [ resource "queue" [ "QUEUE_URL", "https://sqs" ] "jobs" ]
         [ service "charge_svc" [ "jobs" ] ])
  in
  match
    Sol_cli_resource_binding.validate_external_bindings
      ~declared
      ~service_name:"charge_svc"
  with
  | Ok () -> Windtrap.fail "planning accepted a queue without QUEUE_ARN"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"planning names the missing identifier"
      true
      (Sol_cli_string.contains ~needle:"QUEUE_ARN" message)
;;

let%test "plan validation refuses missing external identifier" =
  test_plan_validation_missing_identifier ()
;;
