let is_error label = function
  | Ok _ -> Windtrap.failf "%s: a malformed read was accepted" label
  | Error (_ : string) -> ()
;;

let ok label = function
  | Ok v -> v
  | Error msg -> Windtrap.failf "%s: %s" label msg
;;

let test_boundary () =
  let j =
    ok "decode" (Sol_cli_json.decode ~what:"x" {|{"a":{"b":1},"s":"t","n":null}|})
  in
  Windtrap.equal
    (Windtrap.option Windtrap.int)
    ~msg:"path"
    (Some 1)
    (Sol_cli_json.field [ "a"; "b" ] j |> Sol_cli_json.int);
  Windtrap.equal
    Windtrap.bool
    ~msg:"a path through a non-object is Null, not an exception"
    true
    (Sol_cli_json.field [ "s"; "deeper" ] j = `Null);
  is_error "not JSON" (Sol_cli_json.decode ~what:"x" "{nope");
  is_error
    "required and missing"
    (Sol_cli_json.require ~what:"x" [ "zz" ] Sol_cli_json.int j);
  is_error
    "required, wrong type"
    (Sol_cli_json.require ~what:"x" [ "s" ] Sol_cli_json.int j);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"optional and null"
    None
    (ok "optional" (Sol_cli_json.optional ~what:"x" [ "n" ] Sol_cli_json.string j));
  is_error
    "optional, wrong type"
    (Sol_cli_json.optional ~what:"x" [ "a" ] Sol_cli_json.string j);
  Windtrap.equal
    Windtrap.int
    ~msg:"empty items"
    0
    (List.length (ok "items" (Sol_cli_json.items ~what:"x" {|{"items":[]}|})));
  is_error "no items" (Sol_cli_json.items ~what:"x" {|{"kind":"List"}|});
  is_error "a non-object item" (Sol_cli_json.items ~what:"x" {|{"items":[1]}|})
;;

let test_migration_status () =
  is_error
    "an applied entry without a version"
    (Sol_cli_migration.parse_status_json {|{"migrations":[{"applied":true}]}|});
  Windtrap.equal
    (Windtrap.list Windtrap.int)
    ~msg:"applied versions only"
    [ 2 ]
    (match
       ok
         "status"
         (Sol_cli_migration.parse_status_json
            {|{"migrations":[{"applied":false,"version":1,"name":"a"},{"applied":true,"version":2,"name":"b"}]}|})
     with
     | status -> status.Sol_cli_migration.applied)
;;

let test_release_lists () =
  is_error
    "a release list without items"
    (Sol_cli_release.parse_kubectl_list (`Assoc [ "kind", `String "List" ]));
  Windtrap.equal
    Windtrap.int
    ~msg:"an empty release list"
    0
    (List.length
       (ok "releases" (Sol_cli_release.parse_kubectl_list (`Assoc [ "items", `List [] ]))))
;;

let%test "REFAC-132: the boundary" = test_boundary ()
let%test "REFAC-132: migration status" = test_migration_status ()
let%test "REFAC-132: release lists" = test_release_lists ()
