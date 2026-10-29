let fatal msg =
  prerr_endline ("error: " ^ msg);
  exit 1
;;

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let obs =
    Sol_obs.of_env
      ~sw
      ~net:env#net
      ~clock:env#clock
      ~mono_clock:env#mono_clock
      ~service:"pluto-probe-fn"
      ()
  in
  (* The serverless target supplies the Lambda runtime API; local CronJob and
     `sol local invoke` have no Lambda API, so run the same function once through
     the Cron trigger instead of waiting forever for a Lambda invocation. *)
  let has_lambda_runtime = Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" <> None in
  let module F = Fn.Make (struct
      let trigger = if has_lambda_runtime then Fn.Lambda else Fn.Cron
      let run = Probe_fn.run
    end)
  in
  match F.run ~env ~ot:obs () with
  | Ok () -> ()
  | Error `Signalled -> exit 130
  | Error error -> fatal (Fn.run_error_to_string error)
;;
