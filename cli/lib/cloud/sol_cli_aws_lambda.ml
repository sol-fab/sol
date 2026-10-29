type identity =
  { unit : string
  ; callers : (string * string) list
  ; issuer : string
  ; jwks_uri : string
  }

type output = Sol_cli_aws_lambda_common.output =
  { stdout : string
  ; stderr : string
  }

type request =
  { profile : string option
  ; region : string
  ; service : string
  ; function_name : string
  ; image : string
  ; role_arn : string
  ; identity : identity
  ; record : string option
  ; run : string list -> (output, string) result
  ; http : url:string -> token:string option -> (int * string, string) result
  }

type observed =
  { function_name : string
  ; version : string
  ; alias : string
  ; url : string
  ; tags : (string * string) list
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
  }

type failure = Sol_cli_aws_lambda_common.failure =
  | Refused of string
  | Provider of string
  | Partial of string
  | Unknown of string

open Result.Syntax

let failure_to_string = Sol_cli_aws_lambda_common.failure_to_string
let provider_service_of = Sol_cli_aws_lambda_common.provider_service_of

let scope (r : request) : Sol_cli_aws_lambda_common.scope =
  { profile = r.profile; region = r.region; run = r.run }
;;

let aws (r : request) args =
  Sol_cli_aws_lambda_common.aws ~profile:r.profile ~region:r.region args
;;

let valid_image = Sol_cli_aws_lambda_common.valid_image

let preflight (r : request) =
  let* () =
    if String.trim r.region = "" then Error (Refused "region is empty") else Ok ()
  in
  let* () =
    if String.trim r.function_name = ""
    then Error (Refused "function name is empty")
    else Ok ()
  in
  let* () =
    if String.trim r.role_arn = "" then Error (Refused "role ARN is required") else Ok ()
  in
  let* () = valid_image r.image in
  let* () =
    if r.identity.unit <> "" then Ok () else Error (Refused "identity unit is required")
  in
  let* () =
    if r.identity.issuer = "https://accounts.google.com"
    then Ok ()
    else Error (Refused "Lambda experiment requires the Google issuer")
  in
  let* () =
    if r.identity.jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
    then Ok ()
    else Error (Refused "Lambda experiment requires Google's canonical JWKS URI")
  in
  if r.identity.callers = []
  then Error (Refused "at least one caller is required")
  else Ok ()
;;

let inventory (r : request) = Sol_cli_aws_lambda_common.inventory (scope r)

let describe (r : request) =
  Sol_cli_aws_lambda_common.describe (scope r) ~function_name:r.function_name
;;

let alias_version (r : request) =
  Sol_cli_aws_lambda_common.alias_version (scope r) ~function_name:r.function_name
;;

let url (r : request) =
  match
    r.run
      (aws
         r
         [ "lambda"
         ; "get-function-url-config"
         ; "--function-name"
         ; r.function_name
         ; "--qualifier"
         ; "live"
         ])
  with
  | Error e -> Error e
  | Ok o ->
    (match Sol_cli_json.decode ~what:"Lambda URL" o.stdout with
     | Error m -> Error m
     | Ok json ->
       Sol_cli_json.string (Sol_cli_json.field [ "FunctionUrl" ] json)
       |> Option.to_result ~none:"function URL missing")
;;

let trim_url = Sol_cli_aws_lambda_common.trim_url

let observed (r : request) version tags =
  let* u = url r |> Result.map_error (fun m -> Unknown m) in
  let* av = alias_version r in
  Ok
    { function_name = r.function_name
    ; version = Option.value av ~default:version
    ; alias = "live"
    ; url = trim_url u
    ; tags
    }
;;

let owns ~function_name tags =
  List.assoc_opt "sol-owned" tags = Some "lambda-experiment"
  && List.assoc_opt "sol-service" tags = Some function_name
;;

let release_json (r : release) =
  `Assoc
    [ "kind", `String "svc"
    ; "region", `String r.region
    ; "service", `String r.service
    ; "function_name", `String r.function_name
    ; "version", `String r.version
    ; "alias", `String r.alias
    ; "url", `String r.url
    ; "image", `String r.image
    ; "role_arn", `String r.role_arn
    ]
;;

