open Result.Syntax

type request =
  { profile : string option
  ; region : string
  ; service : string
  ; function_name : string
  ; image : string
  ; role_arn : string
  ; unit : string
  ; http_path : string
  ; record : string option
  ; run : string list -> (Sol_cli_aws_lambda_common.output, string) result
  }

type release =
  { region : string
  ; service : string
  ; function_name : string
  ; version : string
  ; alias : string
  ; url : string
  ; image : string
  ; role_arn : string
  ; http_path : string
  }

type failure = Sol_cli_aws_lambda_common.failure =
  | Refused of string
  | Provider of string
  | Partial of string
  | Unknown of string

let failure_to_string = Sol_cli_aws_lambda_common.failure_to_string

(* Distinct from both the -svc adapter and the run-once -fn adapter: a record whose
   kind or ownership tag says another lifecycle produced this function must never be
   adopted or deleted by this one. *)
let ownership_tag = "lambda-fn-http-experiment"

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
  let nonempty name value =
    if String.trim value = "" then Error (Refused (name ^ " is empty")) else Ok ()
  in
  let* () = nonempty "region" r.region in
  let* () = nonempty "service" r.service in
  let* () = nonempty "function name" r.function_name in
  let* () = nonempty "role ARN" r.role_arn in
  let* () = nonempty "unit" r.unit in
  let* () =
    if String.length r.http_path > 0 && r.http_path.[0] = '/'
    then Ok ()
    else Error (Refused "http_path must start with \"/\"")
  in
  Sol_cli_aws_lambda_common.valid_image r.image
;;

let release_json (r : release) =
  `Assoc
    [ "kind", `String "fn_http"
    ; "provider", `String "aws"
    ; "region", `String r.region
    ; "service", `String r.service
    ; "function_name", `String r.function_name
    ; "version", `String r.version
    ; "alias", `String r.alias
    ; "url", `String r.url
    ; "image", `String r.image
    ; "role_arn", `String r.role_arn
    ; "http_path", `String r.http_path
    ; "http_exposure", `String "public"
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
    if kind = "fn_http"
    then Ok ()
    else
      Error
        (Printf.sprintf
           "release record kind %S is not an AWS Lambda HTTP function record"
           kind)
  in
  let* region = field "region" in
  let* service = field "service" in
  let* function_name = field "function_name" in
  let* version = field "version" in
  let* alias = field "alias" in
  let* url = field "url" in
  let* image = field "image" in
  let* role_arn = field "role_arn" in
  let* http_path = field "http_path" in
  Ok { region; service; function_name; version; alias; url; image; role_arn; http_path }
;;

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

let ready (r : request) =
  let payload =
    Yojson.Safe.to_string
      (`Assoc
          [ "rawPath", `String "/readyz"
          ; "rawQueryString", `String ""
          ; "headers", `Assoc []
          ; "requestContext", `Assoc [ "http", `Assoc [ "method", `String "GET" ] ]
          ; "body", `String ""
          ; "isBase64Encoded", `Bool false
          ])
  in
  let invoke outfile =
    match
      r.run
        (aws
           r
           [ "lambda"
           ; "invoke"
           ; "--function-name"
           ; r.function_name
           ; "--qualifier"
           ; "live"
           ; "--cli-binary-format"
           ; "raw-in-base64-out"
           ; "--payload"
           ; payload
           ; outfile
           ])
    with
    | Error message -> Error (Unknown ("Lambda invoke failed: " ^ message))
    | Ok output ->
      let* metadata =
        Sol_cli_json.decode ~what:"Lambda invoke" output.stdout
        |> Result.map_error (fun message -> Unknown message)
      in
      let* () =
        match Sol_cli_json.string (Sol_cli_json.field [ "FunctionError" ] metadata) with
        | Some error when error <> "" ->
          Error (Unknown ("Lambda invocation FunctionError: " ^ error))
        | _ -> Ok ()
      in
      let* status =
        Sol_cli_json.int (Sol_cli_json.field [ "StatusCode" ] metadata)
        |> Option.to_result ~none:"Lambda invoke returned no StatusCode"
        |> Result.map_error (fun message -> Unknown message)
      in
      let* () =
        if status = 200
        then Ok ()
        else Error (Unknown (Printf.sprintf "Lambda invocation status %d" status))
      in
      let* body =
        Sol_cli_fs.read_file outfile |> Result.map_error (fun message -> Unknown message)
      in
      let* response =
        Sol_cli_json.decode ~what:"Lambda HTTP response" body
        |> Result.map_error (fun message -> Unknown message)
      in
      let* status =
        Sol_cli_json.int (Sol_cli_json.field [ "statusCode" ] response)
        |> Option.to_result ~none:"Lambda HTTP response has no statusCode"
        |> Result.map_error (fun message -> Unknown message)
      in
      if status = 200
      then Ok ()
      else Error (Unknown (Printf.sprintf "post-deploy readiness %d" status))
  in
  Sol_cli_fs.with_temp_file ~prefix:"sol-lambda-fn-http-" ~suffix:".json" "" invoke
  |> Result.map_error (fun message -> Unknown message)
  |> Result.join
