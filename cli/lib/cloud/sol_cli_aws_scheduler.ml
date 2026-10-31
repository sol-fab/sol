open Result.Syntax

type output = Sol_cli_aws_lambda_common.output

type request =
  { profile : string option
  ; region : string
  ; unit : string
  ; function_name : string
  ; schedule : string
  ; timezone : string option
  ; role_arn : string
  ; run : string list -> (output, string) result
  }

type release =
  { schedule_name : string
  ; expression : string
  ; timezone : string
  ; role_arn : string
  ; target_arn : string
  }

let to_json (r : release) =
  `Assoc
    [ "schedule_name", `String r.schedule_name
    ; "expression", `String r.expression
    ; "timezone", `String r.timezone
    ; "role_arn", `String r.role_arn
    ; "target_arn", `String r.target_arn
    ]
;;

let of_json json =
  let field name =
    Sol_cli_json.string (Sol_cli_json.field [ name ] json)
    |> Option.to_result ~none:(name ^ " missing")
  in
  let open Result.Syntax in
  let* schedule_name = field "schedule_name" in
  let* expression = field "expression" in
  let* timezone = field "timezone" in
  let* role_arn = field "role_arn" in
  let* target_arn = field "target_arn" in
  Ok { schedule_name; expression; timezone; role_arn; target_arn }
;;

let aws (r : request) args =
  r.run ("aws" :: "--profile" :: Option.value r.profile ~default:"default" :: args)
;;

let run_trim r args =
  let* output = aws r args in
  let value = String.trim output.stdout in
  if value = "" then Error "AWS returned an empty value" else Ok value
;;

let write_temp name json =
  let path = Filename.temp_file "sol-scheduler-" name in
  let oc = open_out path in
  output_string oc (Yojson.Safe.to_string json);
  close_out oc;
  path
;;

let schedule_name (r : request) =
  let digest =
    Digestif.SHA1.digest_string r.unit
    |> Digestif.SHA1.to_hex
    |> fun hex -> String.sub hex 0 8
  in
  "sol-schedule-" ^ digest
;;

let eventbridge_expression cron =
  match String.split_on_char ' ' (String.trim cron) with
  | [ minute; hour; dom; month; dow ] ->
    let dom, dow =
      if dom = "*" && dow = "*"
      then "?", "*"
      else if dom = "*"
      then "?", dow
      else if dow = "*"
      then dom, "?"
      else dom, dow
    in
    Ok (Printf.sprintf "cron(%s %s %s %s %s *)" minute hour dom month dow)
  | _ ->
    Error
      (Printf.sprintf
         "schedule %S is not a five-field cron expression; EventBridge Scheduler \
          requires a five-field expression that Sol translates"
         cron)
;;

let timezone (r : request) = Option.value r.timezone ~default:"UTC"

let create_or_update r ~name ~expression ~role_arn ~target_arn ~timezone =
  let target = `Assoc [ "Arn", `String target_arn; "RoleArn", `String role_arn ] in
  let target_path = write_temp "target.json" target in
  let args verb =
    [ "scheduler"
    ; verb
    ; "--name"
    ; name
    ; "--schedule-expression"
    ; expression
    ; "--schedule-expression-timezone"
    ; timezone
    ; "--flexible-time-window"
    ; "Mode=OFF"
    ; "--target"
    ; "file://" ^ target_path
    ]
  in
  let* exists =
    match aws r [ "scheduler"; "get-schedule"; "--name"; name ] with
    | Ok _ -> Ok true
    | Error _ -> Ok false
  in
  if exists
  then aws r (args "update-schedule") |> Result.map (fun _ -> ())
  else aws r (args "create-schedule") |> Result.map (fun _ -> ())
;;

let deploy (r : request) =
  let* expression = eventbridge_expression r.schedule in
  let* () =
    if String.trim r.role_arn = ""
    then
      Error
        "scheduled serverless function has no provisioned scheduler identity; the \
         authorization root must establish a dedicated scheduler role"
    else Ok ()
  in
  let* function_arn =
    run_trim
      r
      [ "lambda"
      ; "get-function"
      ; "--function-name"
      ; r.function_name
      ; "--query"
      ; "Configuration.FunctionArn"
      ; "--output"
      ; "text"
      ]
  in
  let target_arn = function_arn ^ ":live" in
  let name = schedule_name r in
  let timezone = timezone r in
  let* () =
    create_or_update r ~name ~expression ~role_arn:r.role_arn ~target_arn ~timezone
    |> Result.map_error (fun message ->
      Printf.sprintf "could not configure EventBridge schedule: %s" message)
  in
  let release =
    { schedule_name = name; expression; timezone; role_arn = r.role_arn; target_arn }
  in
  let* observed =
    aws
      r
      [ "scheduler"
      ; "get-schedule"
      ; "--name"
      ; name
      ; "--query"
      ; "{Role:Target.RoleArn,Arn:Target.Arn}"
      ; "--output"
      ; "json"
      ]
    |> Result.map_error (fun message ->
      Printf.sprintf "schedule verification failed: %s" message)
  in
  let* json =
    Sol_cli_json.decode ~what:"EventBridge schedule" observed.stdout
    |> Result.map_error (fun message -> "EventBridge schedule is invalid: " ^ message)
  in
  let* actual_role =
    Sol_cli_json.string (Sol_cli_json.field [ "Role" ] json)
    |> Option.to_result ~none:"EventBridge schedule has no execution role"
  in
  let* actual_target =
    Sol_cli_json.string (Sol_cli_json.field [ "Arn" ] json)
    |> Option.to_result ~none:"EventBridge schedule has no target ARN"
  in
  let* () =
    if String.equal actual_role r.role_arn
    then Ok ()
    else
      Error
        (Printf.sprintf
           "EventBridge schedule role is %S, expected %S"
           actual_role
           r.role_arn)
  in
  let* () =
    if String.equal actual_target target_arn
    then Ok ()
    else
      Error
        (Printf.sprintf
           "EventBridge schedule target is %S, expected %S"
           actual_target
           target_arn)
  in
  Ok release
;;

let destroy_by_unit (r : request) =
  let name = schedule_name r in
  match aws r [ "scheduler"; "get-schedule"; "--name"; name ] with
  | Error _ -> Ok ()
  | Ok _ ->
    aws r [ "scheduler"; "delete-schedule"; "--name"; name ] |> Result.map (fun _ -> ())
;;

let destroy (r : request) (release : release) =
  match aws r [ "scheduler"; "get-schedule"; "--name"; release.schedule_name ] with
  | Error _ -> Ok ()
  | Ok _ ->
    aws r [ "scheduler"; "delete-schedule"; "--name"; release.schedule_name ]
    |> Result.map (fun _ -> ())
;;
