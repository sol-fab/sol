open Result.Syntax

type request =
  { profile : string option
  ; region : string
  ; service : string
  ; image : string
  ; role_arn : string
  ; max_attempts : int
  ; visibility_timeout_s : int
  ; dlq_retention_s : int
  ; concurrency : int
  ; record : string option
  ; run : string list -> (Sol_cli_aws_lambda_common.output, string) result
  }

type release =
  { region : string
  ; service : string
  ; function_name : string
  ; version : string
  ; alias : string
  ; image : string
  ; role_arn : string
  ; queue_name : string
  ; queue_url : string
  ; queue_arn : string
  ; dlq_name : string
  ; dlq_url : string
  ; dlq_arn : string
  ; mapping_uuid : string
  ; max_attempts : int
  ; visibility_timeout_s : int
  ; dlq_retention_s : int
  ; concurrency : int
  }

let ownership_tag = "lambda-task-experiment"

let scope (r : request) : Sol_cli_aws_lambda_common.scope =
  { profile = r.profile; region = r.region; run = r.run }
;;

let aws (r : request) args =
  Sol_cli_aws_lambda_common.aws ~profile:r.profile ~region:r.region args
;;

let contains_substring ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec at index =
    if index + needle_length > haystack_length
    then false
    else if String.sub haystack index needle_length = needle
    then true
    else at (index + 1)
  in
  needle_length = 0 || at 0
;;

let missing_queue message =
  contains_substring ~needle:"NonExistentQueue" message
  || contains_substring ~needle:"does not exist" message
  || contains_substring ~needle:"QueueDoesNotExist" message
;;

let provider_names ~service =
  let* provider = Sol_cli_aws_lambda_common.provider_service_of service in
  let suffix, count =
    if String.length provider <= 60 then provider, 0 else String.sub provider 0 60, 0
  in
  ignore count;
  Ok (suffix ^ "-task", suffix ^ "-task", suffix ^ "-task-dlq")
;;

let validate_settings (r : request) =
  let* () =
    if r.max_attempts > 0 && r.max_attempts <= 1000
    then Ok ()
    else
      Error (Sol_cli_aws_lambda_common.Refused "max_attempts must be between 1 and 1000")
  in
  let* () =
    if r.visibility_timeout_s >= 0 && r.visibility_timeout_s <= 43200
    then Ok ()
    else
      Error
        (Sol_cli_aws_lambda_common.Refused
           "visibility_timeout_s must be between 0 and 43200")
  in
  let* () =
    if r.dlq_retention_s >= 60 && r.dlq_retention_s <= 1209600
    then Ok ()
    else
      Error
        (Sol_cli_aws_lambda_common.Refused
           "dlq_retention_s must be between 60 and 1209600")
  in
  if r.concurrency > 0
  then Ok ()
  else Error (Sol_cli_aws_lambda_common.Refused "concurrency must be greater than zero")
;;

let tags ~function_name = [ "sol-owned", ownership_tag; "sol-service", function_name ]

let tag_string tags =
  tags |> List.map (fun (key, value) -> key ^ "=" ^ value) |> String.concat ","
;;

let field name json =
  Sol_cli_json.string (Sol_cli_json.field [ name ] json)
  |> Option.to_result ~none:(name ^ " missing")
;;

let queue_url_opt (r : request) ~queue_name =
  match r.run (aws r [ "sqs"; "get-queue-url"; "--queue-name"; queue_name ]) with
  | Ok output ->
    (match Sol_cli_json.decode ~what:"SQS get-queue-url" output.stdout with
     | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
     | Ok json ->
       field "QueueUrl" json
       |> Result.map Option.some
       |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message))
  | Error message ->
    if missing_queue message
    then Ok None
    else Error (Sol_cli_aws_lambda_common.Provider message)
;;

let queue_arn (r : request) ~queue_url =
  match
    r.run
      (aws
         r
         [ "sqs"
         ; "get-queue-attributes"
         ; "--queue-url"
         ; queue_url
         ; "--attribute-names"
         ; "QueueArn"
         ])
  with
  | Error message -> Error (Sol_cli_aws_lambda_common.Provider message)
  | Ok output ->
    (match Sol_cli_json.decode ~what:"SQS queue attributes" output.stdout with
     | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
     | Ok json ->
       field "QueueArn" (Sol_cli_json.field [ "Attributes" ] json)
       |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message))
