type level = Obs_eio.level =
  | Debug
  | Info
  | Warn
  | Error

type span = Obs_eio.span

type t =
  { ot : Obs_eio.t
  ; backend : Obs_eio.backend
  ; renderer : unit -> string
  ; flushers : (float -> unit) list
  }

let setting name =
  match Sys.getenv_opt name with
  | None -> None
  | Some value ->
    (match String.trim value with
     | "" -> None
     | trimmed -> Some trimmed)
;;

let tempo_headers () =
  match setting "TEMPO_HEADERS" with
  | None -> []
  | Some raw ->
    raw
    |> String.split_on_char ','
    |> List.filter_map (fun pair ->
      match String.index_opt pair '=' with
      | None -> None
      | Some at ->
        let key = String.sub pair 0 at |> String.trim in
        let value =
          String.sub pair (at + 1) (String.length pair - at - 1) |> String.trim
        in
        if key = "" then None else Some (key, value))
;;

let stdout_logs =
  { Obs_eio.stdout with emit_metric = (fun _ -> ()); declare_metric = (fun _ -> ()) }
;;

let taxonomy =
  [ "SOL_WORKSPACE", "workspace"
  ; "SOL_ENV", "env"
  ; "SOL_DOMAIN", "domain"
  ; "SOL_SERVICE", "service"
  ; "SOL_PRIMITIVE", "primitive"
  ; "SOL_RELEASE", "release"
  ]
;;

let taxonomy_labels = List.map snd taxonomy

let identity () =
  List.filter_map
    (fun (var, label) -> Option.map (fun value -> label, value) (setting var))
    taxonomy
;;

let dedupe keys =
  List.fold_left (fun acc key -> if List.mem key acc then acc else acc @ [ key ]) [] keys
;;

let of_env ~sw ~net ~clock ~mono_clock ~service ?(context = []) () =
  let identity = identity () in
  let service =
    match List.assoc_opt "service" identity with
    | Some value -> value
    | None -> service
  in
  let fields =
    ("service", service)
    :: List.filter (fun (key, _) -> not (String.equal key "service")) (context @ identity)
  in
  let label_names =
    fields
    |> List.map fst
    |> List.filter (fun name -> not (String.equal name "service"))
    |> dedupe
    |> List.map Obs_loki.stream_label_exn
  in
  let log_backend, loki_flush =
    match setting "LOKI_URL" with
    | None -> Obs_eio.stdout, []
    | Some url ->
      let loki = Obs_loki.create ~sw ~net ~clock ~url ~label_names () in
      ( Obs_eio.compose stdout_logs (Obs_loki.backend loki)
      , [ (fun timeout -> Obs_loki.flush ~timeout loki) ] )
  in
  let prom_backend, renderer = Obs_prometheus.create () in
  let backend = Obs_eio.compose log_backend prom_backend in
  let backend, tempo_flush =
    match setting "TEMPO_URL" with
    | None -> backend, []
    | Some url ->
      let tempo = Obs_tempo.create ~sw ~net ~clock ~url ~headers:(tempo_headers ()) () in
      ( Obs_eio.compose backend (Obs_tempo.backend tempo)
      , [ (fun timeout -> Obs_tempo.flush ~timeout tempo) ] )
  in
  let ot = Obs_eio.create ~service ~mono_clock ~backend () in
  let ot = Obs_eio.with_context ot fields in
  { ot; backend; renderer; flushers = loki_flush @ tempo_flush }
;;

let flush ?(timeout = 5.0) t = List.iter (fun f -> f timeout) t.flushers
let log_debug t ?fields msg = Obs_eio.log_standalone t.ot Debug ?fields msg
let log_info t ?fields msg = Obs_eio.log_standalone t.ot Info ?fields msg
let log_warn t ?fields msg = Obs_eio.log_standalone t.ot Warn ?fields msg
let log_error t ?fields msg = Obs_eio.log_standalone t.ot Error ?fields msg
let with_span t ?parent name f = Obs_eio.with_span t.ot ?parent name f
let log = Obs_eio.log
let current_trace_context = Obs_eio.current_trace_context

let trace_id_string (ctx : Obs_trace.t) =
  let hi, lo = ctx.trace_id in
  Printf.sprintf "%016Lx%016Lx" hi lo
;;

let counter t ~name ~help ~label_names =
  Obs_eio.register_counter t.ot ~name ~help ~label_names
;;

let gauge t ~name ~help ~label_names =
  Obs_eio.register_gauge t.ot ~name ~help ~label_names
;;

let histogram t ~name ~help ~label_names =
  Obs_eio.register_histogram t.ot ~name ~help ~label_names
;;

let with_context t fields = { t with ot = Obs_eio.with_context t.ot fields }
let obs_eio t = t.ot
let metrics_renderer t = t.renderer
let backend_and_renderer t = t.backend, t.renderer
