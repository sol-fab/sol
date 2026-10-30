module type HANDLER = sig
  val routes : Route.t list
end

type route_match =
  | Found of Route.t * (string * string) list
  | Method_not_allowed
  | Not_found

let find_route routes meth path =
  let path_matched = ref false in
  let rec loop = function
    | [] -> if !path_matched then Method_not_allowed else Not_found
    | r :: rest ->
      (match Route_internal.match_path r.Route.pattern path with
       | None -> loop rest
       | Some params ->
         path_matched := true;
         if r.Route.method_ = meth then Found (r, params) else loop rest)
  in
  loop routes
;;

let route_and_boundary routes metrics_auth req =
  let uri = Uri.of_string (Http.Request.resource req) in
  let path = Uri.path uri in
  let builtin =
    match Http.Request.meth req, path with
    | `GET, ("/healthz" | "/readyz") -> Some (path, Observation.External)
    | `GET, "/metrics" ->
      Some
        ( "/metrics"
        , match metrics_auth with
          | `Workload_identity -> Observation.Internal
          | `Public | `Api_key | `Jwt _ -> Observation.External )
    | _ -> None
  in
  match builtin with
  | Some (route, boundary) -> route, boundary
  | None ->
    let route_match =
      match Route_internal.method_of_http (Http.Request.meth req) with
      | None -> Not_found
      | Some meth -> find_route routes meth path
    in
    (match route_match with
     | Found (route, _) ->
       ( Route.pattern_to_string route.Route.pattern
       , if route.Route.is_external then Observation.External else Observation.Internal )
     | Method_not_allowed | Not_found -> "unmatched", Observation.Internal)
;;

let http_status_of_int = function
  | 200 -> `OK
  | 201 -> `Created
  | 204 -> `No_content
  | 400 -> `Bad_request
  | 401 -> `Unauthorized
  | 403 -> `Forbidden
  | 404 -> `Not_found
  | 405 -> `Method_not_allowed
  | 413 -> `Request_entity_too_large
  | 422 -> `Unprocessable_entity
  | 500 -> `Internal_server_error
  | 501 -> `Not_implemented
  | n -> `Code n
;;

let read_body_limited headers (body : Cohttp_eio.Body.t) max_bytes =
  let too_large_from_header =
    match Http.Header.get headers "content-length" with
    | None -> false
    | Some s ->
      (try int_of_string (String.trim s) > max_bytes with
       | _ -> false)
  in
  if too_large_from_header
  then None
  else (
    let probe_limit = if max_bytes >= max_int then max_bytes else max_bytes + 1 in
    match
      let buf = Eio.Buf_read.of_flow body ~max_size:probe_limit in
      Eio.Buf_read.take_all buf
    with
    | exception Eio.Buf_read.Buffer_limit_exceeded -> None
    | s -> if String.length s > max_bytes then None else Some s)
;;

open Result.Syntax

let auth_result
      ?read_api_key
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      ?(report_error = fun ~operation:_ ~exn:_ -> ())
      auth_cfg
      headers
  =
  match
    Auth_internal.validate
      ?read_api_key
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      auth_cfg
      headers
  with
  | Error (`Unauthorized _) -> Error Response.unauthorized
  | Error (`Forbidden _) -> Error Response.forbidden
  | Error (`Server_error msg) ->
    (* Authentication failures are visible to unauthenticated callers. Keep the detail in
       the operator log and return the same generic body as a handler exception; a JWKS
       error must not disclose the issuer host or provider exception text. *)
    report_error ~operation:"authentication" ~exn:(Failure msg);
    Error (Response.internal_error "Internal server error")
  | Ok ctx -> Ok ctx
;;

