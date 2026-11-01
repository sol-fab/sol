let%test "serverless release inventory records and removes a service" =
  let root = Filename.temp_file "sol-inventory" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  let previous = Sys.getcwd () in
  Sys.chdir root;
  let result =
    let open Result.Syntax in
    let* () =
      Sol_cli_serverless_inventory.add
        ~target:"live/aws/us-east-1"
        ~service:"checkout_fn"
        ~record:"/tmp/release.json"
    in
    let* entries = Sol_cli_serverless_inventory.load ~target:"live/aws/us-east-1" in
    let* () =
      Sol_cli_serverless_inventory.remove
        ~target:"live/aws/us-east-1"
        ~service:"checkout_fn"
    in
    let* remaining = Sol_cli_serverless_inventory.load ~target:"live/aws/us-east-1" in
    Ok (entries, remaining)
  in
  Sys.chdir previous;
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
  match result with
  | Error message -> Windtrap.fail message
  | Ok (entries, remaining) ->
    Windtrap.equal Windtrap.int ~msg:"one recorded entry" 1 (List.length entries);
    Windtrap.equal Windtrap.int ~msg:"entry removed" 0 (List.length remaining)
;;

let%test "mixed destroy refuses declared functions without inventory" =
  let root = Filename.temp_file "sol-inventory" "" in
  Sys.remove root;
  Unix.mkdir root 0o755;
  let previous = Sys.getcwd () in
  Sys.chdir root;
  let result =
    Sol_cli_serverless_inventory.destroy_entries
      ~target:"live/aws/us-east-1"
      ~service:None
      ~record:None
      ~declared_functions:1
  in
  Sys.chdir previous;
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
  match result with
  | Ok _ -> Windtrap.fail "mixed destroy accepted no inventory for a declared function"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"inventory refusal names orphan risk"
      true
      (Sol_cli_string.contains ~needle:"orphaned" message)
;;