;;

let queue_tags (r : request) ~queue_url =
  match r.run (aws r [ "sqs"; "list-queue-tags"; "--queue-url"; queue_url ]) with
  | Error message -> Error (Sol_cli_aws_lambda_common.Provider message)
  | Ok output ->
    (match Sol_cli_json.decode ~what:"SQS queue tags" output.stdout with
     | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
     | Ok json ->
       (match Sol_cli_json.assoc (Sol_cli_json.field [ "Tags" ] json) with
        | None -> Ok []
        | Some fields ->
          Ok
            (List.filter_map
               (fun (key, value) ->
                  Option.map (fun value -> key, value) (Sol_cli_json.string value))
               fields)))
;;

let owns_queue (r : request) ~function_name ~queue_url =
  let* tags = queue_tags r ~queue_url in
  if
    List.assoc_opt "sol-owned" tags = Some ownership_tag
    && List.assoc_opt "sol-service" tags = Some function_name
  then Ok ()
  else
    Error
      (Sol_cli_aws_lambda_common.Refused
         (Printf.sprintf
            "SQS queue %s exists without this adapter's ownership tags"
            queue_url))
;;

let create_queue (r : request) ~queue_name ~attributes ~function_name =
  let* () =
    match queue_url_opt r ~queue_name with
    | Ok None -> Ok ()
    | Ok (Some url) -> owns_queue r ~function_name ~queue_url:url
    | Error failure -> Error failure
  in
  let attributes_arg =
    `Assoc (List.map (fun (key, value) -> key, `String value) attributes)
    |> Yojson.Safe.to_string
  in
  let args =
    [ "sqs"; "create-queue"; "--queue-name"; queue_name ]
    @ (if attributes_arg = "" then [] else [ "--attributes"; attributes_arg ])
    @ [ "--tags"; tag_string (tags ~function_name) ]
  in
  match r.run (aws r args) with
  | Error message -> Error (Sol_cli_aws_lambda_common.Partial message)
  | Ok output ->
    (match Sol_cli_json.decode ~what:"SQS create-queue" output.stdout with
     | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
     | Ok json ->
       field "QueueUrl" json
       |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message))
;;

let ensure_queues (r : request) ~function_name ~queue_name ~dlq_name =
  let* dlq_url =
    create_queue
      r
      ~queue_name:dlq_name
      ~attributes:[ "MessageRetentionPeriod", string_of_int r.dlq_retention_s ]
      ~function_name
  in
  let* dlq_arn = queue_arn r ~queue_url:dlq_url in
  let redrive =
    Printf.sprintf
      {|{"deadLetterTargetArn":"%s","maxReceiveCount":"%d"}|}
      dlq_arn
      r.max_attempts
  in
  let* queue_url =
    create_queue
      r
      ~queue_name
      ~attributes:
        [ "VisibilityTimeout", string_of_int r.visibility_timeout_s
        ; "MessageRetentionPeriod", string_of_int r.dlq_retention_s
        ; "RedrivePolicy", redrive
        ]
      ~function_name
  in
  let* queue_arn = queue_arn r ~queue_url in
  Ok (queue_name, queue_url, queue_arn, dlq_name, dlq_url, dlq_arn)
;;

let function_arn (r : request) ~function_name =
  match
    r.run
      (aws
         r
         [ "lambda"
         ; "get-function"
         ; "--function-name"
         ; function_name
         ; "--query"
         ; "Configuration.FunctionArn"
         ; "--output"
         ; "text"
         ])
  with
  | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
  | Ok output -> Ok (String.trim output.stdout)
;;

