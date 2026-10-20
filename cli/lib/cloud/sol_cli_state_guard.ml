type verdict =
  | Proceed
  | Warn of string
  | Acknowledge of string
  | Refuse of string

let verdict ~constructive ~accept_unresolved status =
  let described = Sol_cli_supervised.status_to_string status in
  match status with
  | Sol_cli_supervised.No_previous | Sol_cli_supervised.Resolved _ -> Proceed
  | Sol_cli_supervised.Running _ ->
    Refuse
      (Printf.sprintf
         "a previous Terraform operation against this state is still running and holds \
          its lock. Wait for it to finish; do not unlock it.\n\
         \  %s"
         described)
  | Sol_cli_supervised.Unresolved _ when not constructive ->
    Warn
      (Printf.sprintf
         "warning: the previous Terraform operation against this state is %s"
         described)
  | Sol_cli_supervised.Unresolved _ when accept_unresolved ->
    Acknowledge
      (Printf.sprintf
         "warning: proceeding past an unresolved previous operation, as \
          --accept-unresolved asks: %s"
         described)
  | Sol_cli_supervised.Unresolved _ ->
    Refuse
      (Printf.sprintf
         "refusing to apply: the previous Terraform operation against this state is %s\n\
         \  Terraform may have changed the provider without recording it. Reconcile \
          first (inspect the provider and the state; import or remove what diverged, \
          push any errored.tfstate), then re-run with --accept-unresolved. Nothing was \
          changed."
         described)
;;

let check ~constructive ~accept_unresolved ~chdir ~backend_config =
  let errored = Filename.concat chdir "errored.tfstate" in
  if constructive && Sys.file_exists errored
  then
    Error
      (Printf.sprintf
         "refusing to apply: Terraform could not persist state and left %s. Push it to \
          the backend and remove it before retrying; --accept-unresolved acknowledges an \
          operation record, it never pushes or discards state."
         errored)
  else (
    match
      verdict
        ~constructive
        ~accept_unresolved
        (Sol_cli_terraform.previous_operation ~chdir ~backend_config)
    with
    | Proceed -> Ok ()
    | Warn warning ->
      Sol_cli_report.warn "%s" warning;
      Ok ()
    | Acknowledge warning ->
      Sol_cli_terraform.acknowledge_previous_operation ~chdir ~backend_config;
      Sol_cli_report.warn "%s" warning;
      Ok ()
    | Refuse message -> Error message)
;;
