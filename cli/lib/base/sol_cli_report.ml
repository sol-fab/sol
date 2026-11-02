let emit level text = Logs.msg level (fun m -> m "%s" text)
let app fmt = Printf.ksprintf (emit Logs.App) fmt
let warn fmt = Printf.ksprintf (emit Logs.Warning) fmt
let err fmt = Printf.ksprintf (emit Logs.Error) fmt

let without_final_newline text =
  let n = String.length text in
  if n > 0 && text.[n - 1] = '\n' then String.sub text 0 (n - 1) else text
;;

let app_block text = emit Logs.App (without_final_newline text)
let err_block text = emit Logs.Error (without_final_newline text)

let terminal_on channel =
  let report _src level ~over k msgf =
    ignore level;
    msgf (fun ?header:_ ?tags:_ fmt ->
      Format.kasprintf
        (fun text ->
           output_string channel text;
           output_char channel '\n';
           flush channel;
           over ();
           k ())
        fmt)
  in
  { Logs.report }
;;

let terminal =
  let report _src level ~over k msgf =
    let channel =
      match level with
      | Logs.App -> stdout
      | Logs.Error | Logs.Warning | Logs.Info | Logs.Debug -> stderr
    in
    msgf (fun ?header:_ ?tags:_ fmt ->
      Format.kasprintf
        (fun text ->
           output_string channel text;
           output_char channel '\n';
           flush channel;
           over ();
           k ())
        fmt)
  in
  { Logs.report }
;;

let install_terminal () =
  Logs.set_level (Some Logs.Warning);
  Logs.set_reporter terminal
;;

let install_terminal_stderr () =
  Logs.set_level (Some Logs.Warning);
  Logs.set_reporter (terminal_on stderr)
;;

let collect f =
  let recorded = ref [] in
  let report _src level ~over k msgf =
    msgf (fun ?header:_ ?tags:_ fmt ->
      Format.kasprintf
        (fun text ->
           recorded := (level, text) :: !recorded;
           over ();
           k ())
        fmt)
  in
  let previous = Logs.reporter () in
  let previous_level = Logs.level () in
  Logs.set_level (Some Logs.Warning);
  Logs.set_reporter { Logs.report };
  let result =
    Fun.protect
      ~finally:(fun () ->
        Logs.set_reporter previous;
        Logs.set_level previous_level)
      f
  in
  result, List.rev !recorded
;;
