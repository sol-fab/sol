let liveness_bound_s = 30.0

type t =
  { joined : bool Atomic.t
  ; assigned : int Atomic.t
  ; last_poll : float Atomic.t
  ; now : unit -> float
  }

let create ~now =
  { joined = Atomic.make false
  ; assigned = Atomic.make 0
  ; last_poll = Atomic.make (now ())
  ; now
  }
;;

let on_assignment t owned =
  Atomic.set t.assigned owned;
  Atomic.set t.joined true
;;

let on_poll t = Atomic.set t.last_poll (t.now ())
let is_ready t = Atomic.get t.joined
let assigned_partitions t = Atomic.get t.assigned
let is_live t = t.now () -. Atomic.get t.last_poll <= liveness_bound_s

let respond_string ~status body =
  Cohttp_eio.Server.respond ~status ~body:(Cohttp_eio.Body.of_string body) ()
;;

let serve ~sw ~net ~port t renderer =
  let callback _conn req _body =
    match Cohttp.Request.meth req, Cohttp.Request.resource req with
    | `GET, "/metrics" -> respond_string ~status:`OK (renderer ())
    | `GET, "/readyz" ->
      if is_ready t
      then respond_string ~status:`OK "ready\n"
      else
        respond_string
          ~status:`Service_unavailable
          "not ready: the consumer has not joined its consumer group yet\n"
    | `GET, "/livez" ->
      if is_live t
      then respond_string ~status:`OK "live\n"
      else
        respond_string
          ~status:`Service_unavailable
          "not live: no successful poll recently\n"
    | _ -> respond_string ~status:`Not_found "not found\n"
  in
  let server = Cohttp_eio.Server.make ~callback () in
  try
    let socket =
      Eio.Net.listen
        ~sw
        ~backlog:128
        ~reuse_addr:true
        net
        (`Tcp (Eio.Net.Ipaddr.V4.any, port))
    in
    Cohttp_eio.Server.run
      ~on_error:(fun e ->
        Printf.eprintf "sol-worker: health server error: %s\n%!" (Printexc.to_string e))
      socket
      server
  with
  | Eio.Cancel.Cancelled _ -> `Stop_daemon
  | e ->
    Printf.eprintf
      "sol-worker: could not serve /metrics,/readyz,/livez on port %d: %s\n%!"
      port
      (Printexc.to_string e);
    `Stop_daemon
;;
