let config ?(durable = false) () =
  let base = Test_deployment_phases.local_config in
  if durable
  then
    { base with
      Sol_cli_config.target = { base.target with shape = Some Sol_cli_profile.Durable }
    }
  else base
;;

let authority
      ?(state = Sol_cli_database_setup_render.Established)
      ?(ddl = "ddl")
      ?(dml = "dml")
      ()
  =
  { Sol_cli_database_setup_run.ddl_password = ddl; dml_password = dml; state }
;;

let%test "the provider authority record round-trips both states" =
  List.iter
    (fun state ->
       let authority = authority ~state () in
       let json = Sol_cli_database_setup_run.authority_json authority in
       match Sol_cli_database_setup_run.authority_of_json ~what:"test" json with
       | Error message -> Windtrap.fail message
       | Ok decoded ->
         Windtrap.equal
           Windtrap.string
           ~msg:"the state survives"
           (Sol_cli_database_setup_render.authority_state_to_string state)
           (Sol_cli_database_setup_render.authority_state_to_string
              decoded.Sol_cli_database_setup_run.state);
         Windtrap.equal
           Windtrap.string
           ~msg:"the DDL password survives"
           authority.ddl_password
           decoded.ddl_password;
         Windtrap.equal
           Windtrap.string
           ~msg:"the DML password survives"
           authority.dml_password
           decoded.dml_password)
    [ Sol_cli_database_setup_render.Pending; Sol_cli_database_setup_render.Established ]
;;

let%test "a malformed authority record refuses rather than becoming a bootstrap" =
  let refused json =
    match Sol_cli_database_setup_run.authority_of_json ~what:"test" json with
    | Error _ -> ()
    | Ok _ -> Windtrap.fail ("malformed authority was accepted: " ^ json)
  in
  refused "";
  refused "{}";
  refused {|{"version":2,"state":"established","ddl_password":"a","dml_password":"b"}|};
  refused {|{"version":1,"state":"unknown","ddl_password":"a","dml_password":"b"}|};
  refused {|{"version":1,"state":"established","ddl_password":"","dml_password":"b"}|};
  refused {|{"version":1,"state":"established"}|}
;;

let%test "the provider record wins over a legacy record in either state" =
  let legacy = authority ~state:Sol_cli_database_setup_render.Pending () in
  List.iter
    (fun state ->
       match
         Sol_cli_database_setup_run.choose_authority
           ~provider:(Some (authority ~state ()))
           ~legacy:(Some legacy)
       with
       | Sol_cli_database_setup_run.Provider_record _ -> ()
       | _ -> Windtrap.fail "a legacy record competed with the provider authority")
    [ Sol_cli_database_setup_render.Pending; Sol_cli_database_setup_render.Established ]
;;

let%test "an absent provider record adopts the legacy passwords, preserving its state" =
  List.iter
    (fun state ->
       let legacy = authority ~state () in
       match
         Sol_cli_database_setup_run.choose_authority ~provider:None ~legacy:(Some legacy)
       with
       | Sol_cli_database_setup_run.Adopt_legacy adopted ->
         Windtrap.equal
           Windtrap.string
           ~msg:"the state is not promoted by adoption"
           (Sol_cli_database_setup_render.authority_state_to_string state)
           (Sol_cli_database_setup_render.authority_state_to_string adopted.state)
       | _ -> Windtrap.fail "the legacy record was not adopted")
    [ Sol_cli_database_setup_render.Pending; Sol_cli_database_setup_render.Established ]
;;

let%test "only two absent records generate a new credential" =
  match Sol_cli_database_setup_run.choose_authority ~provider:None ~legacy:None with
  | Sol_cli_database_setup_run.Generate -> ()
  | _ -> Windtrap.fail "a credential was adopted or reused without a record"
;;

let%test "the database authority name is target-scoped and distinct from its projections" =
  let config = config ~durable:true () in
  let authority_name =
    match Sol_cli_secret_authority.database ~config ~part:"authority" with
    | Ok secret -> Sol_cli_provider_secret.reference secret
    | Error message -> Windtrap.fail message
  in
  let ddl_name =
    match Sol_cli_secret_authority.database ~config ~part:"ddl-creds" with
    | Ok secret -> Sol_cli_provider_secret.reference secret
    | Error message -> Windtrap.fail message
  in
  Windtrap.equal
    Windtrap.string
    ~msg:"the authority is under the target's database path"
    "sol/local/local/databases/authority"
    authority_name;
  Windtrap.equal
    Windtrap.bool
    ~msg:"the projection is a different provider secret"
    true
    (not (String.equal authority_name ddl_name))
;;
