type t =
  { program : string
  ; args : string list
  ; timeout_s : float
  }

type outcome =
  | Completed of int
  | Timed_out
  | Unavailable of string

type execution =
  { outcome : outcome
  ; stdout_path : string
  ; stderr_path : string
  ; started_at : float
  ; finished_at : float
  ; record_path : string
  }

let rec wait pid =
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED code -> Completed code
  | _, Unix.WSIGNALED signal | _, Unix.WSTOPPED signal -> Completed (128 + abs signal)
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait pid
;;

let write_json path document =
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
  let channel = Unix.out_channel_of_descr fd in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () ->
       Yojson.Safe.pretty_to_channel channel document;
       output_char channel '\n')
;;

let read path = In_channel.with_open_bin path In_channel.input_all

(* GNU timeout owns process-group termination, including shell descendants. Files
   retain partial diagnostics on timeout; no argv or environment values are logged. *)
let run ~directory ~index command =
  let base = Filename.concat directory (Printf.sprintf "command-%03d" index) in
  let stdout_path = base ^ ".stdout"
  and stderr_path = base ^ ".stderr" in
  let open_output path =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
  in
  let stdout_fd = open_output stdout_path in
  let stderr_fd = open_output stderr_path in
  let stdin_fd = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let started_at = Unix.gettimeofday () in
  let outcome =
    Fun.protect
      ~finally:(fun () -> List.iter Unix.close [ stdin_fd; stdout_fd; stderr_fd ])
      (fun () ->
         try
           let argv =
             [ "timeout"
             ; "--signal=TERM"
             ; "--kill-after=2s"
             ; Printf.sprintf "%.17gs" command.timeout_s
             ; command.program
             ]
             @ command.args
           in
           match
             Unix.create_process
               "timeout"
               (Array.of_list argv)
               stdin_fd
               stdout_fd
               stderr_fd
             |> wait
           with
           | Completed (124 | 137) -> Timed_out
           | outcome -> outcome
         with
         | Unix.Unix_error (error, fn, _) ->
           Unavailable (fn ^ ": " ^ Unix.error_message error))
  in
  let execution =
    { outcome
    ; stdout_path
    ; stderr_path
    ; started_at
    ; finished_at = Unix.gettimeofday ()
    ; record_path = base ^ ".json"
    }
  in
  let status =
    match outcome with
    | Completed n -> `Assoc [ "exit_code", `Int n ]
    | Timed_out -> `String "TIMEOUT"
    | Unavailable reason -> `Assoc [ "unavailable", `String reason ]
  in
  write_json
    execution.record_path
    (`Assoc
        [ "status", status
        ; "started_at", `Float started_at
        ; "finished_at", `Float execution.finished_at
        ; "stdout", `String (Filename.basename stdout_path)
        ; "stderr", `String (Filename.basename stderr_path)
        ]);
  execution
;;
