let () =
  Sol_cli_report.install_terminal ();
  Sol_cli_supervised.dispatch_if_supervisor ();
  Sol_cli_port_forward.dispatch_if_supervisor ();
  let cmd =
    Cmdliner.Cmd.group
      (Cmdliner.Cmd.info
         "sol"
         ~version:(Option.value Sol_cli_build_info.release_version ~default:Version.v)
         ~doc:"Sol platform CLI — scaffold, run, and deploy Sol services")
      [ Sol_cli_cmd_new.cmd
      ; Cmd_ci.cmd
      ; Cmd_check.cmd
      ; Cmd_contract.cmd
      ; Cmd_local.cmd
      ; Cmd_plan.cmd
      ; Cmd_deploy.cmd
      ; Cmd_destroy.cmd
      ; Cmd_cloud_run.cmd
      ; Cmd_lambda.cmd
      ; Cmd_migrate.cmd
      ; Cmd_rollback.cmd
      ; Cmd_secret.cmd
      ; Cmd_target.cmd
      ; Cmd_releases.cmd
      ; Cmd_assets.cmd
      ; Cmd_grants.cmd
      ; Cmd_uninstall.cmd
      ]
  in
  exit (Cmdliner.Cmd.eval cmd)
;;