let authenticate_route
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      ?report_error
      route
      headers
  =
  if route.Route.is_external
  then Ok None
  else
    auth_result
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      ?report_error
      `Workload_identity
      headers
    |> Result.map Option.some
;;

let body_result headers body max_bytes =
  match read_body_limited headers body max_bytes with
  | None -> Error Response.payload_too_large
  | Some s -> Ok s
;;

type error_reporter = operation:string -> exn:exn -> unit

let stderr_error_reporter ~operation ~exn =
  Printf.eprintf "sol-svc: %s: %s\n%!" operation (Printexc.to_string exn)
;;

let dispatch_unguarded
      ?(report_error = stderr_error_reporter)
      ?read_api_key
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      ?on_boundary
      ?on_workload_principal
      ~routes
      ~metrics_renderer
      ~metrics_auth
      ~max_body_bytes
      ?route_observer
      ?(ready = fun () -> true)
      req
      body
  =
  let meth_opt = Route_internal.method_of_http (Http.Request.meth req) in
  match meth_opt with
  | None -> { Response.status = 405; headers = []; body = "" }
  | Some meth ->
    let resource = Http.Request.resource req in
    let uri = Uri.of_string resource in
    let path = Uri.path uri in
    let headers = Http.Request.headers req in
    if Route.parse_request_path path = None
    then { Response.status = 400; headers = []; body = "Bad Request" }
    else (
      let observe lbl =
        match route_observer with
        | Some f -> f lbl
        | None -> ()
      in
      let builtin =
        match meth, path with
        | `GET, "/healthz" ->
          Option.iter (fun f -> f Observation.External) on_boundary;
          observe "/healthz";
          Some (Response.json {|{"status":"ok"}|})
        | `GET, "/readyz" ->
          Option.iter (fun f -> f Observation.External) on_boundary;
          observe "/readyz";
          Some
            (if ready ()
             then Response.json {|{"status":"ready"}|}
             else
               { Response.status = 503
               ; headers = [ "content-type", "application/json" ]
               ; body = {|{"status":"shutting down"}|}
               })
        | `GET, "/metrics" ->
          Option.iter
            (fun f ->
               f
                 (match metrics_auth with
                  | `Workload_identity -> Observation.Internal
                  | `Public | `Api_key | `Jwt _ -> Observation.External))
            on_boundary;
          observe "/metrics";
          (match metrics_renderer with
           | None -> Some Response.not_found
           | Some render ->
             let result =
               let* _ =
                 auth_result
                   ?read_api_key
                   ?fetch_jwks
                   ?fetch_workload_jwks
                   ?workload_identity
                   ~report_error
                   metrics_auth
                   headers
               in
               Ok
                 (Response.ok
                    ~headers:
                      [ "content-type", "text/plain; version=0.0.4; charset=utf-8" ]
                    (render ()))
             in
             Some
               (match result with
                | Ok r | Error r -> r))
        | _ -> None
      in
      match builtin with
      | Some r -> r
      | None ->
        (match find_route routes meth path with
         | Not_found ->
           observe "unmatched";
           Response.not_found
         | Method_not_allowed ->
           observe "unmatched";
           { Response.status = 405; headers = []; body = "" }
         | Found (route, params) ->
           Option.iter
             (fun f ->
                f
                  (if route.Route.is_external
                   then Observation.External
                   else Observation.Internal))
             on_boundary;
           observe (Route.pattern_to_string route.Route.pattern);
           let result =
             let* auth_ctx =
               authenticate_route
                 ?fetch_jwks
                 ?fetch_workload_jwks
                 ?workload_identity
                 ~report_error
                 route
                 headers
             in
             Option.iter
               (fun f ->
                  match auth_ctx with
                  | Some { Auth.principal = Auth.Unit { unit; service_account }; _ } ->
                    f (Some (unit, service_account))
                  | _ -> f None)
               on_workload_principal;
             let* body_str = body_result headers body max_body_bytes in
             let trace_ctx =
               Http.Header.to_list headers |> Obs_trace.extract_from_headers
             in
             let sol_req =
               Request.
                 { method_ = meth
                 ; path
                 ; headers
                 ; params
                 ; uri
                 ; body = body_str
                 ; auth = auth_ctx
                 ; trace_ctx
                 }
             in
             try Ok (route.Route.handler sol_req) with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
             | exn ->
               report_error ~operation:(Route.pattern_to_string route.Route.pattern) ~exn;
               Ok (Response.internal_error "Internal server error")
           in
           (match result with
            | Ok r | Error r -> r)))
