let () =
  Eio_main.run
  @@ fun env ->
  let timed =
    object
      method net = env#net
      method clock = env#clock
      method mono_clock = env#mono_clock
    end
  in
  let module Lambda = Sol_task_lambda.Make (Task_consumer) in
  match Lambda.run ~env:timed () with
  | Ok () -> ()
  | Error message -> failwith message
;;
