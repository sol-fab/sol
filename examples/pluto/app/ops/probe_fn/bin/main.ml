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
  let module F = Fn.Make (Probe_fn) in
  match F.run ~env ~ot:obs () with
  | Ok () -> ()
  | Error `Signalled -> exit 130
  | Error error -> fatal (Fn.run_error_to_string error)
;;
