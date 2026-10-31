open Result.Syntax

type request =
  { profile : string option
  ; region : string
  ; service : string
  ; function_name : string
  ; image : string
  ; role_arn : string
  ; unit : string
  ; schedule : string option
  ; timezone : string option
  ; scheduler_role_arn : string option
  ; external_env : (string * string) list
  ; record : string option
  ; run : string list -> (Sol_cli_aws_lambda_common.output, string) result
  }

type observed =
  { function_name : string
  ; version : string
  ; alias : string
  ; tags : (string * string) list
  ; invocation_status : string
  }

type release =
  { region : string
  ; service : string
  ; function_name : string
  ; version : string
  ; alias : string
  ; image : string
  ; role_arn : string
  ; scheduler : Sol_cli_aws_scheduler.release option
  }

type failure = Sol_cli_aws_lambda_common.failure =
  | Refused of string
  | Provider of string
  | Partial of string
  | Unknown of string

let failure_to_string = Sol_cli_aws_lambda_common.failure_to_string

(* This tag value is the function adapter's ownership class. It is deliberately distinct
   from the HTTP adapter's, so neither lifecycle can adopt or delete the other's
   function even when the Sol service name normalizes to the same Lambda name. *)
let ownership_tag = "lambda-fn-experiment"

let scope (r : request) : Sol_cli_aws_lambda_common.scope =
  { profile = r.profile; region = r.region; run = r.run }
;;

let aws (r : request) args =
  Sol_cli_aws_lambda_common.aws ~profile:r.profile ~region:r.region args
;;

let owns ~function_name tags =
  List.assoc_opt "sol-owned" tags = Some ownership_tag
  && List.assoc_opt "sol-service" tags = Some function_name
  &&
  match List.assoc_opt "sol-workspace" tags with
  | Some workspace ->
    String.equal workspace (Sol_cli_aws_lambda_common.workspace_label ())
  | None -> true
;;

let preflight (r : request) =
  let* () =
    if String.trim r.region = "" then Error (Refused "region is empty") else Ok ()
  in
  let* () =
    if String.trim r.service = "" then Error (Refused "service is empty") else Ok ()
  in
  let* () =
    if String.trim r.function_name = ""
    then Error (Refused "function name is empty")
    else Ok ()
  in
  let* () =
    if String.trim r.role_arn = "" then Error (Refused "role ARN is required") else Ok ()
  in
  let* () =
    if String.trim r.unit = "" then Error (Refused "unit is required") else Ok ()
  in
  Sol_cli_aws_lambda_common.valid_image r.image
;;

let release_json (r : release) =
  `Assoc
    [ "kind", `String "fn"
    ; "region", `String r.region
    ; "service", `String r.service
    ; "function_name", `String r.function_name
    ; "version", `String r.version
    ; "alias", `String r.alias
    ; "image", `String r.image
    ; "role_arn", `String r.role_arn
    ; ( "scheduler"
      , match r.scheduler with
        | None -> `Null
        | Some scheduler -> Sol_cli_aws_scheduler.to_json scheduler )
    ]
;;

let observed_json (o : observed) =
  `Assoc
    [ "kind", `String "fn"
    ; "function_name", `String o.function_name
    ; "version", `String o.version
    ; "alias", `String o.alias
    ; "invocation_status", `String o.invocation_status
    ; "tags", `Assoc (List.map (fun (k, v) -> k, `String v) o.tags)
    ]
;;

let write_record ~path r = Sol_cli_aws_lambda_common.write_json ~path (release_json r)

let read_record ~path =
  let* json = Sol_cli_aws_lambda_common.read_json ~path in
  let field name =
    Sol_cli_json.string (Sol_cli_json.field [ name ] json)
    |> Option.to_result ~none:(name ^ " missing")
  in
  let* kind = field "kind" in
  let* () =
    if kind = "fn"
    then Ok ()
    else
      Error
        (Printf.sprintf
           "release record kind %S is not an AWS Lambda run-once function record"
           kind)
  in
  let* region = field "region" in
  let* service = field "service" in
  let* function_name = field "function_name" in
  let* version = field "version" in
  let* alias = field "alias" in
  let* image = field "image" in
  let* role_arn = field "role_arn" in
  let scheduler =
    match Sol_cli_json.field [ "scheduler" ] json with
    | `Null -> Ok None
    | scheduler_json ->
      Sol_cli_aws_scheduler.of_json scheduler_json
      |> Result.map Option.some
      |> Result.map_error (fun message -> "scheduler: " ^ message)
  in
  let* scheduler = scheduler in
  Ok { region; service; function_name; version; alias; image; role_arn; scheduler }
;;

(* The observed state is read back from the provider: the alias is the serving identity,
   and the tags are the ownership proof destroy will require later. *)
let describe_owned (r : request) =
  match Sol_cli_aws_lambda_common.describe (scope r) ~function_name:r.function_name with
  | Error (`Provider m) | Error (`Unknown m) -> Error (Unknown m)
  | Ok (`Present (version, tags)) ->
    if owns ~function_name:r.function_name tags
    then Ok (version, tags)
    else
      Error
        (Refused
           (Printf.sprintf
              "Lambda function exists without this adapter's ownership tags (fn=%s \
               tags=%s)"
              r.function_name
              (Yojson.Safe.to_string
                 (`Assoc (List.map (fun (k, v) -> k, `String v) tags)))))
