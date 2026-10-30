open Result.Syntax

type output =
  { stdout : string
  ; stderr : string
  }

type failure =
  | Refused of string
  | Provider of string
  | Partial of string
  | Unknown of string

let failure_to_string = function
  | Refused m -> "refused: " ^ m
  | Provider m -> "provider failure: " ^ m
  | Partial m -> "partial: " ^ m ^ " (state unknown)"
  | Unknown m -> "unknown: " ^ m
;;

let provider_service_of service =
  match Sol_cli_kubernetes_name.k8s_name_of_source service with
  | Ok name -> Ok (Sol_cli_kubernetes_name.k8s_name_to_string name)
  | Error message ->
    Error
      (Refused
         (Printf.sprintf "Sol service %S has no valid Lambda name: %s" service message))
;;

type scope =
  { profile : string option
  ; region : string
  ; run : string list -> (output, string) result
  }

let aws ~profile ~region args =
  [ "aws"; "--region"; region; "--output"; "json" ]
  @ (match profile with
     | None -> []
     | Some p -> [ "--profile"; p ])
  @ args
;;

let valid_image image =
  if Sol_cli_image_ref.is_digest image
  then Ok ()
  else Error (Refused "image must be an immutable <repo>@sha256:<digest> reference")
;;

let parse_function_names text =
  let* json = Sol_cli_json.decode ~what:"Lambda list-functions" text in
  let* functions =
    match Sol_cli_json.list (Sol_cli_json.field [ "Functions" ] json) with
    | Some functions -> Ok functions
    | None ->
      Error
        "Lambda list-functions response has no Functions array; refusing to infer \
         absence from an unreadable inventory"
  in
  let rec collect index acc = function
    | [] -> Ok (List.rev acc)
    | entry :: rest ->
      (match Sol_cli_json.string (Sol_cli_json.field [ "FunctionName" ] entry) with
       | Some name -> collect (index + 1) (name :: acc) rest
       | None ->
         Error
           (Printf.sprintf
              "Lambda list-functions entry %d has no FunctionName; refusing to infer \
               absence from a partial inventory"
              index))
  in
  collect 1 [] functions
;;

let inventory (s : scope) =
  match
    s.run (aws ~profile:s.profile ~region:s.region [ "lambda"; "list-functions" ])
  with
  | Error e -> Error e
  | Ok o -> parse_function_names o.stdout
;;

let describe (s : scope) ~function_name =
  match
    s.run
      (aws
         ~profile:s.profile
         ~region:s.region
         [ "lambda"; "get-function"; "--function-name"; function_name ])
  with
  | Error e -> Error (`Provider e)
  | Ok o ->
    (match Sol_cli_json.decode ~what:"Lambda get-function" o.stdout with
     | Error m -> Error (`Unknown m)
     | Ok json ->
       let config = Sol_cli_json.field [ "Configuration" ] json in
       let* version =
         Sol_cli_json.string (Sol_cli_json.field [ "Version" ] config)
         |> Option.to_result ~none:"get-function has no Version"
         |> Result.map_error (fun m -> `Unknown m)
       in
       let tags =
         match Sol_cli_json.assoc (Sol_cli_json.field [ "Tags" ] json) with
         | None -> []
         | Some fields ->
           List.filter_map
             (fun (key, value) ->
                Option.map (fun value -> key, value) (Sol_cli_json.string value))
             fields
       in
       Ok (`Present (version, tags)))
;;

