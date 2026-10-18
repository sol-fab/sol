open Sol_cli_resource_binding

let binding
      ?(ownership = Sol_cli_config.Ownership_sol)
      ?store
      ?(credentials = [])
      resource
  =
  { resource
  ; typ = "postgres"
  ; ownership
  ; store
  ; keys = []
  ; connection = []
  ; credentials
  }
;;

let selected bindings =
  match postgres bindings with
  | Ok database -> database
  | Error message -> Windtrap.fail message
;;

let%test
    "PostgreSQL selection preserves resource identity and complete credential classes"
  =
  let database =
    selected
      [ binding
          ~ownership:Ownership_external
          ~store:"vault"
          ~credentials:[ "ddl", "private/ddl"; "dml", "private/dml" ]
          "app_db"
      ]
  in
  (match database with
   | External_postgres { resource; store; credentials } ->
     Windtrap.equal Windtrap.string "app_db" resource;
     Windtrap.equal Windtrap.string "vault" store;
     Windtrap.equal Windtrap.string "private/ddl" credentials.ddl;
     Windtrap.equal Windtrap.string "private/dml" credentials.dml
   | _ -> Windtrap.fail "expected a complete external selection");
  let consumer =
    Sol_cli_deployment_plan.database_for_uses
      ~target:(Some "prod-aws-eu-west-1")
      ~database
      [ "app_db" ]
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    (Some "prod-aws-eu-west-1")
    (postgres_use_target consumer);
  Windtrap.equal (Windtrap.option Windtrap.string) None (postgres_use_ca_target consumer)
;;

let%test "required external PostgreSQL fields cannot be blank or absent" =
  List.iter
    (fun database ->
       match postgres [ database ] with
       | Error _ -> ()
       | Ok _ -> Windtrap.fail "an incomplete database selection reached delivery")
    [ binding
        ~ownership:Ownership_external
        ~credentials:[ "ddl", "ddl"; "dml", "dml" ]
        "db"
    ; binding
        ~ownership:Ownership_external
        ~store:" "
        ~credentials:[ "ddl", "ddl"; "dml", "dml" ]
        "db"
    ; binding
        ~ownership:Ownership_external
        ~store:"vault"
        ~credentials:[ "ddl", "ddl" ]
        "db"
    ; binding
        ~ownership:Ownership_external
        ~store:"vault"
        ~credentials:[ "ddl", ""; "dml", "dml" ]
        "db"
    ; binding
        ~ownership:Ownership_external
        ~store:"vault"
        ~credentials:[ "ddl", "ddl"; "dml", " " ]
        "db"
    ]
;;

let%test "credential and CA routing are projections of the same consumer" =
  List.iter
    (fun (database, expected_target, expected_ca) ->
       let use =
         Sol_cli_deployment_plan.database_for_uses
           ~target:(Some "prod-aws-eu-west-1")
           ~database
           [ "app_db" ]
       in
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         expected_target
         (postgres_use_target use);
       Windtrap.equal
         (Windtrap.option Windtrap.string)
         expected_ca
         (postgres_use_ca_target use);
       let nonconsumer =
         Sol_cli_deployment_plan.database_for_uses
           ~target:(Some "prod-aws-eu-west-1")
           ~database
           [ "other_db" ]
       in
       Windtrap.equal Windtrap.bool true (nonconsumer = No_postgres_use))
    [ No_postgres, None, None
    ; Managed_postgres "app_db", Some "prod-aws-eu-west-1", Some "prod-aws-eu-west-1"
    ; Local_postgres "app_db", Some "prod-aws-eu-west-1", None
    ]
;;

let%test
    "omitted PostgreSQL resources remain explicitly absent; resolution errors are errors"
  =
  let resource name omit typ =
    Sol_cli_config.
      { name
      ; typ
      ; omit
      ; binding = None
      ; partition_key = None
      ; sort_key = None
      ; indexes = []
      ; size = None
      }
  in
  let config selected_resources =
    Sol_cli_config.
      { project = Some "ws"
      ; target = Result.get_ok (parse_target "prod/aws/eu-west-1")
      ; resources = selected_resources
      ; services = []
      }
  in
  Windtrap.equal
    Windtrap.bool
    true
    (resolve_postgres (config [ resource "app_db" true (Some "postgres") ])
     = Ok No_postgres);
  List.iter
    (fun cfg ->
       match resolve_postgres cfg with
       | Error _ -> ()
       | Ok _ -> Windtrap.fail "resolution failure became an absent database")
    [ config [ resource "app_db" false None ]
    ; config
        [ resource "first_db" false (Some "postgres")
        ; resource "second_db" false (Some "postgres")
        ]
    ]
;;

let%test
    "external PostgreSQL cannot silently discard declared private trust or connection \
     inputs"
  =
  let complete =
    binding
      ~ownership:Ownership_external
      ~store:"vault"
      ~credentials:[ "ddl", "private/ddl"; "dml", "private/dml" ]
      "app_db"
  in
  List.iter
    (fun unsupported ->
       match postgres [ unsupported ] with
       | Error message ->
         Windtrap.equal
           Windtrap.bool
           true
           (Sol_cli_string.contains ~needle:"cannot be delivered" message)
       | Ok _ ->
         Windtrap.fail "unsupported external PostgreSQL inputs were silently dropped")
    [ { complete with connection = [ "sslrootcert", "private/root.crt" ] }
    ; { complete with connection = [ "host", "db.example" ] }
    ; { complete with keys = [ "POSTGRES_CA_CERT", "private/ca" ] }
    ; { complete with credentials = ("ca", "private/ca") :: complete.credentials }
    ]
;;