;;

let invoke (r : request) ~qualifier =
  if String.trim qualifier = ""
  then Error (Refused "invoke qualifier is required")
  else (
    let invocation path =
      match
        r.run
          (aws
             r
             [ "lambda"
             ; "invoke"
             ; "--function-name"
             ; r.function_name
             ; "--qualifier"
             ; qualifier
             ; "--cli-binary-format"
             ; "raw-in-base64-out"
             ; "--payload"
             ; "{}"
             ; path
             ])
      with
      | Error e -> Error (Provider e)
      | Ok o ->
        let* metadata =
          Sol_cli_json.decode ~what:"Lambda invoke" o.stdout
          |> Result.map_error (fun m -> Unknown m)
        in
        (* FunctionError is how a synchronous invocation reports a handler failure even
           when the transport itself returned 200. It must fail the lifecycle step. *)
        let* () =
          match Sol_cli_json.string (Sol_cli_json.field [ "FunctionError" ] metadata) with
          | Some error when error <> "" ->
            Error (Provider (Printf.sprintf "Lambda invocation FunctionError: %s" error))
          | _ -> Ok ()
        in
        let* status_code =
          Sol_cli_json.int (Sol_cli_json.field [ "StatusCode" ] metadata)
          |> Option.to_result ~none:"Lambda invoke returned no StatusCode"
          |> Result.map_error (fun m -> Unknown m)
        in
        let* () =
          if status_code = 200
          then Ok ()
          else Error (Provider (Printf.sprintf "Lambda invocation status %d" status_code))
        in
        let* body = Sol_cli_fs.read_file path |> Result.map_error (fun m -> Unknown m) in
        let* response =
          Sol_cli_json.decode ~what:"Lambda invoke response" body
          |> Result.map_error (fun m -> Unknown m)
        in
        (match Sol_cli_json.string (Sol_cli_json.field [ "status" ] response) with
         | Some "ok" -> Ok "ok"
         | Some status ->
           Error
             (Provider
                (Printf.sprintf
                   "Lambda function returned status %S; expected {status:\"ok\"}"
                   status))
         | None ->
           Error
             (Provider
                "Lambda function response has no status field; expected {status:\"ok\"}"))
    in
    match
      Sol_cli_fs.with_temp_file
        ~prefix:"sol-lambda-fn-invoke-"
        ~suffix:".json"
        ""
        invocation
    with
    | Ok result -> result
    | Error message -> Error (Unknown message))
;;

let environment (r : request) =
  [ "SOL_UNIT", r.unit; "SOL_PRIMITIVE", "fn" ] @ r.external_env
;;

