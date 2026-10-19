let () =
  let operation =
    match Array.to_list Sys.argv with
    | [ _; "bootstrap" ] -> Sol_cli_database_setup.Bootstrap
    | [ _; "repair" ] -> Sol_cli_database_setup.Repair
    | _ -> failwith "expected bootstrap or repair"
  in
  print_endline (Sol_cli_database_setup.sql ~operation)
;;
