let write path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc
;;

let make_workspace () =
  let root = Filename.temp_file "sol-auth-model" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  write
    (Filename.concat root "sol.yml")
    {|
project: auth-model
services:
  payments_fn:
    type: fn
    path: app/payments/payments_fn
  notifications_fn:
    type: fn
    path: app/notifications/notifications_fn
|};
  List.iter
    (fun (dir, schedule) ->
       ignore (Sol_cli_fs.mkdir_p (Filename.concat root dir));
       write (Filename.concat root (dir ^ "/Dockerfile")) "FROM scratch\n";
       write
         (Filename.concat root (dir ^ "/sol.toml"))
         (match schedule with
          | Some schedule -> Printf.sprintf "[service]\nschedule = %S\n" schedule
          | None -> "[service]\n"))
    [ "app/payments/payments_fn", Some "0 * * * *"
    ; "app/notifications/notifications_fn", None
    ];
  root
;;

let target = Result.get_ok (Sol_cli_config.parse_target "auth-model/aws/us-east-1")

let config : Sol_cli_config.t =
  { project = Some "auth-model"; target; resources = []; services = [] }
;;

let units exclude =
  let root = make_workspace () in
  let model = Result.get_ok (Sol_cli_workspace_model.load ~root) in
  let result =
    Sol_cli_serverless_lifecycle.complete_units
      ~config
      ~project:"auth-model"
      ~target
      ~model
      ~exclude
      ~serverless_all:false
  in
  let () =
    let rec remove path =
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun child -> remove (Filename.concat path child));
        Unix.rmdir path)
      else Sys.remove path
    in
    remove root
  in
  result
;;

let%test "complete model keeps both functions" =
  match units None with
  | Error message -> Windtrap.fail message
  | Ok (serverless, scheduler) ->
    Windtrap.equal Windtrap.int ~msg:"serverless units" 2 (List.length serverless);
    Windtrap.equal Windtrap.int ~msg:"scheduler units" 1 (List.length scheduler);
    Windtrap.equal
      Windtrap.bool
      ~msg:"payments unit is present"
      true
      (List.exists
         (fun (u : Sol_cli_grant.serverless_unit) -> u.unit = "payments/payments_fn")
         serverless);
    Windtrap.equal
      Windtrap.bool
      ~msg:"notifications unit is present"
      true
      (List.exists
         (fun (u : Sol_cli_grant.serverless_unit) ->
            u.unit = "notifications/notifications_fn")
         serverless)
;;

let%test "excluding a scheduled function removes its scheduler unit only" =
  match units (Some "payments_fn") with
  | Error message -> Windtrap.fail message
  | Ok (serverless, scheduler) ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"only the retained function remains, with no scheduler unit"
      true
      (List.length serverless = 1
       && List.length scheduler = 0
       && List.exists
            (fun (u : Sol_cli_grant.serverless_unit) ->
               u.unit = "notifications/notifications_fn")
            serverless)
;;

let%test "complete model keeps Kubernetes and serverless units distinct" =
  let target_grant : Sol_cli_grant.target_grant =
    { unit = "payments/orders_svc"
    ; capability = "message.publish"
    ; resource = "arn:aws:sqs:us-east-1:123456789012:orders"
    ; namespace = "payments"
    }
  in
  let serverless : Sol_cli_grant.serverless_unit =
    { unit = "payments/payments_fn"
    ; requirements =
        [ { Sol_cli_grant.capability = Sol_cli_grant.Message_publish
          ; resource = "arn:aws:sqs:us-east-1:123456789012:orders"
          }
        ]
    }
  in
  let model : Sol_cli_authorization_stage.target_authorization =
    { grants = [ target_grant ]; serverless_units = [ serverless ]; scheduler_units = [] }
  in
  Windtrap.equal Windtrap.int ~msg:"one Kubernetes grant" 1 (List.length model.grants);
  Windtrap.equal
    Windtrap.int
    ~msg:"one serverless unit"
    1
    (List.length model.serverless_units);
  Windtrap.equal
    Windtrap.string
    ~msg:"grant type is preserved"
    "message.publish"
    (Sol_cli_grant.target_grant_to_json target_grant
     |> Yojson.Safe.Util.member "capability"
     |> Yojson.Safe.Util.to_string)
;;