let describe_function (r : request) ~function_name =
  match Sol_cli_aws_lambda_common.describe (scope r) ~function_name with
  | Error (`Provider message) | Error (`Unknown message) ->
    Error (Sol_cli_aws_lambda_common.Unknown message)
  | Ok (`Present (version, tags)) -> Ok (version, tags)
;;

let ensure_function_owned (r : request) ~function_name ~existing =
  if not existing
  then Ok ()
  else
    let* _, tags = describe_function r ~function_name in
    if
      List.assoc_opt "sol-owned" tags = Some ownership_tag
      && List.assoc_opt "sol-service" tags = Some function_name
    then Ok ()
    else
      Error
        (Sol_cli_aws_lambda_common.Refused
           (Printf.sprintf
              "Lambda function %s exists without this adapter's ownership tags"
              function_name))
;;

let list_mappings (r : request) ~function_arn ~queue_arn =
  match
    r.run
      (aws
         r
         [ "lambda"
         ; "list-event-source-mappings"
         ; "--function-name"
         ; function_arn
         ; "--event-source-arn"
         ; queue_arn
         ])
  with
  | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
  | Ok output ->
    (match Sol_cli_json.decode ~what:"Lambda event source mappings" output.stdout with
     | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
     | Ok json ->
       (match Sol_cli_json.list (Sol_cli_json.field [ "EventSourceMappings" ] json) with
        | None -> Ok []
        | Some mappings -> Ok mappings))
;;

let mapping_uuid json =
  field "UUID" json
  |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message)
;;

let create_or_update_mapping (r : request) ~alias_arn ~queue_arn =
  let* mappings = list_mappings r ~function_arn:alias_arn ~queue_arn in
  let* uuid =
    match mappings with
    | [] ->
      (match
         r.run
           (aws
              r
              [ "lambda"
              ; "create-event-source-mapping"
              ; "--function-name"
              ; alias_arn
              ; "--event-source-arn"
              ; queue_arn
              ; "--batch-size"
              ; "10"
              ; "--scaling-config"
              ; Printf.sprintf "MaximumConcurrency=%d" r.concurrency
              ; "--function-response-types"
              ; "ReportBatchItemFailures"
              ; "--enabled"
              ])
       with
       | Error message -> Error (Sol_cli_aws_lambda_common.Partial message)
       | Ok output ->
         (match Sol_cli_json.decode ~what:"Lambda create mapping" output.stdout with
          | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
          | Ok json -> mapping_uuid json))
    | mapping :: _ ->
      let* uuid = mapping_uuid mapping in
      (match
         r.run
           (aws
              r
              [ "lambda"
              ; "update-event-source-mapping"
              ; "--uuid"
              ; uuid
              ; "--function-name"
              ; alias_arn
              ; "--scaling-config"
              ; Printf.sprintf "MaximumConcurrency=%d" r.concurrency
              ; "--function-response-types"
              ; "ReportBatchItemFailures"
              ; "--enabled"
              ])
       with
       | Error message -> Error (Sol_cli_aws_lambda_common.Partial message)
       | Ok _ -> Ok uuid)
  in
  Ok uuid
;;

let describe_mapping (r : request) ~uuid =
  match r.run (aws r [ "lambda"; "get-event-source-mapping"; "--uuid"; uuid ]) with
  | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
  | Ok output ->
    (match Sol_cli_json.decode ~what:"Lambda event source mapping" output.stdout with
     | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
     | Ok json -> Ok json)
;;

let mapping_ready (r : request) ~uuid =
  let deadline = Unix.gettimeofday () +. 120. in
  let rec loop () =
    let* json = describe_mapping r ~uuid in
    let* state =
      field "State" json
      |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message)
    in
    let* response_types =
      match Sol_cli_json.list (Sol_cli_json.field [ "FunctionResponseTypes" ] json) with
      | None -> Ok []
      | Some values ->
        Ok (List.filter_map (fun value -> Sol_cli_json.string value) values)
    in
    match state with
    | "Enabled" ->
      if List.mem "ReportBatchItemFailures" response_types
      then Ok ()
      else
        Error
          (Sol_cli_aws_lambda_common.Unknown
             (Printf.sprintf
                "event source mapping is Enabled with response types [%s]"
                (String.concat ", " response_types)))
    | "Creating" | "Enabling" | "Updating" ->
      if Unix.gettimeofday () > deadline
      then
        Error
          (Sol_cli_aws_lambda_common.Unknown
             (Printf.sprintf
                "timed out waiting for event source mapping %s (state %s)"
                uuid
                state))
      else (
        Unix.sleepf 2.;
        loop ())
    | "Failed" ->
      Error
        (Sol_cli_aws_lambda_common.Unknown
           ("event source mapping " ^ uuid ^ " entered Failed"))
    | other ->
      Error
        (Sol_cli_aws_lambda_common.Unknown
           (Printf.sprintf "event source mapping %s is %s" uuid other))
  in
  loop ()
;;

let release_json (r : release) =
  `Assoc
    [ "kind", `String "aws-task"
    ; "region", `String r.region
    ; "service", `String r.service
    ; "function_name", `String r.function_name
    ; "version", `String r.version
    ; "alias", `String r.alias
    ; "image", `String r.image
    ; "role_arn", `String r.role_arn
    ; "queue_name", `String r.queue_name
    ; "queue_url", `String r.queue_url
    ; "queue_arn", `String r.queue_arn
    ; "dlq_name", `String r.dlq_name
    ; "dlq_url", `String r.dlq_url
    ; "dlq_arn", `String r.dlq_arn
    ; "mapping_uuid", `String r.mapping_uuid
    ; "max_attempts", `Int r.max_attempts
    ; "visibility_timeout_s", `Int r.visibility_timeout_s
    ; "dlq_retention_s", `Int r.dlq_retention_s
    ; "concurrency", `Int r.concurrency
    ]
;;

let write_record ~path r = Sol_cli_aws_lambda_common.write_json ~path (release_json r)

let read_record ~path =
  let* json = Sol_cli_aws_lambda_common.read_json ~path in
  let field name =
    Sol_cli_json.string (Sol_cli_json.field [ name ] json)
    |> Option.to_result ~none:(name ^ " missing")
  in
  let int_field name =
    Sol_cli_json.int (Sol_cli_json.field [ name ] json)
    |> Option.to_result ~none:(name ^ " missing")
  in
  let* kind = field "kind" in
  let* () =
    if kind = "aws-task"
    then Ok ()
    else Error (Printf.sprintf "release record kind %S is not an AWS task record" kind)
  in
  let* region = field "region" in
  let* service = field "service" in
  let* function_name = field "function_name" in
  let* version = field "version" in
  let* alias = field "alias" in
  let* image = field "image" in
  let* role_arn = field "role_arn" in
  let* queue_name = field "queue_name" in
  let* queue_url = field "queue_url" in
  let* queue_arn = field "queue_arn" in
  let* dlq_name = field "dlq_name" in
  let* dlq_url = field "dlq_url" in
  let* dlq_arn = field "dlq_arn" in
  let* mapping_uuid = field "mapping_uuid" in
  let* max_attempts = int_field "max_attempts" in
  let* visibility_timeout_s = int_field "visibility_timeout_s" in
  let* dlq_retention_s = int_field "dlq_retention_s" in
  let* concurrency = int_field "concurrency" in
  Ok
    { region
    ; service
    ; function_name
    ; version
    ; alias
    ; image
    ; role_arn
    ; queue_name
    ; queue_url
    ; queue_arn
    ; dlq_name
    ; dlq_url
    ; dlq_arn
    ; mapping_uuid
    ; max_attempts
    ; visibility_timeout_s
    ; dlq_retention_s
    ; concurrency
    }
;;

let deploy (r : request) =
  let* () = validate_settings r in
  let* () = Sol_cli_aws_lambda_common.valid_image r.image in
  let* () =
    if String.trim r.role_arn = ""
    then Error (Sol_cli_aws_lambda_common.Refused "role ARN is required")
    else Ok ()
  in
  let* record =
    r.record
    |> Option.to_result
         ~none:
           (Sol_cli_aws_lambda_common.Refused
              "task deploy requires an ownership record path")
  in
  let* function_name, queue_name, dlq_name = provider_names ~service:r.service in
  let* names =
    Sol_cli_aws_lambda_common.inventory (scope r)
    |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message)
  in
  let existing = List.mem function_name names in
  let* () = ensure_function_owned r ~function_name ~existing in
  let release ~version ~mapping_uuid ~queue_url ~queue_arn ~dlq_url ~dlq_arn =
    { region = r.region
    ; service = r.service
    ; function_name
    ; version
    ; alias = "live"
    ; image = r.image
    ; role_arn = r.role_arn
    ; queue_name
    ; queue_url
    ; queue_arn
    ; dlq_name
    ; dlq_url
    ; dlq_arn
    ; mapping_uuid
    ; max_attempts = r.max_attempts
    ; visibility_timeout_s = r.visibility_timeout_s
    ; dlq_retention_s = r.dlq_retention_s
    ; concurrency = r.concurrency
    }
  in
  let write release =
    write_record ~path:record release
    |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Provider message)
  in
  (* Record the deterministic resource names before creating anything. If queue or
     function creation fails partway, destroy can resolve the created resources by name
     even when their URLs were never observed. *)
  let* () =
    write
      (release
         ~version:""
         ~mapping_uuid:""
         ~queue_url:""
         ~queue_arn:""
         ~dlq_url:""
         ~dlq_arn:"")
  in
  let* _, queue_url, queue_arn, _, dlq_url, dlq_arn =
    ensure_queues r ~function_name ~queue_name ~dlq_name
  in
  let* () =
    write (release ~version:"" ~mapping_uuid:"" ~queue_url ~queue_arn ~dlq_url ~dlq_arn)
  in
  let* () =
    Sol_cli_aws_lambda_common.ensure_function
      (scope r)
      ~function_name
      ~image:r.image
      ~role_arn:r.role_arn
      ~environment:[ "SOL_TASK_RUNTIME", "lambda" ]
      ~tags:(tags ~function_name)
      ~timeout_s:(max 3 (min 900 (r.visibility_timeout_s - 5)))
      ~existing
      ()
  in
  let* version = Sol_cli_aws_lambda_common.publish_version (scope r) ~function_name in
  let* () = Sol_cli_aws_lambda_common.put_alias (scope r) ~function_name ~version in
  let* () =
    write (release ~version ~mapping_uuid:"" ~queue_url ~queue_arn ~dlq_url ~dlq_arn)
  in
  let* function_arn = function_arn r ~function_name in
  let alias_arn = function_arn ^ ":live" in
  let* mapping_uuid = create_or_update_mapping r ~alias_arn ~queue_arn in
  let release = release ~version ~mapping_uuid ~queue_url ~queue_arn ~dlq_url ~dlq_arn in
  let* () = write release in
  let* () = mapping_ready r ~uuid:mapping_uuid in
  Ok release
;;

let verify (r : request) ~record =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun m -> Sol_cli_aws_lambda_common.Refused m)
  in
  let* () =
    if expected.region = r.region && expected.service = r.service
    then Ok ()
    else
      Error
        (Sol_cli_aws_lambda_common.Refused
           "release record does not match the target region and service")
  in
  let* () =
    if expected.version = "" || expected.mapping_uuid = ""
    then
      Error
        (Sol_cli_aws_lambda_common.Refused
           "task ownership record is incomplete; the deploy did not finish")
    else Ok ()
  in
  let* () = mapping_ready r ~uuid:expected.mapping_uuid in
  let* _ =
    Sol_cli_aws_lambda_common.alias_version
      (scope r)
      ~function_name:expected.function_name
  in
  Ok expected
;;

let enqueue (r : request) ~record ~body =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun m -> Sol_cli_aws_lambda_common.Refused m)
  in
  let* () =
    if expected.region = r.region && expected.service = r.service
    then Ok ()
    else
      Error
        (Sol_cli_aws_lambda_common.Refused
           "release record does not match the target region and service")
  in
  match
    r.run
      (aws
         r
         [ "sqs"
         ; "send-message"
         ; "--queue-url"
         ; expected.queue_url
         ; "--message-body"
         ; body
         ])
  with
  | Error message -> Error (Sol_cli_aws_lambda_common.Provider message)
  | Ok output ->
    (match Sol_cli_json.decode ~what:"SQS send-message" output.stdout with
     | Error message -> Error (Sol_cli_aws_lambda_common.Unknown message)
     | Ok json ->
       field "MessageId" json
       |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message))
;;

let rollback (r : request) ~record ~version =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun m -> Sol_cli_aws_lambda_common.Refused m)
  in
  let* () =
    if expected.region = r.region && expected.service = r.service
    then Ok ()
    else
      Error
        (Sol_cli_aws_lambda_common.Refused
           "release record does not match the target region and service")
  in
  let* () =
    if String.trim version = ""
    then Error (Sol_cli_aws_lambda_common.Refused "rollback version is required")
    else Ok ()
  in
  let* () =
    Sol_cli_aws_lambda_common.put_alias
      (scope r)
      ~function_name:expected.function_name
      ~version
  in
  let recorded = { expected with version; alias = "live" } in
  let* () =
    write_record ~path:record recorded
    |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Provider message)
  in
  let* () = mapping_ready r ~uuid:expected.mapping_uuid in
  Ok recorded
;;

let delete_queue (r : request) ~queue_url =
  match r.run (aws r [ "sqs"; "delete-queue"; "--queue-url"; queue_url ]) with
  | Ok _ -> Ok ()
  | Error message -> Error (Sol_cli_aws_lambda_common.Partial message)
;;

let destroy (r : request) ~record =
  let* expected =
    read_record ~path:record
    |> Result.map_error (fun m -> Sol_cli_aws_lambda_common.Refused m)
  in
  let* () =
    if expected.region = r.region && expected.service = r.service
    then Ok ()
    else
      Error
        (Sol_cli_aws_lambda_common.Refused
           "release record does not match the target region and service")
  in
  (* Ownership before mutation. *)
  let* names =
    Sol_cli_aws_lambda_common.inventory (scope r)
    |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message)
  in
  let* () =
    if List.mem expected.function_name names
    then
      let* _, tags = describe_function r ~function_name:expected.function_name in
      if
        List.assoc_opt "sol-owned" tags = Some ownership_tag
        && List.assoc_opt "sol-service" tags = Some expected.function_name
      then Ok ()
      else
        Error
          (Sol_cli_aws_lambda_common.Refused
             "live Lambda function lacks this adapter's ownership tags")
    else Ok ()
  in
  let resolve_queue_url ~queue_name ~queue_url =
    if queue_url <> "" then Ok (Some queue_url) else queue_url_opt r ~queue_name
  in
  let* source_url =
    resolve_queue_url ~queue_name:expected.queue_name ~queue_url:expected.queue_url
  in
  let* dlq_url =
    resolve_queue_url ~queue_name:expected.dlq_name ~queue_url:expected.dlq_url
  in
  let* () =
    match source_url with
    | None -> Ok ()
    | Some url -> owns_queue r ~function_name:expected.function_name ~queue_url:url
  in
  let* () =
    match dlq_url with
    | None -> Ok ()
    | Some url -> owns_queue r ~function_name:expected.function_name ~queue_url:url
  in
  let* () =
    if expected.mapping_uuid = ""
    then Ok ()
    else (
      match
        r.run
          (aws
             r
             [ "lambda"; "delete-event-source-mapping"; "--uuid"; expected.mapping_uuid ])
      with
      | Ok _ -> Ok ()
      | Error message ->
        if contains_substring ~needle:"ResourceNotFoundException" message
        then Ok ()
        else Error (Sol_cli_aws_lambda_common.Partial message))
  in
  let* () =
    if List.mem expected.function_name names
    then (
      match
        r.run
          (aws
             r
             [ "lambda"; "delete-function"; "--function-name"; expected.function_name ])
      with
      | Ok _ -> Ok ()
      | Error message -> Error (Sol_cli_aws_lambda_common.Partial message))
    else Ok ()
  in
  let* () =
    match source_url with
    | None -> Ok ()
    | Some url -> delete_queue r ~queue_url:url
  in
  let* () =
    match dlq_url with
    | None -> Ok ()
    | Some url -> delete_queue r ~queue_url:url
  in
  let* names =
    Sol_cli_aws_lambda_common.inventory (scope r)
    |> Result.map_error (fun message -> Sol_cli_aws_lambda_common.Unknown message)
  in
  let* () =
    if List.mem expected.function_name names
    then Error (Sol_cli_aws_lambda_common.Unknown "function remains after delete")
    else Ok ()
  in
  let* () =
    match queue_url_opt r ~queue_name:expected.queue_name with
    | Ok None -> Ok ()
    | Ok (Some _) ->
      Error (Sol_cli_aws_lambda_common.Unknown "source queue remains after delete")
    | Error failure -> Error failure
  in
  match queue_url_opt r ~queue_name:expected.dlq_name with
  | Ok None -> Ok ()
  | Ok (Some _) ->
    Error (Sol_cli_aws_lambda_common.Unknown "dead-letter queue remains after delete")
  | Error failure -> Error failure
;;
