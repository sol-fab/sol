let () =
  let task = Task_consumer.Send_welcome { user_id = "u-1" } in
  assert (Task_consumer.kind task = "send_welcome");
  assert (Task_consumer.decode {|{"kind":"send_welcome","user_id":"u-1"}|} = Ok task);
  assert (Result.is_error (Task_consumer.decode {|{"kind":"send_welcome"}|}));
  assert (
    Task_consumer.handle ~task_id:"task-1" ~idempotency_key:"welcome-u-1" task
    = Sol_task.Ack)
;;
