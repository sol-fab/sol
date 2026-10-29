open Cmdliner

let cmd =
  Cmd.group
    (Cmd.info "task" ~doc:"Operate on durable task execution")
    [ Sol_cli_aws_task_cmd.cmd ]
;;
