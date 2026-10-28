open Result.Syntax

type output =
  { stdout : string
  ; stderr : string
  }

let run argv =
  Sol_cli_process.run (Sol_cli_process.cmd argv)
  |> Result.map (fun (o : Sol_cli_process.output) ->
    ({ stdout = o.stdout; stderr = o.stderr } : output))
  |> Result.map_error Sol_cli_process.error_to_string
;;

let http ~url ~token =
  let config = Filename.temp_file "sol-serverless-curl-" ".conf" in
  let cleanup () = Sol_cli_fs.remove_reporting config in
  let write () =
    match token with
    | None -> Ok ()
    | Some token ->
      Sol_cli_fs.write_atomic
        ~perm:0o600
        config
        (Printf.sprintf "header = \"Authorization: Bearer %s\"\n" token)
  in
  Fun.protect ~finally:cleanup (fun () ->
    let* () = write () in
    let* out =
      run
        [ "curl"
        ; "--silent"
        ; "--show-error"
        ; "--config"
        ; config
        ; "--output"
        ; "-"
        ; "--write-out"
        ; "\\n%{http_code}"
        ; url
        ]
    in
    match String.rindex_opt out.stdout '\n' with
    | None -> Error "curl returned no HTTP status"
    | Some at ->
      let body = String.sub out.stdout 0 at in
      let status = String.sub out.stdout (at + 1) (String.length out.stdout - at - 1) in
      (match int_of_string_opt (String.trim status) with
       | Some status -> Ok (status, body)
       | None -> Error "curl returned a non-numeric HTTP status"))
;;