(* AWS reports a missing alias as ResourceNotFoundException. Anything else -- expired
   credentials, a denied API call, a malformed response -- must not become "create the
   alias", because the create would then collide with the real state. *)
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

let resource_is_absent message =
  String.lowercase_ascii message
  |> fun text -> contains_substring ~needle:"resourcenotfoundexception" text
;;

let alias_is_absent message =
  let text = String.lowercase_ascii message in
  contains_substring ~needle:"resourcenotfoundexception" text
  || contains_substring ~needle:"alias not found" text
  || contains_substring ~needle:"cannot find alias" text
;;

let alias_version (s : scope) ~function_name =
  match
    s.run
      (aws
         ~profile:s.profile
         ~region:s.region
         [ "lambda"; "get-alias"; "--function-name"; function_name; "--name"; "live" ])
  with
  | Error e -> if alias_is_absent e then Ok None else Error (Provider e)
  | Ok o ->
    (match Sol_cli_json.decode ~what:"Lambda alias" o.stdout with
     | Error m -> Error (Unknown m)
     | Ok json ->
       (match Sol_cli_json.string (Sol_cli_json.field [ "FunctionVersion" ] json) with
        | Some version -> Ok (Some version)
        | None -> Error (Unknown "get-alias returned no FunctionVersion")))
;;

let put_alias (s : scope) ~function_name ~version =
  let* existing = alias_version s ~function_name in
  let command, verb =
    match existing with
    | Some _ -> "update-alias", "update"
    | None -> "create-alias", "create"
  in
  let require_version () =
    match alias_version s ~function_name with
    | Ok (Some actual) when actual = version -> Ok ()
    | Ok (Some actual) ->
      Error
        (Unknown
           (Printf.sprintf
              "%s alias did not reach version %s (observed %s)"
              verb
              version
              actual))
    | Ok None ->
      Error
        (Unknown
           (Printf.sprintf
              "%s alias did not reach version %s (the alias is absent)"
              verb
              version))
    | Error failure ->
      Error
        (Unknown
           (Printf.sprintf
              "could not observe the alias after %s: %s"
              verb
              (failure_to_string failure)))
  in
  match
    s.run
      (aws
         ~profile:s.profile
         ~region:s.region
         [ "lambda"
         ; command
         ; "--function-name"
         ; function_name
         ; "--name"
         ; "live"
         ; "--function-version"
         ; version
         ])
  with
  | Ok _ -> require_version ()
  | Error e ->
    (* The CLI can report an error after the provider applied the mutation. The alias is
       the serving identity, so reconcile against what is actually serving: if it is the
       requested version, keep the provider error as a warning and continue to the
       caller's verification. Any other observed version is a failed mutation; an
       unreadable alias is unknown, not success. *)
    (match alias_version s ~function_name with
     | Ok (Some actual) when actual = version ->
       Sol_cli_report.warn
         "Lambda %s-alias reported an error but the live alias is at version %s; \
          reconciled: %s"
         verb
         version
         e;
       Ok ()
     | Ok _ | Error _ -> Error (Unknown (Printf.sprintf "%s alias failed: %s" verb e)))
;;

let environment_json variables =
  `Assoc
    [ "Variables", `Assoc (List.map (fun (key, value) -> key, `String value) variables) ]
  |> Yojson.Safe.to_string
;;

let ensure_function
      (s : scope)
      ~function_name
      ~image
      ~role_arn
      ~environment
      ~tags
      ?timeout_s
      ?memory_mb
      ~existing
      ()
  =
  let environment = environment_json environment in
  let tags_arg =
    tags |> List.map (fun (key, value) -> key ^ "=" ^ value) |> String.concat ","
  in
  let timeout_args =
    match timeout_s with
    | None -> []
    | Some seconds -> [ "--timeout"; string_of_int seconds ]
  in
  let memory_args =
    match memory_mb with
    | None -> []
    | Some megabytes -> [ "--memory-size"; string_of_int megabytes ]
  in
  let* () =
    if existing
    then
      let* () =
        s.run
          (aws
             ~profile:s.profile
             ~region:s.region
             [ "lambda"
             ; "update-function-code"
             ; "--function-name"
             ; function_name
             ; "--image-uri"
             ; image
             ])
        |> Result.map (fun _ -> ())
        |> Result.map_error (fun message -> Partial message)
      in
      let* () =
        s.run
          (aws
             ~profile:s.profile
             ~region:s.region
             [ "lambda"; "wait"; "function-updated"; "--function-name"; function_name ])
        |> Result.map (fun _ -> ())
        |> Result.map_error (fun message ->
          Unknown ("wait after code update: " ^ message))
      in
      s.run
        (aws
           ~profile:s.profile
           ~region:s.region
           ([ "lambda"
            ; "update-function-configuration"
            ; "--function-name"
            ; function_name
            ; "--role"
            ; role_arn
            ; "--environment"
            ; environment
            ]
            @ timeout_args
            @ memory_args))
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun message -> Partial message)
    else
      s.run
        (aws
           ~profile:s.profile
           ~region:s.region
           ([ "lambda"
            ; "create-function"
            ; "--function-name"
            ; function_name
            ; "--package-type"
            ; "Image"
            ; "--code"
            ; "ImageUri=" ^ image
            ; "--role"
            ; role_arn
            ; "--timeout"
            ; string_of_int (Option.value timeout_s ~default:30)
            ; "--memory-size"
            ; string_of_int (Option.value memory_mb ~default:512)
            ; "--architectures"
            ; "x86_64"
            ; "--environment"
            ; environment
            ]
            @ if tags_arg = "" then [] else [ "--tags"; tags_arg ]))
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun message -> Partial message)
  in
  s.run
    (aws
       ~profile:s.profile
       ~region:s.region
       [ "lambda"; "wait"; "function-updated"; "--function-name"; function_name ])
  |> Result.map (fun _ -> ())
  |> Result.map_error (fun message -> Unknown ("wait failed: " ^ message))
;;

let publish_version (s : scope) ~function_name =
  match
    s.run
      (aws
         ~profile:s.profile
         ~region:s.region
         [ "lambda"; "publish-version"; "--function-name"; function_name ])
  with
  | Error message -> Error (Unknown ("publish failed: " ^ message))
  | Ok output ->
    (match Sol_cli_json.decode ~what:"Lambda publish-version" output.stdout with
     | Error message -> Error (Unknown message)
     | Ok json ->
       Sol_cli_json.string (Sol_cli_json.field [ "Version" ] json)
       |> Option.to_result ~none:"publish returned no version"
       |> Result.map_error (fun message -> Unknown message))
;;

let trim_url u =
  let rec trim s =
    if String.length s > 0 && s.[String.length s - 1] = '/'
    then trim (String.sub s 0 (String.length s - 1))
    else s
  in
  trim (String.trim u)
;;

let read_json ~path =
  let* text = Sol_cli_fs.read_file path in
  Sol_cli_json.decode ~what:"Lambda release" text
;;

let write_json ~path json =
  Sol_cli_fs.write_atomic ~perm:0o600 path (Yojson.Safe.to_string json ^ "\n")
;;

let record_kind ~path =
  let* json = read_json ~path in
  Ok (Sol_cli_json.string (Sol_cli_json.field [ "kind" ] json))
;;