let observed_json (o : observed) =
  `Assoc
    [ "kind", `String "svc"
    ; "function_name", `String o.function_name
    ; "version", `String o.version
    ; "alias", `String o.alias
    ; "url", `String o.url
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
    if kind = "svc"
    then Ok ()
    else
      Error
        (Printf.sprintf
           "release record kind %S is not an AWS Lambda HTTP service record"
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
  Ok { region; service; function_name; version; alias; url; image; role_arn }
;;

let deploy (r : request) =
  let* () = preflight r in
  let* names = inventory r |> Result.map_error (fun m -> Unknown m) in
  let* existing =
    if List.mem r.function_name names
    then (
      match describe r with
      | Error (`Provider m) -> Error (Unknown m)
      | Error (`Unknown m) -> Error (Unknown m)
      | Ok (`Present (_, tags)) ->
        if owns ~function_name:r.function_name tags
        then Ok true
        else (
          let tags_json =
            Yojson.Safe.to_string (`Assoc (List.map (fun (k, v) -> k, `String v) tags))
          in
          Error
            (Refused
               (Printf.sprintf
                  "Lambda function exists without adapter ownership tags (fn=%s tags=%s)"
                  r.function_name
                  tags_json))))
    else Ok false
  in
  let env =
    `Assoc
      [ ( "Variables"
        , `Assoc
            [ "SOL_UNIT", `String r.identity.unit
            ; ( "SOL_CALLED_BY"
              , `String
                  (r.identity.callers
                   |> List.map (fun (s, u) -> u ^ "=" ^ s)
                   |> String.concat ",") )
            ; "SOL_TRUSTED_WORKLOAD_ISSUER", `String r.identity.issuer
            ; "SOL_TRUSTED_WORKLOAD_JWKS_URI", `String r.identity.jwks_uri
            ; "SOL_WORKLOAD_SUBJECT_SCHEME", `String "google_oidc_service_account"
            ; "AWS_LWA_PORT", `String "8080"
            ] )
      ]
    |> Yojson.Safe.to_string
  in
  let* () =
    if existing
    then
      let* () =
        r.run
          (aws
             r
             [ "lambda"
             ; "update-function-code"
             ; "--function-name"
             ; r.function_name
             ; "--image-uri"
             ; r.image
             ])
        |> Result.map (fun _ -> ())
        |> Result.map_error (fun m -> Partial m)
      in
      let* () =
        r.run
          (aws
             r
             [ "lambda"; "wait"; "function-updated"; "--function-name"; r.function_name ])
        |> Result.map (fun _ -> ())
        |> Result.map_error (fun m -> Unknown ("wait after code update: " ^ m))
      in
      r.run
        (aws
           r
           [ "lambda"
           ; "update-function-configuration"
           ; "--function-name"
           ; r.function_name
           ; "--role"
           ; r.role_arn
           ; "--environment"
           ; env
           ])
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun m -> Partial m)
    else
      r.run
        (aws
           r
           [ "lambda"
           ; "create-function"
           ; "--function-name"
           ; r.function_name
           ; "--package-type"
           ; "Image"
           ; "--code"
           ; "ImageUri=" ^ r.image
           ; "--role"
           ; r.role_arn
           ; "--timeout"
           ; "30"
           ; "--memory-size"
           ; "512"
           ; "--architectures"
           ; "x86_64"
           ; "--environment"
           ; env
           ; "--tags"
           ; "sol-owned=lambda-experiment,sol-service=" ^ r.function_name
           ])
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun m -> Partial m)
  in
  let* () =
    r.run
      (aws r [ "lambda"; "wait"; "function-updated"; "--function-name"; r.function_name ])
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun m -> Unknown ("wait failed: " ^ m))
  in
  let* version =
    match
      r.run (aws r [ "lambda"; "publish-version"; "--function-name"; r.function_name ])
    with
    | Error e -> Error (Unknown ("publish failed: " ^ e))
    | Ok o ->
      (match Sol_cli_json.decode ~what:"Lambda publish-version" o.stdout with
       | Error m -> Error (Unknown m)
       | Ok json ->
         Sol_cli_json.string (Sol_cli_json.field [ "Version" ] json)
         |> Option.to_result ~none:"publish returned no version"
         |> Result.map_error (fun m -> Unknown m))
  in
  let* () =
    Sol_cli_aws_lambda_common.put_alias (scope r) ~function_name:r.function_name ~version
  in
  let* () =
    match url r with
    | Ok _ -> Ok ()
    | Error _ ->
      r.run
        (aws
           r
           [ "lambda"
           ; "create-function-url-config"
           ; "--function-name"
           ; r.function_name
           ; "--qualifier"
           ; "live"
           ; "--auth-type"
           ; "NONE"
           ])
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun m -> Unknown m)
  in
  let ignore_error args =
    match r.run (aws r args) with
    | Ok _ -> ()
    | Error _ -> ()
  in
  ignore_error
    [ "lambda"
    ; "remove-permission"
    ; "--function-name"
    ; r.function_name
    ; "--qualifier"
    ; "live"
    ; "--statement-id"
    ; "sol-public-url"
    ];
  ignore_error
    [ "lambda"
    ; "remove-permission"
    ; "--function-name"
    ; r.function_name
    ; "--qualifier"
    ; "live"
    ; "--statement-id"
    ; "sol-public-invoke"
    ];
  let* () =
    r.run
      (aws
         r
         [ "lambda"
         ; "add-permission"
         ; "--function-name"
         ; r.function_name
         ; "--qualifier"
         ; "live"
         ; "--statement-id"
         ; "sol-public-url"
         ; "--action"
         ; "lambda:InvokeFunctionUrl"
         ; "--principal"
         ; "*"
         ; "--function-url-auth-type"
         ; "NONE"
         ])
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun m -> Provider ("URL permission: " ^ m))
  in
  let* () =
    r.run
      (aws
         r
         [ "lambda"
         ; "add-permission"
         ; "--function-name"
         ; r.function_name
         ; "--qualifier"
         ; "live"
         ; "--statement-id"
         ; "sol-public-invoke"
         ; "--action"
         ; "lambda:InvokeFunction"
         ; "--principal"
         ; "*"
         ; "--invoked-via-function-url"
         ])
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun m -> Provider ("invoke permission: " ^ m))
  in
  let* o = observed r version [] in
  let release =
    { region = r.region
    ; service = r.service
    ; function_name = r.function_name
    ; version
    ; alias = "live"
    ; url = o.url
    ; image = r.image
    ; role_arn = r.role_arn
    }
  in
  let* () =
    match r.record with
    | None -> Ok ()
    | Some path -> write_record ~path release |> Result.map_error (fun m -> Provider m)
  in
  Ok release
;;

let verify (r : request) ~token =
  let* o = observed r "unknown" [] in
  if token = ""
  then Error (Refused "authorized token is required")
  else
    let* ready, _ =
      r.http ~url:(o.url ^ "/readyz") ~token:None |> Result.map_error (fun m -> Unknown m)
    in
    let* () =
      if ready = 200 then Ok () else Error (Unknown (Printf.sprintf "readiness %d" ready))
    in
    let* auth, _ =
      r.http ~url:(o.url ^ "/quote") ~token:(Some token)
      |> Result.map_error (fun m -> Unknown m)
    in
    let* () =
      if auth = 200
      then Ok ()
      else Error (Unknown (Printf.sprintf "authorized /quote %d" auth))
    in
    let* unauth, _ =
      r.http ~url:(o.url ^ "/quote") ~token:None |> Result.map_error (fun m -> Unknown m)
    in
    let* () =
      if unauth = 401
      then Ok ()
      else Error (Unknown (Printf.sprintf "unauthenticated /quote %d" unauth))
    in
    Ok o
;;

let rollback (r : request) ~version ~token ~on_alias_moved : (observed, failure) result =
  let* () =
    if String.trim version = ""
    then Error (Refused "rollback version is required")
    else Ok ()
  in
  (* A rollback moves the live alias, so it must establish that the function is this
     adapter's before mutating provider state. *)
  let* () =
    match describe r with
    | Error (`Provider m) | Error (`Unknown m) -> Error (Unknown m)
    | Ok (`Present (_, tags)) ->
      if owns ~function_name:r.function_name tags
      then Ok ()
      else Error (Refused "live function lacks this adapter's ownership tags")
  in
  let* () =
    r.run
      (aws
         r
         [ "lambda"
         ; "update-alias"
         ; "--function-name"
         ; r.function_name
         ; "--name"
         ; "live"
         ; "--function-version"
         ; version
         ])
    |> Result.map (fun _ -> ())
    |> Result.map_error (fun m -> Partial m)
  in
  (* The alias has moved. Record that provider state before the smoke test, so a failed
     smoke cannot leave the release record naming the version that is no longer live. *)
  let* () =
    on_alias_moved version
    |> Result.map_error (fun m ->
      Partial ("alias moved but release record update failed: " ^ m))
  in
  verify r ~token |> Result.map (fun (o : observed) -> ({ o with version } : observed))
;;

let destroy (r : request) ~profile ~region ~service ~record =
  let* expected = read_record ~path:record |> Result.map_error (fun m -> Refused m) in
  let* function_name =
    provider_service_of service
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
  let* names =
    inventory { r with profile; region } |> Result.map_error (fun m -> Unknown m)
  in
  if not (List.mem expected.function_name names)
  then Ok ()
  else (
    let owned_request =
      { r with profile; region; function_name = expected.function_name }
    in
    let* () =
      match describe owned_request with
      | Error (`Provider m) | Error (`Unknown m) -> Error (Unknown m)
      | Ok (`Present (_, tags)) ->
        if owns ~function_name:expected.function_name tags
        then Ok ()
        else Error (Refused "live function lacks this adapter's ownership tags")
    in
    let* () =
      r.run
        (aws
           { r with profile; region }
           [ "lambda"
           ; "delete-function-url-config"
           ; "--function-name"
           ; expected.function_name
           ; "--qualifier"
           ; "live"
           ])
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun m -> Partial m)
    in
    let* () =
      r.run
        (aws
           { r with profile; region }
           [ "lambda"; "delete-function"; "--function-name"; expected.function_name ])
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun m -> Partial m)
    in
    let* names =
      inventory { r with profile; region } |> Result.map_error (fun m -> Unknown m)
    in
    if List.mem expected.function_name names
    then Error (Unknown "function remains after delete")
    else Ok ())
;;