;;

let deploy (r : request) =
  let* () = preflight r in
  let* names =
    Sol_cli_aws_lambda_common.inventory (scope r) |> Result.map_error (fun m -> Unknown m)
  in
  let* existing =
    if List.mem r.function_name names
    then (
      match describe_owned r with
      | Ok _ -> Ok true
      | Error failure -> Error failure)
    else Ok false
  in
  let provisional =
    { region = r.region
    ; service = r.service
    ; function_name = r.function_name
    ; version = ""
    ; alias = "live"
    ; url = ""
    ; image = r.image
    ; role_arn = r.role_arn
    ; http_path = r.http_path
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
    Sol_cli_aws_lambda_common.ensure_function
      (scope r)
      ~function_name:r.function_name
      ~image:r.image
      ~role_arn:r.role_arn
      ~environment:
        [ "SOL_UNIT", r.unit
        ; "SOL_PRIMITIVE", "fn"
        ; "SOL_HTTP_PATH", r.http_path
        ; "SOL_HTTP_EXPOSURE", "public"
        ]
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
  (* The alias has moved. Record what is serving before the URL and smoke, so a failure
     here still leaves a destroyable record naming the live version. *)
  let serving = { provisional with version } in
  let* () =
    match r.record with
    | None -> Ok ()
    | Some path -> write_record ~path serving |> Result.map_error (fun m -> Provider m)
  in
  let* () = ready r in
  Ok serving
;;

let rollback (r : request) ~version ~on_alias_moved =
  let* () =
    if String.trim version = ""
    then Error (Refused "rollback version is required")
    else Ok ()
  in
  let* () =
    match describe_owned r with
    | Ok _ -> Ok ()
    | Error failure -> Error failure
  in
  let* () =
    Sol_cli_aws_lambda_common.verify_role
      ~expected:r.role_arn
      (scope r)
      ~function_name:r.function_name
  in
  let* () =
    match
      Sol_cli_aws_lambda_common.put_alias
        (scope r)
        ~function_name:r.function_name
        ~version
    with
    | Ok () -> Ok ()
    | Error message ->
      (match
         Sol_cli_aws_lambda_common.alias_version (scope r) ~function_name:r.function_name
       with
       | Ok (Some actual) when actual = version ->
         Sol_cli_report.warn
           "Lambda alias update reported an error but live is at version %s; reconciled: \
            %s"
           version
           (failure_to_string message);
         Ok ()
       | Ok _ -> Error (Partial (failure_to_string message))
       | Error _ -> Error (Unknown (failure_to_string message)))
  in
  let* () =
    on_alias_moved version
    |> Result.map_error (fun message -> Partial ("alias moved: " ^ message))
  in
  let release =
    { region = r.region
    ; service = r.service
    ; function_name = r.function_name
    ; version
    ; alias = "live"
    ; url = ""
    ; image = r.image
    ; role_arn = r.role_arn
    ; http_path = r.http_path
    }
  in
  let* () = ready r in
  Ok release
;;

let destroy ~(r : request) ~profile ~region ~service ~record =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun message ->
      Refused ("destroy requires an ownership record: " ^ message))
  in
  let* () =
    if expected.region = region && expected.service = service
    then Ok ()
    else
      Error
        (Refused
           "release record does not match the target region and service; refusing to \
            delete an unverified function")
  in
  let* names =
    Sol_cli_aws_lambda_common.inventory (scope { r with profile; region })
    |> Result.map_error (fun m -> Unknown m)
  in
  if not (List.mem expected.function_name names)
  then Ok ()
  else (
    let owned = { r with profile; region; function_name = expected.function_name } in
    let* () =
      match describe_owned owned with
      | Ok _ -> Ok ()
      | Error failure -> Error failure
    in
    let* () =
      Sol_cli_aws_lambda_common.verify_role
        ~expected:expected.role_arn
        (scope owned)
        ~function_name:expected.function_name
    in
    let delete args =
      match r.run (aws owned args) with
      | Ok _ -> Ok ()
      | Error message ->
        if Sol_cli_aws_lambda_common.resource_is_absent message
        then Ok ()
        else Error (Partial message)
    in
    let* () =
      delete [ "lambda"; "delete-function"; "--function-name"; expected.function_name ]
    in
    let* names =
      Sol_cli_aws_lambda_common.inventory (scope { r with profile; region })
      |> Result.map_error (fun m -> Unknown m)
    in
    if List.mem expected.function_name names
    then Error (Unknown "function remains after delete")
    else Ok ())
;;
