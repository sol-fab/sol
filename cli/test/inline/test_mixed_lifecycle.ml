let service name primitive : Sol_cli_manifest.service =
  { domain = "app"; name; primitive; dir = "app/" ^ name }
;;

let target =
  Result.get_ok (Sol_cli_config.parse_target "mixed/aws/us-east-1")
  |> fun target ->
  { target with
    Sol_cli_config.provider_fields =
      (target.Sol_cli_config.provider_fields
       |> List.filter (fun (provider, _) -> provider <> "sol"))
      @ [ "sol", [ "execution", "mixed" ] ]
  }
;;

let%test "one authorization apply precedes both mixed backends" =
  let calls = ref [] in
  let mark name = calls := !calls @ [ name ] in
  let svc = service "orders_svc" Sol_cli_manifest.Svc in
  let fn = service "notify_fn" Sol_cli_manifest.Fn in
  let result =
    Sol_cli_mixed_lifecycle.run
      ~target
      ~services:[ svc; fn ]
      ~authorize:(fun () ->
        mark "authorize";
        Ok ())
      ~serverless:(fun services ->
        mark "serverless";
        Windtrap.equal Windtrap.int ~msg:"one function" 1 (List.length services);
        Ok ())
      ~kubernetes:(fun services ->
        mark "kubernetes";
        Windtrap.equal Windtrap.int ~msg:"one service" 1 (List.length services);
        Ok ())
  in
  (match result with
   | Error message -> Windtrap.fail message
   | Ok () -> ());
  Windtrap.equal
    Windtrap.int
    ~msg:"authorization once, then each backend once"
    3
    (List.length !calls);
  Windtrap.equal
    Windtrap.string
    ~msg:"authorization is first"
    "authorize"
    (List.hd !calls)
;;

let%test "a failed backend stops the next one but records the completed backend" =
  let calls = ref [] in
  let mark name = calls := !calls @ [ name ] in
  let svc = service "orders_svc" Sol_cli_manifest.Svc in
  let fn = service "notify_fn" Sol_cli_manifest.Fn in
  let first =
    Sol_cli_mixed_lifecycle.run
      ~target
      ~services:[ svc; fn ]
      ~authorize:(fun () -> Ok ())
      ~serverless:(fun _ ->
        mark "serverless";
        Ok ())
      ~kubernetes:(fun _ ->
        mark "kubernetes";
        Error "backend failed")
  in
  (match first with
   | Error "backend failed" -> ()
   | _ -> Windtrap.fail "failure was not preserved");
  Windtrap.equal Windtrap.int ~msg:"both backends were attempted" 2 (List.length !calls);
  let retried =
    Sol_cli_mixed_lifecycle.run
      ~target
      ~services:[ svc; fn ]
      ~authorize:(fun () ->
        mark "retry-authorize";
        Ok ())
      ~serverless:(fun _ ->
        mark "retry-serverless";
        Ok ())
      ~kubernetes:(fun _ ->
        mark "retry-kubernetes";
        Ok ())
  in
  (match retried with
   | Error message -> Windtrap.fail message
   | Ok () -> ());
  Windtrap.equal
    Windtrap.int
    ~msg:"retry re-runs authorization and both backends"
    5
    (List.length !calls)
;;