;;

let respond_or_500 ?(report_error = stderr_error_reporter) f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
  | exn ->
    report_error ~operation:"dispatch" ~exn;
    Response.internal_error "Internal server error"
;;

let dispatch
      ?(report_error = stderr_error_reporter)
      ?read_api_key
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      ?on_boundary
      ?on_workload_principal
      ~routes
      ~metrics_renderer
      ~metrics_auth
      ~max_body_bytes
      ?route_observer
      ~ready
      req
      body
  =
  respond_or_500 ~report_error (fun () ->
    dispatch_unguarded
      ~report_error
      ?read_api_key
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      ?on_boundary
      ?on_workload_principal
      ~routes
      ~metrics_renderer
      ~metrics_auth
      ~max_body_bytes
      ?route_observer
      ~ready
      req
      body)
;;

exception Drain_timeout

type run_error = [ `Config of string ]

let run_error_to_string (`Config msg) = "sol-svc: config error: " ^ msg

let auth_uses_api_key = function
  | `Api_key -> true
  | `Public | `Jwt _ | `Workload_identity -> false
;;

let api_key_required metrics_auth = auth_uses_api_key metrics_auth
let unverified_jwt_opt_in = "SOL_ALLOW_UNVERIFIED_JWT"

let auth_is_unverified_jwt = function
  | `Jwt { Auth.verification = Auth.Unverified_dev_only; _ } -> true
  | `Jwt { Auth.verification = Auth.Verified_signature_required _; _ }
  | `Public | `Api_key | `Workload_identity -> false
;;

let refuse_unverified_jwt metrics_auth =
  let used = auth_is_unverified_jwt metrics_auth in
  if used && Sol_runtime.setting unverified_jwt_opt_in <> Some "1"
  then
    Error
      (`Config
          (Printf.sprintf
             "a route uses Unverified_dev_only JWT auth, which accepts tokens without \
              checking their signature. It runs only where %s=1 (sol local deploy sets \
              this on the local cluster). Use Verified_signature_required."
             unverified_jwt_opt_in))
  else Ok ()
;;

let jwks_url_of = function
  | `Jwt { Auth.verification = Auth.Verified_signature_required { key_source; _ }; _ } ->
    (match key_source with
     | Auth.Jwks_url url -> Some url
     | Auth.Jwks_static _ | Auth.Hs256_secret _ -> None)
  | `Jwt { Auth.verification = Auth.Unverified_dev_only; _ }
  | `Public | `Api_key | `Workload_identity -> None
;;

let refuse_non_https_jwks metrics_auth =
  let is_https url =
    let uri = Uri.of_string url in
    match Uri.scheme uri, Uri.host uri with
    | Some scheme, Some host -> String.lowercase_ascii scheme = "https" && host <> ""
    | _ -> false
  in
  match
    List.find_map
      (fun auth ->
         match jwks_url_of auth with
         | Some url when not (is_https url) -> Some url
         | _ -> None)
      [ metrics_auth ]
  with
  | None -> Ok ()
  | Some url ->
    Error
      (`Config
          (Printf.sprintf
             "Jwks_url must be an absolute https:// URL (the keys verify token \
              signatures, so they must not travel in plaintext): %S"
             url))
;;

