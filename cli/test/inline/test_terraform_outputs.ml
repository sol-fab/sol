module O = Sol_cli_terraform_outputs

let shown json =
  match O.displayable json with
  | Ok outputs -> List.map O.line outputs
  | Error e -> Windtrap.fail e
;;

let test_selection () =
  let json =
    {|{ "endpoint":   {"sensitive": false, "value": "https://k8s.test"},
        "secret":     {"sensitive": true,  "value": "hunter2"},
        "unmarked":   {"value": "shown only when marked non-sensitive"},
        "subnets":    {"sensitive": false, "value": ["a", 1, "b"]},
        "no_strings": {"sensitive": false, "value": [1, 2]},
        "missing":    {"sensitive": false, "value": null},
        "count":      {"sensitive": false, "value": 3} }|}
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"only non-sensitive strings, string lists and nulls, in order"
    [ Printf.sprintf "  %-28s  %s" "endpoint" "https://k8s.test"
    ; Printf.sprintf "  %-28s  [%s]" "subnets" "a, b"
    ; Printf.sprintf "  %-28s  (none)" "missing"
    ]
    (shown json)
;;

let test_unreadable () =
  (match O.displayable "{not json" with
   | Error _ -> ()
   | Ok _ -> Windtrap.fail "malformed JSON was read");
  match O.displayable "[]" with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "a non-object read as no outputs"
;;

let%test "outputs: selection" = test_selection ()
let%test "outputs: unreadable" = test_unreadable ()

let%test "Terraform output errors never repeat credential-bearing JSON" =
  let canary = "credentialCanaryDoNotDisclose" in
  let malformed = canary ^ " is not JSON" in
  let check = function
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        false
        (Sol_cli_string.contains ~needle:"credentialCanary" message)
    | Ok _ -> Windtrap.fail "invalid Terraform output accepted"
  in
  check (O.displayable malformed);
  check (O.raw malformed ~name:"password");
  check (O.text malformed ~name:"password");
  let wrong_type =
    Printf.sprintf {|{"password":{"sensitive":true,"value":[%S]}}|} canary
  in
  check (O.text wrong_type ~name:"password")
;;

let%test "cluster and destruction readers omit malformed sensitive Terraform input" =
  let malformed = "credentialCanaryDoNotDisclose is not JSON" in
  let check reader = function
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:reader
        false
        (Sol_cli_string.contains ~needle:"credentialCanary" message)
    | Ok _ -> Windtrap.fail (reader ^ " accepted invalid Terraform JSON")
  in
  check "cluster outputs" (Sol_cli_cluster.outputs_reader ~provider:"AWS" malformed);
  check "AWS cluster outputs" (Sol_cli_aws_cluster.of_outputs_json malformed);
  check "GCP cluster outputs" (Sol_cli_gcp_cluster.of_outputs_json malformed);
  check "GCP project selection" (Sol_cli_gcp_cluster.project_id_of_outputs_json malformed);
  check
    "platform teardown"
    (Sol_cli_platform_teardown.unserved_of_show_json ~served:[] malformed);
  match Sol_cli_cloud_destroy.inventory_of_show_json malformed with
  | Sol_cli_cloud_destroy.State_unreadable message ->
    check "destruction state" (Error message)
  | _ -> Windtrap.fail "malformed destruction state accepted"
;;

let%test
    "provider registry cannot echo malformed Terraform outputs before cluster resolution"
  =
  let dir = Filename.temp_file "sol-sensitive-terraform-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let executable = Filename.concat dir "terraform" in
  Out_channel.with_open_text executable (fun channel ->
    output_string
      channel
      "#!/bin/sh\nprintf '%s' 'credentialCanaryDoNotDisclose is not JSON'\n");
  Unix.chmod executable 0o700;
  let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" path;
      Sys.remove executable;
      Unix.rmdir dir)
    (fun () ->
       let target = Result.get_ok (Sol_cli_config.parse_target "prod/aws/eu-west-1") in
       match
         Sol_cli_provider_registry.of_root Sol_cli_provider.Aws ~target ~chdir:dir
       with
       | Error failure ->
         Windtrap.equal
           Windtrap.bool
           false
           (Sol_cli_string.contains
              ~needle:"credentialCanary"
              (Sol_cli_provider_registry.resolution_failure_to_string failure))
       | Ok _ -> Windtrap.fail "provider accepted malformed output")
;;
