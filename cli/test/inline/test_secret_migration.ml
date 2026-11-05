let aws_secret =
  let scope =
    match
      Sol_cli_provider_secret.scope
        ~provider:Sol_cli_provider_secret.Aws
        ~environment:"dev"
        ~target:"dev-aws-us-east-1"
        ~project:None
        ~region:(Some "us-east-1")
    with
    | Ok scope -> scope
    | Error message -> Windtrap.fail message
  in
  match
    Sol_cli_provider_secret.application
      ~scope
      ~domain:"payments"
      ~unit:"charge-svc"
      ~key:"API_KEY"
  with
  | Ok secret -> secret
  | Error message -> Windtrap.fail message
;;

let gcp_secret =
  let scope =
    match
      Sol_cli_provider_secret.scope
        ~provider:Sol_cli_provider_secret.Gcp
        ~environment:"dev"
        ~target:"dev-gcp-us-central1"
        ~project:(Some "example-project")
        ~region:None
    with
    | Ok scope -> scope
    | Error message -> Windtrap.fail message
  in
  match
    Sol_cli_provider_secret.application
      ~scope
      ~domain:"payments"
      ~unit:"charge-svc"
      ~key:"API_KEY"
  with
  | Ok secret -> secret
  | Error message -> Windtrap.fail message
;;

let status json = Sol_cli_secret_authority.observation_of_json aws_secret json

let tags ?(environment = "dev") () =
  `Assoc
    [ ( "Tags"
      , `List
          [ `Assoc [ "Key", `String "sol-managed-by"; "Value", `String "sol" ]
          ; `Assoc [ "Key", `String "sol-authority"; "Value", `String "application" ]
          ; `Assoc [ "Key", `String "sol-environment"; "Value", `String environment ]
          ; `Assoc [ "Key", `String "sol-target"; "Value", `String "dev-aws-us-east-1" ]
          ] )
    ]
;;

