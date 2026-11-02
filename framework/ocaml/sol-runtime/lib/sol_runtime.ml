let signals = [ Sys.sigterm; Sys.sigint ]
let registered : Unix.file_descr list Atomic.t = Atomic.make []
let previous : (int * Sys.signal_behavior) list ref = ref []
let signalled = Atomic.make false
let byte = Bytes.make 1 '\x00'

let handle signum =
  if Atomic.exchange signalled true
  then (
    List.iter (fun s -> Sys.set_signal s Sys.Signal_default) signals;
    Unix.kill (Unix.getpid ()) signum)
  else
    List.iter
      (fun w ->
         try ignore (Unix.single_write w byte 0 1) with
         | Unix.Unix_error _ -> ())
      (Atomic.get registered)
;;

let rec update f =
  let old = Atomic.get registered in
  if not (Atomic.compare_and_set registered old (f old)) then update f
;;

let registration_mutex = Mutex.create ()

let with_registration_lock f =
  Mutex.lock registration_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock registration_mutex) f
;;

let register w =
  with_registration_lock (fun () ->
    if Atomic.get registered = []
    then (
      Atomic.set signalled false;
      previous := List.map (fun s -> s, Sys.signal s (Sys.Signal_handle handle)) signals);
    update (fun ws -> w :: ws))
;;

let unregister w =
  with_registration_lock (fun () ->
    update (List.filter (fun w' -> w' <> w));
    if Atomic.get registered = []
    then (
      List.iter (fun (s, behavior) -> Sys.set_signal s behavior) !previous;
      previous := [];
      Atomic.set signalled false))
;;

let close_noerr fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let install_signal_handler ~sw resolver =
  let r, w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock w;
  register w;
  Eio.Switch.on_release sw (fun () ->
    unregister w;
    close_noerr w;
    close_noerr r);
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio_unix.await_readable r;
    let buf = Bytes.create 1 in
    (try ignore (Unix.read r buf 0 1) with
     | Unix.Unix_error _ -> ());
    ignore (Eio.Promise.try_resolve resolver ());
    `Stop_daemon)
;;

let setting name =
  match Sys.getenv_opt name with
  | None -> None
  | Some value ->
    (match String.trim value with
     | "" -> None
     | trimmed -> Some trimmed)
;;

let strip_line_ending value =
  let value =
    if String.ends_with ~suffix:"\n" value
    then String.sub value 0 (String.length value - 1)
    else value
  in
  if String.ends_with ~suffix:"\r" value
  then String.sub value 0 (String.length value - 1)
  else value
;;

let mounted_secrets_dir = "/var/run/sol/secrets"

let secret_file ~name =
  match setting (name ^ "_FILE") with
  | Some path -> Some path
  | None ->
    let dir = Option.value (setting "SOL_SECRETS_DIR") ~default:mounted_secrets_dir in
    let path = Filename.concat dir name in
    if Sys.file_exists path then Some path else None
;;

let read_secret_file path =
  try
    let value = In_channel.with_open_bin path In_channel.input_all |> strip_line_ending in
    if String.equal value "" then Ok None else Ok (Some value)
  with
  | Sys_error message -> Error (Printf.sprintf "could not read %s: %s" path message)
;;

let secret_result name =
  match secret_file ~name with
  | Some path -> read_secret_file path
  | None -> Ok (setting name)
;;

let secret name =
  match secret_result name with
  | Ok value -> value
  | Error _ -> None
;;

let contains_substring ~needle haystack =
  let needle_length = String.length needle
  and haystack_length = String.length haystack in
  let rec go i =
    if i + needle_length > haystack_length
    then false
    else if String.equal (String.sub haystack i needle_length) needle
    then true
    else go (i + 1)
  in
  go 0
;;
