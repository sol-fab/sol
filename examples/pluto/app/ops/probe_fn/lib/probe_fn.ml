(** A dependency-free serverless probe.

    The function runs once and exits. On an AWS serverless target the framework
    serves this module through the Lambda runtime and answers an invocation with
    [{"status":"ok"}]; locally or on Kubernetes it is a run-once CronJob. *)

let run () =
  Printf.printf "[probe-fn] pluto serverless probe ok\n%!";
  Ok ()
;;