let%test "a same-named secret without Sol ownership is refused, not adopted" =
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"missing tags"
    (Some "its sol-managed-by label/tag is not \"sol\"")
    (match status (`Assoc []) with
     | Sol_cli_secret_authority.Unowned reason -> Some reason
     | _ -> None);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"another environment's tags"
    (Some "its sol-environment label/tag is not \"dev\"")
    (match status (tags ~environment:"prod" ()) with
     | Sol_cli_secret_authority.Unowned reason -> Some reason
     | _ -> None)
;;

let%test "ownership accepts the exact claim on both providers" =
  Windtrap.equal
    Windtrap.bool
    ~msg:"AWS tags"
    true
    (match status (tags ()) with
     | Sol_cli_secret_authority.Owned -> true
     | _ -> false);
  Windtrap.equal
    Windtrap.bool
    ~msg:"GCP labels"
    true
    (match
       Sol_cli_secret_authority.observation_of_json
         gcp_secret
         (`Assoc
             [ ( "labels"
               , `Assoc
                   [ "sol-managed-by", `String "sol"
                   ; "sol-authority", `String "application"
                   ; "sol-environment", `String "dev"
                   ; "sol-target", `String "dev-gcp-us-central1"
                   ] )
             ])
     with
     | Sol_cli_secret_authority.Owned -> true
     | _ -> false)
;;

let%test "AWS create-secret passes every ownership tag under one --tags flag" =
  let argv = Sol_cli_secret_authority.aws_create_args aws_secret in
  let tag_flags = List.filter (fun arg -> String.equal arg "--tags") argv in
  Windtrap.equal
    Windtrap.int
    ~msg:"one --tags flag, not one per tag"
    1
    (List.length tag_flags);
  let rec tags_after = function
    | [] -> []
    | "--tags" :: rest -> rest
    | _ :: rest -> tags_after rest
  in
  let tags = tags_after argv |> List.filter (String.starts_with ~prefix:"Key=") in
  Windtrap.equal
    Windtrap.int
    ~msg:"all four ownership tags are passed"
    4
    (List.length tags);
  List.iter
    (fun tag ->
       Windtrap.equal
         Windtrap.bool
         ~msg:("tag is a Key=,Value= entry: " ^ tag)
         true
         (String.contains tag ','))
    tags
;;

let%test "a pending provider deletion is not absence" =
  match status (`Assoc [ "DeletedDate", `String "2026-01-01T00:00:00Z" ]) with
  | Sol_cli_secret_authority.Pending_deletion _ -> ()
  | _ -> Windtrap.fail "a pending deletion must not read as absent"
;;

open Sol_cli_secret_migration

let decided = function
  | Nothing -> "nothing"
  | Adopt value -> "adopt:" ^ value
  | Retire -> "retire"
  | Retire_differing -> "retire-differing"
;;

let%test "migration adopts only the legacy copy and retires a matching duplicate" =
  Windtrap.equal
    Windtrap.string
    ~msg:"nothing to migrate"
    "nothing"
    (decided (decide ~provider_value:None ~legacy_value:None));
  Windtrap.equal
    Windtrap.string
    ~msg:"already provider-only"
    "nothing"
    (decided (decide ~provider_value:(Some "v") ~legacy_value:None));
  Windtrap.equal
    Windtrap.string
    ~msg:"provider absent, legacy present"
    "adopt:v"
    (decided (decide ~provider_value:None ~legacy_value:(Some "v")));
  Windtrap.equal
    Windtrap.string
    ~msg:"an interrupted migration resumes by retiring the duplicate"
    "retire"
    (decided (decide ~provider_value:(Some "v") ~legacy_value:(Some "v")))
;;

let%test "the provider authority wins when a legacy copy disagrees" =
  Windtrap.equal
    Windtrap.string
    ~msg:"a differing Kubernetes value is retired, not adopted"
    "retire-differing"
    (decided (decide ~provider_value:(Some "provider") ~legacy_value:(Some "legacy")))
;;

let%test "an interrupted adoption leaves the value in both places and is recoverable" =
  (* The first interruption point is after the provider write and before the legacy delete.
     The decision must then retire, not adopt again or refuse. *)
  match decide ~provider_value:(Some "v") ~legacy_value:(Some "v") with
  | Retire -> ()
  | _ -> Windtrap.fail "the second pass must not write another provider version"
;;

let%test "the destroy inventory is limited to this environment's application authority" =
  let json =
    `Assoc
      [ ( "SecretList"
        , `List
            [ `Assoc
                [ "Name", `String "sol/dev/dev-aws-us-east-1/units/payments/api/API_KEY"
                ; ( "Tags"
                  , `List
                      [ `Assoc
                          [ "Key", `String "sol-environment"; "Value", `String "dev" ]
                      ; `Assoc
                          [ "Key", `String "sol-target"
                          ; "Value", `String "dev-aws-us-east-1"
                          ]
                      ; `Assoc
                          [ "Key", `String "sol-authority"
                          ; "Value", `String "application"
                          ]
                      ] )
                ]
            ; `Assoc
                [ "Name", `String "sol/prod/units/payments/api/API_KEY"
                ; ( "Tags"
                  , `List
                      [ `Assoc
                          [ "Key", `String "sol-environment"; "Value", `String "prod" ]
                      ; `Assoc
                          [ "Key", `String "sol-target"
                          ; "Value", `String "prod-aws-us-east-1"
                          ]
                      ; `Assoc
                          [ "Key", `String "sol-authority"
                          ; "Value", `String "application"
                          ]
                      ] )
                ]
            ; `Assoc
                [ "Name", `String "sol/dev/dev-aws-us-east-1/databases/target/authority"
                ; ( "Tags"
                  , `List
                      [ `Assoc
                          [ "Key", `String "sol-environment"; "Value", `String "dev" ]
                      ; `Assoc
                          [ "Key", `String "sol-target"
                          ; "Value", `String "dev-aws-us-east-1"
                          ]
                      ; `Assoc
                          [ "Key", `String "sol-authority"; "Value", `String "database" ]
                      ] )
                ]
            ; `Assoc
                [ "Name", `String "sol-dev-other"
                ; ( "Tags"
                  , `List
                      [ `Assoc
                          [ "Key", `String "sol-environment"; "Value", `String "dev" ]
                      ; `Assoc
                          [ "Key", `String "sol-target"
                          ; "Value", `String "dev-aws-us-east-1"
                          ]
                      ; `Assoc
                          [ "Key", `String "sol-authority"
                          ; "Value", `String "application"
                          ]
                      ] )
                ]
            ] )
      ]
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"only this target's application and database authorities"
    [ "sol/dev/dev-aws-us-east-1/units/payments/api/API_KEY"
    ; "sol/dev/dev-aws-us-east-1/databases/target/authority"
    ; "sol-dev-other"
    ]
    (Sol_cli_secret_authority.aws_inventory
       ~environment:"dev"
       ~target:"dev-aws-us-east-1"
       json
     |> List.map (fun entry -> entry.Sol_cli_secret_authority.entry_name))
;;

let%test "a GCP inventory reports short provider names" =
  let json =
    `List
      [ `Assoc
          [ "name", `String "projects/example/secrets/sol-dev-units-payments-api-API_KEY"
          ]
      ]
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"the provider resource path is reduced to the secret id"
    [ "sol-dev-units-payments-api-API_KEY" ]
    (Sol_cli_secret_authority.gcp_inventory json
     |> List.map (fun entry -> entry.Sol_cli_secret_authority.entry_name))
;;