let api_key_reader ~env ~required =
  match Sol_runtime.setting "SOL_API_KEY_FILE", Sol_runtime.setting "SOL_API_KEY" with
  | Some path, _ ->
    (try
       let key = String.trim (Eio.Path.load Eio.Path.(env#fs / path)) in
       if key = ""
       then Error (`Config ("API key file is empty: " ^ path))
       else Ok (fun () -> Some key)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
     | exn ->
       Error
         (`Config
             ("could not read SOL_API_KEY_FILE " ^ path ^ ": " ^ Printexc.to_string exn)))
  | None, Some key -> Ok (fun () -> Some key)
  | None, _ when required ->
    Error (`Config "API key auth configured but SOL_API_KEY/SOL_API_KEY_FILE is not set")
  | None, _ -> Ok (fun () -> None)
;;

let workload_identity_requested routes metrics_auth =
  metrics_auth = `Workload_identity
  || List.exists (fun route -> not route.Route.is_external) routes
;;

(* The canonical calls graph supplies the audience and allowed callers. Sol projects
   the issuer established by the target capability. *)
let workload_identity_config routes metrics_auth =
  if not (workload_identity_requested routes metrics_auth)
  then Ok None
  else (
    let nonempty name value =
      if String.trim value = ""
      then Error (`Config (Printf.sprintf "%s must not be empty" name))
      else Ok value
    in
    let* audience =
      match Sol_runtime.setting "SOL_UNIT" with
      | Some unit -> nonempty "SOL_UNIT" unit
      | None ->
        Error
          (`Config
              "a route uses Workload_identity auth but SOL_UNIT is not set; the callee's \
               own unit is required to check the token audience")
    in
    let* subject_scheme =
      (* [Sol_runtime.setting] treats an empty value as absent. The scheme is the
         one exception where absence has a compatibility default; an explicitly
         empty value must not silently select Kubernetes. *)
      match Sys.getenv_opt "SOL_WORKLOAD_SUBJECT_SCHEME" with
      | None -> Ok Auth.Kubernetes_service_account
      | Some "" -> Error (`Config "SOL_WORKLOAD_SUBJECT_SCHEME must not be empty")
      | Some raw ->
        (match Auth.subject_scheme_of_string raw with
         | Ok scheme -> Ok scheme
         | Error message -> Error (`Config message))
    in
    let callers =
      match Sol_runtime.setting "SOL_CALLED_BY" with
      | None -> []
      | Some raw -> Auth.callers_of_projection raw
    in
    let* () =
      match Auth.validate_callers subject_scheme callers with
      | Ok () -> Ok ()
      | Error message -> Error (`Config message)
    in
    let* trusted_issuer =
      match Sol_runtime.setting "SOL_TRUSTED_WORKLOAD_ISSUER" with
      | Some issuer -> nonempty "SOL_TRUSTED_WORKLOAD_ISSUER" issuer
      | None ->
        Error
          (`Config
              "a route requires Sol workload authentication but \
               SOL_TRUSTED_WORKLOAD_ISSUER is not set by Sol's target capability \
               projection")
    in
    let* trusted_jwks_uri =
      match Sol_runtime.setting "SOL_TRUSTED_WORKLOAD_JWKS_URI" with
      | None -> Ok None
      | Some raw ->
        let raw = String.trim raw in
        if raw = ""
        then Error (`Config "SOL_TRUSTED_WORKLOAD_JWKS_URI must not be empty")
        else (
          let uri = Uri.of_string raw in
          match Uri.scheme uri, Uri.host uri, Uri.userinfo uri with
          | Some "https", Some host, None when host <> "" -> Ok (Some raw)
          | _ ->
            Error
              (`Config "SOL_TRUSTED_WORKLOAD_JWKS_URI must be an absolute https:// URL"))
    in
    let* () =
      match subject_scheme, trusted_jwks_uri with
      | Auth.Google_oidc_service_account, None ->
        Error
          (`Config
              "the Google OIDC subject scheme requires SOL_TRUSTED_WORKLOAD_JWKS_URI; \
               Google's discovery JWKS origin differs from its issuer")
      | Auth.Kubernetes_service_account, Some _ ->
        Error
          (`Config
              "SOL_TRUSTED_WORKLOAD_JWKS_URI is only supported for the Google OIDC \
               subject scheme; Kubernetes keeps same-origin discovery")
      | _ -> Ok ()
    in
    Ok (Some { Auth.audience; callers; trusted_issuer; trusted_jwks_uri; subject_scheme }))
;;

let emit_request_observation
      ~ot
      ~observe
      ~(metrics_fns : (Obs_eio.counter_fn * Obs_eio.histogram_fn) option)
      req
      ~route
      ~boundary
      ~workload_principal
      ~status
      ~duration_s
  =
  let meth_str =
    match Http.Request.meth req with
    | `GET -> "GET"
    | `POST -> "POST"
    | `PUT -> "PUT"
    | `PATCH -> "PATCH"
    | `DELETE -> "DELETE"
    | _ -> "OTHER"
  in
  let path = Uri.(of_string (Http.Request.resource req) |> path) in
  let trace_id =
    Option.bind
      (Http.Header.get (Http.Request.headers req) "traceparent")
      (fun value ->
         match String.split_on_char '-' value with
         | [ _version; id; _parent; _flags ] when String.length id = 32 -> Some id
         | _ -> None)
  in
  let event =
    Observation.request_finished
      ~method_:meth_str
      ~path
      ~route
      ?trace_id
      ~boundary
      ?workload_principal
      ~status
      ~duration_s
      ()
  in
  let fields =
    [ "method", meth_str
    ; "path", path
    ; "route", route
    ; "status", string_of_int status
    ; "duration_ms", string_of_int (int_of_float (duration_s *. 1000.))
    ; "boundary", Observation.boundary_to_string boundary
    ]
    @
    match workload_principal with
    | None -> []
    | Some (unit, _service_account) -> [ "caller", unit ]
  in
  Option.iter (fun o -> Sol_obs.log_info o ~fields "http request completed") ot;
  Option.iter (fun sink -> sink event) observe;
  Option.iter
    (fun ((req_count : Obs_eio.counter_fn), (req_duration : Obs_eio.histogram_fn)) ->
       let sc = string_of_int (status / 100) ^ "xx" in
       req_count ~labels:[ "method", meth_str; "route", route; "status_class", sc ] 1;
       req_duration ~labels:[ "method", meth_str; "route", route ] duration_s)
    metrics_fns
;;

module For_testing = struct
  let respond_or_500 ?report_error = respond_or_500 ?report_error
  let reset_jwks_cache () = Auth_cache.clear ()
  let cached_jwks_urls () = Auth_cache.urls ()

  let seed_stale_jwks_cache ~url ~age_s ~jwks =
    Auth_cache.replace
      { Auth_cache.url
      ; fetched_at = Unix.gettimeofday () -. age_s
      ; jwks = Jose.Jwks.of_string jwks
      }
  ;;

  let dispatch
        ?report_error
        ?read_api_key
        ?fetch_jwks
        ?fetch_workload_jwks
        ?workload_identity
        ?on_boundary
        ?on_workload_principal
        ~routes
        req
        body
    =
    dispatch
      ?report_error
      ?read_api_key
      ?fetch_jwks
      ?fetch_workload_jwks
      ?workload_identity
      ?on_boundary
      ?on_workload_principal
      ~routes
      ~metrics_renderer:None
      ~metrics_auth:`Public
      ~max_body_bytes:1_048_576
      ~ready:(fun () -> true)
      req
      body
  ;;

  let workload_identity_config routes metrics_auth =
    workload_identity_config routes metrics_auth
  ;;

  let parse_called_by = Auth.callers_of_projection
  let workload_identity_requested = workload_identity_requested
  let jwks_uri_of_discovery = Auth_internal.jwks_uri_of_discovery
  let numeric_https_uri = Auth_internal.numeric_https_uri
end

module Make (H : HANDLER) = struct
  (* A duplicate method+pattern silently shadows the later route. An external route before
     an internal one would expose the later handler without its workload-identity check,
     so this is a startup configuration error rather than a first-match lookup decision. *)
  let normalized_pattern (pattern : Route.pattern) =
    let segments =
      pattern.segments
      |> List.map (function
        | Route.Literal value -> "L:" ^ value
        | Route.Param _ -> "P:")
      |> String.concat "/"
    in
    segments ^ if pattern.trailing_slash then "/" else ""
  ;;

  let duplicate_route routes =
    let seen = Hashtbl.create (List.length routes) in
    let rec loop = function
      | [] -> None
      | (route : Route.t) :: rest ->
        let normalized = normalized_pattern route.pattern in
        let key = route.method_, normalized in
        if Hashtbl.mem seen key
        then Some (Route.pattern_to_string route.pattern)
        else (
          Hashtbl.add seen key ();
          loop rest)
    in
    loop routes
  ;;

  let run
        ~(env :
           < net : _ Eio.Net.t
           ; clock : _ Eio.Time.clock
           ; fs : Eio.Fs.dir_ty Eio.Path.t
           ; .. >)
        ?(port = 8080)
        ?(metrics_auth = `Public)
        ?ot
        ?observe
        ?(max_body_bytes = 10_485_760)
        ?(drain_timeout_s = 30.0)
        ?(shutdown_delay_s = 5.0)
        ?stop
        ?on_listen
        ()
    =
    let* () =
      match duplicate_route H.routes with
      | None -> Ok ()
      | Some pattern ->
        Error
          (`Config
              (Printf.sprintf
                 "duplicate route %S: every method+pattern pair must be unique, because \
                  a                 later duplicate is otherwise unreachable and may \
                  hide an internal                 handler behind a public one"
                 pattern))
    in
    let* port =
      match Sol_runtime.setting "PORT" with
      | None -> Ok port
      | Some raw ->
        (match int_of_string_opt raw with
         | Some p when p >= 0 && p <= 65535 -> Ok p
         | _ ->
           Error (`Config (Printf.sprintf "PORT=%S is not a port number (0-65535)" raw)))
    in
    let ot_eio = Option.map Sol_obs.obs_eio ot in
    let metrics_renderer = Option.map Sol_obs.metrics_renderer ot in
    let report_error =
      match ot with
      | Some o ->
        fun ~operation ~exn ->
          Sol_obs.log_error
            o
            ~fields:[ "operation", operation; "exception", Printexc.to_string exn ]
            "service request failed"
      | None -> stderr_error_reporter
    in
    let metrics_fns =
      match ot_eio with
      | None -> None
      | Some o ->
        let req_count, req_duration =
          Obs_eio.register_counter_and_histogram
            o
            ~counter_name:"sol_svc_requests_total"
            ~counter_help:"Total HTTP requests by method, route, and HTTP status class"
            ~counter_labels:[ "method"; "route"; "status_class" ]
            ~histogram_name:"sol_svc_request_duration_seconds"
            ~histogram_help:"HTTP request latency in seconds by method and route"
            ~histogram_labels:[ "method"; "route" ]
        in
        Some (req_count, req_duration)
    in
    let fetch_jwks = Auth_internal.fetch_jwks_over_https ~env in
    let* () = refuse_unverified_jwt metrics_auth in
    let* () = refuse_non_https_jwks metrics_auth in
    let* read_api_key = api_key_reader ~env ~required:(api_key_required metrics_auth) in
    let* workload_identity = workload_identity_config H.routes metrics_auth in
    let fetch_workload_jwks =
      match workload_identity with
      | Some { Auth.trusted_jwks_uri = Some uri; _ } ->
        fun _ -> Auth_internal.fetch_jwks_over_https ~env uri
      | _ -> Auth_internal.fetch_workload_jwks_over_https ~env
    in
    let lifecycle = Lifecycle.create () in
    let signal_stop, signal_stop_r = Eio.Promise.create () in
    let await_stop () =
      match stop with
      | None -> Eio.Promise.await signal_stop
      | Some external_stop ->
        Eio.Fiber.first
          (fun () -> Eio.Promise.await signal_stop)
          (fun () -> Eio.Promise.await external_stop)
    in
    (try
       Eio.Switch.run (fun sw ->
         Sol_runtime.install_signal_handler ~sw signal_stop_r;
         let socket =
           Eio.Net.listen
             ~sw
             ~reuse_addr:true
             ~backlog:128
             env#net
             (`Tcp (Eio.Net.Ipaddr.V4.any, port))
         in
         let actual_port =
           match Eio.Net.listening_addr socket with
           | `Tcp (_, p) -> p
           | _ -> port
         in
         (match on_listen with
          | Some f -> f actual_port
          | None -> ());
         Printf.eprintf "sol-svc listening on :%d\n%!" actual_port;
         let callback _conn req body =
           let t0 = Eio.Time.now env#clock in
           let route, initial_boundary = route_and_boundary H.routes metrics_auth req in
           let route_ref = ref route in
           let boundary_ref = ref initial_boundary in
           let workload_principal = ref None in
           let observe_request status =
             emit_request_observation
               ~ot
               ~observe
               ~metrics_fns
               req
               ~route:!route_ref
               ~boundary:!boundary_ref
               ~workload_principal:!workload_principal
               ~status
               ~duration_s:(Eio.Time.now env#clock -. t0)
           in
           let send_response response =
             let body_str = response.Response.body in
             (* The service reads a request body only after routing/auth, so an early
                response (401/404/405/413/503) leaves bytes unread. Keep-alive would then
                parse the body as the next request on the same connection (request
                desynchronization). The documented contract is one request per connection;
                enforce it rather than relying on the client to close. *)
             let headers =
               response.Response.headers
               |> List.filter (fun (name, _) ->
                 not (String.equal (String.lowercase_ascii name) "connection"))
               |> fun headers ->
               Http.Header.of_list
                 (("content-length", string_of_int (String.length body_str))
                  :: ("connection", "close")
                  :: headers)
             in
             Cohttp_eio.Server.respond
               ~status:(http_status_of_int response.Response.status)
               ~headers
               ~body:(Cohttp_eio.Body.of_string body_str)
               ()
           in
           match Lifecycle.begin_request lifecycle with
           | None ->
             let response =
               { Response.status = 503; headers = [ "content-length", "0" ]; body = "" }
             in
             observe_request response.Response.status;
             send_response response
           | Some lease ->
             Fun.protect
               ~finally:(fun () -> Lifecycle.finish_request lease)
               (fun () ->
                  let route_observer = Some (fun lbl -> route_ref := lbl) in
                  let response =
                    dispatch
                      ~report_error
                      ~fetch_jwks
                      ~fetch_workload_jwks
                      ?workload_identity
                      ~routes:H.routes
                      ~metrics_renderer
                      ~metrics_auth
                      ~read_api_key
                      ~max_body_bytes
                      ?route_observer
                      ~on_boundary:(fun boundary -> boundary_ref := boundary)
                      ~on_workload_principal:(fun principal ->
                        workload_principal := principal)
                      ~ready:(fun () -> Lifecycle.ready lifecycle)
                      req
                      body
                  in
                  observe_request response.Response.status;
                  send_response response)
         in
         let server = Cohttp_eio.Server.make ~callback () in
         let server_stop, server_stop_r = Eio.Promise.create () in
         Eio.Fiber.fork_daemon ~sw (fun () ->
           await_stop ();
           Lifecycle.begin_shutdown lifecycle;
           if shutdown_delay_s > 0.0 then Eio.Time.sleep env#clock shutdown_delay_s;
           Lifecycle.begin_draining lifecycle;
           ignore (Eio.Promise.try_resolve server_stop_r ());
           `Stop_daemon);
         Eio.Fiber.first
           (fun () ->
              Cohttp_eio.Server.run
                ~stop:server_stop
                ~on_error:(fun e -> report_error ~operation:"transport" ~exn:e)
                socket
                server)
           (fun () ->
              await_stop ();
              Eio.Time.sleep env#clock (shutdown_delay_s +. drain_timeout_s);
              raise Drain_timeout))
     with
     | Drain_timeout ->
       Printf.eprintf "sol-svc: drain timeout reached, forcing shutdown\n%!");
    Option.iter (fun o -> Sol_obs.flush o) ot;
    Ok ()
  ;;
end

let run routes =
  let module H = struct
    let routes = routes
  end
  in
  let module S = Make (H) in
  S.run
;;
