open Result.Syntax
module J = Sol_cli_json

let environment = "SOL_MIGRATION_EXECUTION_BINDING"
let protocol = `Assoc [ "schema", `Int 1; "channel", `String "migration-execution" ]

type receipt =
  { binding : string
  ; target : string
  ; namespace : string
  ; name : string
  ; uid : string
  ; principal : string
  ; cluster : string
  ; endpoint : string
  ; observed_at : int
  }

type message =
  | Execution of receipt
  | No_execution of string
  | Unavailable

let valid_binding s =
  String.length s = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s
;;

let requested () =
  match Sys.getenv_opt environment with
  | Some value when valid_binding value -> Some value
  | _ -> None
;;

(* A launcher arms the channel by supplying a private duplex socket as stdin.
   Mark it close-on-exec here, before the product spawns any helper, so kubectl,
   credential helpers and other exec'd children cannot inherit the descriptor and
   consume the acknowledgment. Refuse anything that is not a socket rather than
   writing protocol bytes to a terminal or a read-only descriptor. *)
let prepare () =
  match requested () with
  | None -> Ok None
  | Some binding ->
    (try
       match (Unix.fstat Unix.stdin).Unix.st_kind with
       | Unix.S_SOCK ->
         Unix.set_close_on_exec Unix.stdin;
         Ok (Some binding)
       | _ -> Error "execution channel is not a private socket"
     with
     | Unix.Unix_error _ | Sys_error _ -> Error "execution channel unavailable")
;;

let encode = function
  | Unavailable ->
    Yojson.Safe.to_string (`Assoc [ "schema", `Int 1; "kind", `String "Unavailable" ])
  | No_execution reason ->
    Yojson.Safe.to_string
      (`Assoc
          [ "schema", `Int 1; "kind", `String "NoExecution"; "reason", `String reason ])
  | Execution r ->
    Yojson.Safe.to_string
      (`Assoc
          [ "schema", `Int 1
          ; "kind", `String "MigrationExecution"
          ; "binding", `String r.binding
          ; "target", `String r.target
          ; "namespace", `String r.namespace
          ; "name", `String r.name
          ; "uid", `String r.uid
          ; "principal", `String r.principal
          ; "cluster", `String r.cluster
          ; "endpoint", `String r.endpoint
          ; "observed_at", `Int r.observed_at
          ])
;;

let decode input =
  let* json =
    J.decode ~what:"migration execution" input
    |> Result.map_error (fun _ -> "malformed execution metadata")
  in
  let* json = Sol_cli_database_contract_data.canonical json in
  let text key = J.require ~what:"execution metadata" [ key ] J.string json in
  let* () =
    if J.field [ "schema" ] json = `Int 1
    then Ok ()
    else Error "unsupported execution schema"
  in
  match J.field [ "kind" ] json with
  | `String "Unavailable"
    when json = `Assoc [ "kind", `String "Unavailable"; "schema", `Int 1 ] ->
    Ok Unavailable
  | `String "NoExecution" ->
    let* reason = text "reason" in
    let expected =
      Yojson.Safe.from_string (encode (No_execution reason))
      |> Sol_cli_database_contract_data.canonical
    in
    if String.trim reason = "" || expected <> Ok json
    then Error "invalid execution metadata"
    else Ok (No_execution reason)
  | `String "MigrationExecution" ->
    let* binding = text "binding" in
    let* target = text "target" in
    let* namespace = text "namespace" in
    let* name = text "name" in
    let* uid = text "uid" in
    let* principal = text "principal" in
    let* cluster = text "cluster" in
    let* endpoint = text "endpoint" in
    let* observed_at =
      J.require
        ~what:"execution metadata"
        [ "observed_at" ]
        (function
          | `Int n -> Some n
          | _ -> None)
        json
    in
    let receipt =
      { binding; target; namespace; name; uid; principal; cluster; endpoint; observed_at }
    in
    let expected =
      Yojson.Safe.from_string (encode (Execution receipt))
      |> Sol_cli_database_contract_data.canonical
    in
    if
      (not (valid_binding binding))
      || List.exists
           (fun s -> String.trim s = "")
           [ target; namespace; name; uid; principal; cluster; endpoint ]
      || observed_at < 0
      || expected <> Ok json
    then Error "invalid execution metadata"
    else Ok (Execution receipt)
  | _ -> Error "unsupported execution message"
;;

let protect fn =
  try fn () with
  | Unix.Unix_error _ | Sys_error _ -> Error "execution channel unavailable"
;;

let write_line fd line =
  protect (fun () ->
    let previous = Sys.signal Sys.sigpipe Sys.Signal_ignore in
    Fun.protect
      ~finally:(fun () -> Sys.set_signal Sys.sigpipe previous)
      (fun () ->
         Unix.set_nonblock fd;
         let data = Bytes.of_string (line ^ "\n") in
         let deadline = Unix.gettimeofday () +. 5. in
         let rec loop n =
           if n = Bytes.length data
           then Ok ()
           else (
             let remaining = deadline -. Unix.gettimeofday () in
             if remaining <= 0.
             then Error "execution channel write timed out"
             else (
               let _, ready, _ = Unix.select [] [ fd ] [] remaining in
               if ready = []
               then Error "execution channel write timed out"
               else (
                 let written =
                   try Unix.single_write fd data n (Bytes.length data - n) with
                   | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
                     -> -1
                 in
                 if written = 0
                 then Error "execution channel closed"
                 else if written < 0
                 then loop n
                 else loop (n + written))))
         in
         if Bytes.length data > 8192 then Error "execution metadata too large" else loop 0))
;;

let read_line ~timeout_s fd =
  protect (fun () ->
    let buffer = Buffer.create 512 in
    let byte = Bytes.create 1 in
    let deadline = Unix.gettimeofday () +. timeout_s in
    let rec loop () =
      let remaining = deadline -. Unix.gettimeofday () in
      if remaining <= 0.
      then Error "execution channel read timed out"
      else (
        let ready, _, _ = Unix.select [ fd ] [] [] remaining in
        if ready = []
        then Error "execution channel read timed out"
        else if Unix.read fd byte 0 1 = 0
        then Error "execution channel closed"
        else if Bytes.get byte 0 = '\n'
        then Ok (Buffer.contents buffer)
        else if Buffer.length buffer >= 8192
        then Error "execution metadata too large"
        else (
          Buffer.add_char buffer (Bytes.get byte 0);
          loop ()))
    in
    loop ())
;;

let send fd event = write_line fd (encode event)

let receive ?(timeout_s = 60.) fd =
  let* line = read_line ~timeout_s fd in
  decode line
;;

let acknowledge fd = write_line fd "capture-finished"

let notify message =
  protect (fun () ->
    (* The opt-in launcher supplies a socket as stdin; [prepare] already marked it
     close-on-exec, so no helper spawned afterwards can retain the channel. *)
    let* () = send Unix.stdin message in
    let* acknowledgment = read_line ~timeout_s:60. Unix.stdin in
    if acknowledgment = "capture-finished"
    then Ok ()
    else Error "invalid capture acknowledgment")
;;

(* A normal product run has no launcher: report only when one asked. An absent or
   unusable channel never changes the product's own wait, cleanup or exit status. *)
let notify_when_requested message =
  match prepare () with
  | Ok None -> Ok ()
  | Ok (Some _) -> notify message
  | Error message -> Error message
;;