let deploy (r : request) =
  let* () = preflight r in
  let* names =
    Sol_cli_aws_lambda_common.inventory (scope r) |> Result.map_error (fun m -> Unknown m)
  in
  let* existing =
    if List.mem r.function_name names
    then
      let* _ = describe_owned r in
      Ok true
    else Ok false
  in
  let provisional =
    { region = r.region
    ; service = r.service
    ; function_name = r.function_name
    ; version = ""
    ; alias = "live"
    ; image = r.image
    ; role_arn = r.role_arn
    ; scheduler = None
    }
  in
  let* () =
    match r.record with
    | None -> Ok ()
    | Some path ->
      write_record ~path provisional
      |> Result.map_error (fun m -> Provider ("provisional ownership record: " ^ m))
  in
  let* () =
    match r.schedule with
    | Some _ -> Ok ()
    | None ->
      Sol_cli_aws_scheduler.destroy_by_unit
        { profile = r.profile
        ; region = r.region
        ; unit = r.unit
        ; function_name = r.function_name
        ; schedule = ""
        ; timezone = None
        ; role_arn = ""
        ; run = r.run
        }
      |> Result.map_error (fun message -> Provider message)
  in
  let* () =
    Sol_cli_aws_lambda_common.ensure_function
      (scope r)
      ~function_name:r.function_name
      ~image:r.image
      ~role_arn:r.role_arn
      ~environment:(environment r)
      ~tags:
        [ "sol-owned", ownership_tag
        ; "sol-service", r.function_name
        ; "sol-workspace", Sol_cli_aws_lambda_common.workspace_label ()
        ]
      ~existing
      ()
  in
  let* () =
    Sol_cli_aws_lambda_common.verify_role
      ~expected:r.role_arn
      (scope r)
      ~function_name:r.function_name
    |> Result.map_error (function
      | Sol_cli_aws_lambda_common.Refused message -> Partial message
      | other -> other)
  in
  let* version =
    Sol_cli_aws_lambda_common.publish_version (scope r) ~function_name:r.function_name
  in
  let* () =
    Sol_cli_aws_lambda_common.put_alias (scope r) ~function_name:r.function_name ~version
  in
  let release =
    { region = r.region
    ; service = r.service
    ; function_name = r.function_name
    ; version
    ; alias = "live"
    ; image = r.image
    ; role_arn = r.role_arn
    ; scheduler = None
    }
  in
  let* release =
    match r.schedule, r.scheduler_role_arn with
    | None, _ -> Ok release
    | Some _, None ->
      Error
        (Refused
           "scheduled serverless function has no provisioned scheduler identity; \
            the             authorization root must establish a dedicated scheduler role")
    | Some schedule, Some role_arn ->
      let* scheduler =
        Sol_cli_aws_scheduler.deploy
          { profile = r.profile
          ; region = r.region
          ; unit = r.unit
          ; function_name = r.function_name
          ; schedule
          ; timezone = r.timezone
          ; role_arn
          ; run = r.run
          }
        |> Result.map_error (fun message -> Provider message)
      in
      Ok { release with scheduler = Some scheduler }
  in
  (* Record the alias that is now live before invoking it. A first deploy whose
     invocation fails must still leave an ownership record, and an update must not leave
     the previous version recorded while the provider serves the new one. *)
  let* () =
    match r.record with
    | None -> Ok ()
    | Some path -> write_record ~path release |> Result.map_error (fun m -> Provider m)
  in
  let* () = invoke r ~qualifier:"live" |> Result.map (fun _ -> ()) in
  Ok release
;;

let rollback (r : request) ~version ~on_alias_moved =
  let* () =
    if String.trim version = ""
    then Error (Refused "rollback version is required")
    else Ok ()
  in
  (* A rollback moves the live alias, so it establishes ownership and the recorded
     execution role before mutating. *)
  let* _, tags = describe_owned r in
  let* () =
    Sol_cli_aws_lambda_common.verify_role
      ~expected:r.role_arn
      (scope r)
      ~function_name:r.function_name
  in
  let* () =
    Sol_cli_aws_lambda_common.put_alias (scope r) ~function_name:r.function_name ~version
  in
  (* The alias has moved. Record that provider state before the invocation, so a failed
     FunctionError check cannot leave the release record naming the old version. *)
  let* () =
    on_alias_moved version
    |> Result.map_error (fun m ->
      Partial ("alias moved but release record update failed: " ^ m))
  in
  let* invocation_status = invoke r ~qualifier:"live" in
  Ok { function_name = r.function_name; version; alias = "live"; tags; invocation_status }
;;

let destroy (r : request) ~profile ~region ~service ~record =
  let* expected = read_record ~path:record |> Result.map_error (fun m -> Refused m) in
  let* function_name =
    Sol_cli_aws_lambda_common.provider_service_of service
    |> Result.map_error (fun failure -> Refused (failure_to_string failure))
  in
  let* () =
    if
      expected.region = region
      && expected.service = service
      && expected.function_name = function_name
    then Ok ()
    else
      Error
        (Refused
           "release record does not match the target region, service, and provider \
            function name")
  in
  let s = { r with profile; region } in
  let* names =
    Sol_cli_aws_lambda_common.inventory (scope s) |> Result.map_error (fun m -> Unknown m)
  in
  if not (List.mem expected.function_name names)
  then Ok ()
  else (
    let owned = { s with function_name = expected.function_name } in
    let* () = describe_owned owned |> Result.map (fun _ -> ()) in
    let* () =
      Sol_cli_aws_lambda_common.verify_role
        ~expected:expected.role_arn
        (scope owned)
        ~function_name:expected.function_name
    in
    let* () =
      match expected.scheduler with
      | None -> Ok ()
      | Some scheduler ->
        Sol_cli_aws_scheduler.destroy
          { profile = s.profile
          ; region = s.region
          ; unit = ""
          ; function_name = expected.function_name
          ; schedule = ""
          ; timezone = None
          ; role_arn = ""
          ; run = s.run
          }
          scheduler
        |> Result.map_error (fun message -> Partial message)
    in
    (* Deleting the function also deletes its versions and the live alias. There is no
       Function URL to remove, and no event source mapping is created by this adapter. *)
    let* () =
      s.run
        (aws s [ "lambda"; "delete-function"; "--function-name"; expected.function_name ])
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun m -> Partial m)
    in
    let* names =
      Sol_cli_aws_lambda_common.inventory (scope s)
      |> Result.map_error (fun m -> Unknown m)
    in
    if List.mem expected.function_name names
    then Error (Unknown "function remains after delete")
    else Ok ())
;;
