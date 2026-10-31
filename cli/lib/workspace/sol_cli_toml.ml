type rollout_strategy =
  | Recreate
  | RollingUpdate

type scheduled_concurrency =
  | Allow
  | Forbid
  | Replace

type canary_step =
  | Weight of int
  | Pause of int option

type progressive_delivery =
  | Canary of { steps : canary_step list }
  | Blue_green

type cpu_quantity = Cpu_quantity of string
type memory_quantity = Memory_quantity of string
type hostname = Hostname of string
type ingress_path = Ingress_path of string

type volume_access_mode =
  | ReadWriteOnce
  | ReadOnlyMany
  | ReadWriteMany

type volume =
  { name : string
  ; mount_path : string
  ; size : string
  ; access_mode : volume_access_mode
  }

let cpu_quantity_to_string (Cpu_quantity s) = s
let memory_quantity_to_string (Memory_quantity s) = s
let hostname_to_string (Hostname s) = s
let ingress_path_to_string (Ingress_path s) = s

let volume_access_mode_to_string = function
  | ReadWriteOnce -> "ReadWriteOnce"
  | ReadOnlyMany -> "ReadOnlyMany"
  | ReadWriteMany -> "ReadWriteMany"
;;

let volume_access_mode_of_string = function
  | "ReadWriteOnce" -> Ok ReadWriteOnce
  | "ReadOnlyMany" -> Ok ReadOnlyMany
  | "ReadWriteMany" -> Ok ReadWriteMany
  | s ->
    Error
      (Printf.sprintf
         "%S is not a volume access mode (expected ReadWriteOnce, ReadOnlyMany or \
          ReadWriteMany)"
         s)
;;

let effective_rollout_of_string s =
  let open Result.Syntax in
  match s with
  | "rolling_update" -> Ok (None, None)
  | "recreate" -> Ok (Some Recreate, None)
  | "blue_green" -> Ok (None, Some Blue_green)
  | s ->
    (match String.split_on_char ':' s with
     | [ "canary"; steps ] ->
       let ok_steps steps = Ok (None, Some (Canary { steps })) in
       if steps = ""
       then ok_steps []
       else (
         let parse_step step =
           let len = String.length step in
           if len = 0
           then Error "empty canary step"
           else (
             match step.[0] with
             | 'p' when len = 1 -> Ok (Pause None)
             | ('w' | 'p') as kind ->
               let n = String.sub step 1 (len - 1) in
               (match int_of_string_opt n with
                | None -> Error (Printf.sprintf "%S is not a canary step" step)
                | Some n -> if kind = 'w' then Ok (Weight n) else Ok (Pause (Some n)))
             | _ -> Error (Printf.sprintf "%S is not a canary step" step))
         in
         let rec go acc = function
           | [] -> Ok (List.rev acc)
           | step :: rest ->
             let* step = parse_step step in
             go (step :: acc) rest
         in
         Result.bind (go [] (String.split_on_char ',' steps)) ok_steps)
     | _ ->
       Error
         (Printf.sprintf
            "%S is not an effective rollout (expected rolling_update, recreate, \
             blue_green or canary:<steps>)"
            s))
;;

type event_decl =
  { name : string
  ; topic : string
  ; partitions : int
  ; key_field : string option
  ; schema : string
  }

type binding_language =
  | Ocaml
  | Typescript

let binding_language_of_string = function
  | "ocaml" -> Ok Ocaml
  | "typescript" -> Ok Typescript
  | other ->
    Error
      (Printf.sprintf
         "unknown contract language %S — supported values are \"ocaml\" and \
          \"typescript\""
         other)
;;

let binding_language_to_string = function
  | Ocaml -> "ocaml"
  | Typescript -> "typescript"
;;

type t =
  { replicas : int option
  ; availability : Sol_cli_availability.t option
  ; cpu : cpu_quantity option
  ; memory : memory_quantity option
  ; env_config : (string * string) list
  ; secret_keys : string list
  ; build_secret_keys : string list
  ; volumes : volume list
  ; rollout_strategy : rollout_strategy option
  ; ingress_host : hostname option
  ; ingress_path : ingress_path option
  ; extra_labels : (string * string) list
  ; progressive_delivery : progressive_delivery option
  ; schedule : string option
  ; schedule_timezone : string option
  ; scheduled_concurrency : scheduled_concurrency option
  ; backoff_limit : int option
  ; calls : string list
  ; topics : string list
  ; events : event_decl list
  ; contract_language : binding_language option
  }

let empty =
  { replicas = None
  ; availability = None
  ; cpu = None
  ; memory = None
  ; env_config = []
  ; secret_keys = []
  ; build_secret_keys = []
  ; volumes = []
  ; rollout_strategy = None
  ; ingress_host = None
  ; ingress_path = None
  ; extra_labels = []
  ; progressive_delivery = None
  ; schedule = None
  ; schedule_timezone = None
  ; scheduled_concurrency = None
  ; backoff_limit = None
  ; calls = []
  ; topics = []
  ; events = []
  ; contract_language = None
  }
;;

type parse_error =
  | Toml_syntax of
      { path : string
      ; message : string
      }
  | Validation of
      { path : string
      ; message : string
      }

let parse_error_to_string = function
  | Toml_syntax { path; message } | Validation { path; message } ->
    Printf.sprintf "%s: %s" path message
;;

let validation_error path message = Error (Validation { path; message })

open Result.Syntax

let is_digit c = c >= '0' && c <= '9'
let is_lower_alnum c = (c >= 'a' && c <= 'z') || is_digit c

let split_on_dot s =
  let rec loop acc start i =
    if i = String.length s
    then List.rev (String.sub s start (i - start) :: acc)
    else if s.[i] = '.'
    then loop (String.sub s start (i - start) :: acc) (i + 1) (i + 1)
    else loop acc start (i + 1)
  in
  loop [] 0 0
;;

let has_decimal_digits s =
  let len = String.length s in
  let digits start stop =
    let rec loop i =
      if i = stop then true else if is_digit s.[i] then loop (i + 1) else false
    in
    start < stop && loop start
  in
  match String.index_opt s '.' with
  | None -> digits 0 len
  | Some dot ->
    (digits 0 dot || digits (dot + 1) len)
    &&
    let rec loop i =
      if i = len then true else if i = dot || is_digit s.[i] then loop (i + 1) else false
    in
    loop 0
;;

let cpu_quantity_of_string s =
  let len = String.length s in
  if len = 0
  then Error "sol.toml: [infra.scale] cpu quantity must not be empty"
  else (
    let valid =
      if len > 1 && s.[len - 1] = 'm'
      then (
        let millicores = String.sub s 0 (len - 1) in
        has_decimal_digits millicores && not (String.contains millicores '.'))
      else has_decimal_digits s
    in
    if valid
    then Ok (Cpu_quantity s)
    else
      Error
        (Printf.sprintf
           "sol.toml: [infra.scale] cpu quantity %S is invalid — use cores like \"1\" or \
            \"0.5\", or millicores like \"250m\""
           s))
;;

let memory_suffixes =
  [ ""; "Ki"; "Mi"; "Gi"; "Ti"; "Pi"; "Ei"; "k"; "K"; "M"; "G"; "T"; "P"; "E" ]
;;

let memory_quantity_of_string s =
  let len = String.length s in
  if len = 0
  then Error "sol.toml: [infra.scale] memory quantity must not be empty"
  else (
    let suffix =
      List.find_opt
        (fun suffix ->
           let slen = String.length suffix in
           slen <= len && String.sub s (len - slen) slen = suffix)
        (memory_suffixes
         |> List.sort (fun a b -> compare (String.length b) (String.length a)))
    in
    match suffix with
    | None ->
      Error
        (Printf.sprintf
           "sol.toml: [infra.scale] memory quantity %S is invalid — use bytes or memory \
            suffixes like \"128Mi\" or \"1Gi\""
           s)
    | Some suffix ->
      let number = String.sub s 0 (len - String.length suffix) in
      if has_decimal_digits number
      then Ok (Memory_quantity s)
      else
        Error
          (Printf.sprintf
             "sol.toml: [infra.scale] memory quantity %S is invalid — use bytes or \
              memory suffixes like \"128Mi\" or \"1Gi\""
             s))
;;

let validate_hostname_label label =
  let len = String.length label in
  len > 0
  && len <= 63
  && is_lower_alnum label.[0]
  && is_lower_alnum label.[len - 1]
  &&
  let rec loop i =
    if i = len
    then true
    else (
      let c = label.[i] in
      (is_lower_alnum c || c = '-') && loop (i + 1))
  in
  loop 0
;;

let hostname_of_string s =
  let len = String.length s in
  if len = 0 || len > 253
  then Error "sol.toml: [infra.deploy] ingress_host must be a DNS hostname"
  else if String.contains s '*'
  then
    Error
      (Printf.sprintf
         "sol.toml: [infra.deploy] ingress_host %S is invalid — wildcard hosts are not \
          supported"
         s)
  else if List.for_all validate_hostname_label (split_on_dot s)
  then Ok (Hostname s)
  else
    Error
      (Printf.sprintf
         "sol.toml: [infra.deploy] ingress_host %S is invalid — use a DNS hostname like \
          \"api.example.com\""
         s)
;;

let ingress_path_of_string s =
  let len = String.length s in
  let rec has_invalid_char i =
    if i = len
    then false
    else (
      match s.[i] with
      | '\000' .. '\032' | '\127' -> true
      | _ -> has_invalid_char (i + 1))
  in
  if len = 0 || s.[0] <> '/'
  then
    Error
      (Printf.sprintf
         "sol.toml: [infra.deploy] ingress_path %S is invalid — paths must start with \
          \"/\""
         s)
  else if has_invalid_char 0
  then
    Error
      (Printf.sprintf
         "sol.toml: [infra.deploy] ingress_path %S is invalid — paths must not contain \
          whitespace or control characters"
         s)
  else Ok (Ingress_path s)
;;

let parse_rollout_strategy path s =
  match s with
  | "Recreate" -> Ok Recreate
  | "RollingUpdate" -> Ok RollingUpdate
  | other ->
    validation_error
      path
      (Printf.sprintf
         "sol.toml: unsupported rollout_strategy %S — valid values are \"Recreate\" and \
          \"RollingUpdate\""
         other)
;;

let scheduled_concurrency_to_string = function
  | Allow -> "allow"
  | Forbid -> "forbid"
  | Replace -> "replace"
;;

let scheduled_concurrency_of_string s =
  match s with
  | "allow" -> Ok Allow
  | "forbid" -> Ok Forbid
  | "replace" -> Ok Replace
  | other ->
    Error
      (Printf.sprintf
         "unsupported scheduled_concurrency %S — valid values are \"allow\", \"forbid\", \
          and \"replace\""
         other)
;;

let parse_scheduled_concurrency path s =
  match scheduled_concurrency_of_string s with
  | Ok concurrency -> Ok concurrency
  | Error message -> validation_error path (Printf.sprintf "sol.toml: %s" message)
;;

let validate_opt path parse = function
  | None -> Ok None
  | Some s ->
    parse s
    |> Result.map (fun v -> Some v)
    |> Result.map_error (fun message -> Validation { path; message })
;;

let parse_volume_access_mode path ~volume_name = function
  | "ReadWriteOnce" -> Ok ReadWriteOnce
  | "ReadOnlyMany" -> Ok ReadOnlyMany
  | "ReadWriteMany" -> Ok ReadWriteMany
  | other ->
    validation_error
      path
      (Printf.sprintf
         "sol.toml: [infra.volumes.%s] access_mode %S is invalid — valid values are \
          \"ReadWriteOnce\", \"ReadOnlyMany\", and \"ReadWriteMany\""
         volume_name
         other)
;;

let volume_string_field path ~volume_name ~field fields =
  match List.assoc_opt field fields with
  | None ->
    validation_error
      path
      (Printf.sprintf
         "sol.toml: [infra.volumes.%s] missing required %s"
         volume_name
         field)
  | Some v ->
    (try Ok (Otoml.get_string v) with
     | Otoml.Type_error _ ->
       validation_error
         path
         (Printf.sprintf
            "sol.toml: [infra.volumes.%s] %s must be a string"
            volume_name
            field))
;;

let parse_volume path (name, value) =
  let* fields =
    try Otoml.get_table value |> Result.ok with
    | Otoml.Type_error _ ->
      validation_error
        path
        (Printf.sprintf "sol.toml: [infra.volumes.%s] must be a table" name)
  in
  let* mount_path =
    volume_string_field path ~volume_name:name ~field:"mount_path" fields
  in
  let* size = volume_string_field path ~volume_name:name ~field:"size" fields in
  let* access_mode =
    match List.assoc_opt "access_mode" fields with
    | None -> Ok ReadWriteOnce
    | Some v ->
      (try parse_volume_access_mode path ~volume_name:name (Otoml.get_string v) with
       | Otoml.Type_error _ ->
         validation_error
           path
           (Printf.sprintf
              "sol.toml: [infra.volumes.%s] access_mode must be a string"
              name))
  in
  if not (validate_hostname_label name)
  then
    validation_error
      path
      (Printf.sprintf
         "sol.toml: [infra.volumes.%s] name is invalid — use lowercase letters, digits, \
          and hyphens"
         name)
  else if String.length mount_path = 0 || mount_path.[0] <> '/'
  then
    validation_error
      path
      (Printf.sprintf
         "sol.toml: [infra.volumes.%s] mount_path must be an absolute path"
         name)
  else if Sol_cli_string.is_blank size
  then
    validation_error
      path
      (Printf.sprintf "sol.toml: [infra.volumes.%s] size must not be empty" name)
  else Ok { name; mount_path; size; access_mode }
;;

let parse_volumes path doc =
  match Otoml.find_opt doc Otoml.get_value [ "infra"; "volumes" ] with
  | None -> Ok []
  | Some v ->
    let* entries =
      try Otoml.get_table v |> Result.ok with
      | Otoml.Type_error _ ->
        validation_error
          path
          "sol.toml: [infra.volumes] must be a table of tables, e.g. [infra.volumes.data]"
    in
    List.fold_left
      (fun acc entry ->
         let* acc = acc in
         let* volume = parse_volume path entry in
         Ok (volume :: acc))
      (Ok [])
      entries
    |> Result.map List.rev
;;

let validate_extra_label_key k =
  let prefix = "sol.dev/" in
  if String.starts_with ~prefix k
  then
    Error
      (Printf.sprintf
         "sol.toml: extra_labels key %S is reserved — keys may not start with \
          \"sol.dev/\""
         k)
  else Ok ()
;;

let validate_weight n =
  if n < 0 || n > 100
  then
    Error
      (Printf.sprintf
         "sol.toml: [infra.rollout] canary weight %d is invalid — weights must be \
          between 0 and 100"
         n)
  else Ok ()
;;

let validate_duration d =
  if d <= 0
  then
    Error
      (Printf.sprintf
         "sol.toml: [infra.rollout] pause duration %d is invalid — durations must be \
          positive seconds"
         d)
  else Ok ()
;;

let validate_canary_step = function
  | Weight n -> validate_weight n
  | Pause None -> Ok ()
  | Pause (Some d) -> validate_duration d
;;

let parse_canary_step_value path v =
  let* pairs =
    try Otoml.get_table v |> Result.ok with
    | Otoml.Type_error _ ->
      validation_error
        path
        "sol.toml: [infra.rollout] canary step must be an inline table like {weight = \
         10} or {pause = {}}"
  in
  match List.assoc_opt "weight" pairs with
  | Some wv ->
    let* n =
      try Otoml.get_integer wv |> Result.ok with
      | Otoml.Type_error _ ->
        validation_error path "sol.toml: [infra.rollout] canary weight must be an integer"
    in
    let step = Weight n in
    let* () =
      validate_canary_step step
      |> Result.map_error (fun message -> Validation { path; message })
    in
    Ok step
  | None ->
    (match List.assoc_opt "pause" pairs with
     | Some pv ->
       let* inner =
         try Otoml.get_table pv |> Result.ok with
         | Otoml.Type_error _ ->
           validation_error
             path
             "sol.toml: [infra.rollout] pause value must be an inline table like {} or \
              {duration = 60}"
       in
       let* step =
         match List.assoc_opt "duration" inner with
         | Some dv ->
           let* d =
             try Otoml.get_integer dv |> Result.ok with
             | Otoml.Type_error _ ->
               validation_error
                 path
                 "sol.toml: [infra.rollout] pause duration must be an integer"
           in
           Ok (Pause (Some d))
         | None -> Ok (Pause None)
       in
       let* () =
         validate_canary_step step
         |> Result.map_error (fun message -> Validation { path; message })
       in
       Ok step
     | None ->
       validation_error
         path
         "sol.toml: unsupported [infra.rollout] canary step — expected {weight = N} or \
          {pause = {...}}")
;;

let parse_steps path doc =
  match Otoml.find_opt doc Otoml.get_value [ "infra"; "rollout"; "steps" ] with
  | None -> Ok []
  | Some arr_v ->
    let* items =
      try Otoml.get_array Otoml.get_value arr_v |> Result.ok with
      | Otoml.Type_error _ ->
        validation_error path "sol.toml: [infra.rollout] steps must be an array"
    in
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match item with
         | Otoml.TomlInteger n ->
           let step = Weight n in
           let* () =
             validate_canary_step step
             |> Result.map_error (fun message -> Validation { path; message })
           in
           loop (step :: acc) rest
         | _ ->
           let* step = parse_canary_step_value path item in
           loop (step :: acc) rest)
    in
    loop [] items
;;

let valid_event_name name =
  let len = String.length name in
  let valid_first c = c >= 'A' && c <= 'Z' in
  let valid_rest c =
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_'
  in
  len > 0
  && valid_first name.[0]
  &&
  let rec loop i = i = len || (valid_rest name.[i] && loop (i + 1)) in
  loop 1
;;

let schema_properties schema =
  try
    match Yojson.Safe.from_string schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc props) -> Some (List.map fst props)
       | _ -> None)
    | _ -> None
  with
  | Yojson.Json_error _ -> None
;;

let parse_event path index = function
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs ->
    let string_field field =
      match List.assoc_opt field pairs with
      | None ->
        validation_error
          path
          (Printf.sprintf
             "sol.toml: [[events]] entry %d is missing required %s"
             index
             field)
      | Some v ->
        (try Ok (Otoml.get_string v) with
         | Otoml.Type_error _ ->
           validation_error
             path
             (Printf.sprintf
                "sol.toml: [[events]] entry %d %s must be a string"
                index
                field))
    in
    let* name = string_field "name" in
    let* topic = string_field "topic" in
    let* schema = string_field "schema" in
    let* partitions =
      match List.assoc_opt "partitions" pairs with
      | None ->
        validation_error
          path
          (Printf.sprintf
             "sol.toml: [[events]] entry %d is missing required partitions"
             index)
      | Some v ->
        (try Ok (Otoml.get_integer v) with
         | Otoml.Type_error _ ->
           validation_error
             path
             (Printf.sprintf
                "sol.toml: [[events]] entry %d partitions must be an integer"
                index))
    in
    let* key_field =
      match List.assoc_opt "key" pairs with
      | None -> Ok None
      | Some v ->
        (try Ok (Some (Otoml.get_string v)) with
         | Otoml.Type_error _ ->
           validation_error
             path
             (Printf.sprintf "sol.toml: [[events]] entry %d key must be a string" index))
    in
    let* () =
      if valid_event_name name
      then Ok ()
      else
        validation_error
          path
          (Printf.sprintf
             "sol.toml: [[events]] entry %d name %S is not a valid event name — use an \
              uppercase letter followed by letters, digits or underscores"
             index
             name)
    in
    let* () =
      if Sol_cli_string.is_blank topic
      then
        validation_error
          path
          (Printf.sprintf "sol.toml: [[events]] entry %d topic must not be empty" index)
      else Ok ()
    in
    let* () =
      if partitions < 1
      then
        validation_error
          path
          (Printf.sprintf
             "sol.toml: [[events]] entry %d partitions must be at least 1"
             index)
      else Ok ()
    in
    let* properties =
      match schema_properties schema with
      | Some properties -> Ok properties
      | None ->
        validation_error
          path
          (Printf.sprintf
             "sol.toml: [[events]] entry %d schema must be a JSON object with a \
              properties table"
             index)
    in
    let* () =
      match key_field with
      | None -> Ok ()
      | Some key ->
        if List.mem key properties
        then Ok ()
        else
          validation_error
            path
            (Printf.sprintf
               "sol.toml: [[events]] entry %d key %S is not a property of its schema — \
                the declared key must name a field of the message"
               index
               key)
    in
    Ok { name; topic; partitions; key_field; schema }
  | _ ->
    validation_error
      path
      (Printf.sprintf "sol.toml: [[events]] entry %d must be a table" index)
;;

let parse_events path doc =
  match Otoml.find_opt doc Otoml.get_value [ "events" ] with
  | None -> Ok []
  | Some value ->
    let entries =
      match value with
      | Otoml.TomlArray entries | Otoml.TomlTableArray entries -> entries
      | _ -> []
    in
    let rec loop acc index = function
      | [] -> Ok (List.rev acc)
      | entry :: rest ->
        let* event = parse_event path index entry in
        loop (event :: acc) (index + 1) rest
    in
    let* events = loop [] 0 entries in
    let names = List.map (fun event -> event.name) events in
    if List.length names = List.length (List.sort_uniq String.compare names)
    then Ok events
    else validation_error path "sol.toml: [[events]] declares the same name twice"
;;

type key_schema =
  | Leaf
  | Table of (string * key_schema) list
  | User_table
  | Volumes
  | Canary_steps
  | Events

let volume_schema = [ "mount_path", Leaf; "size", Leaf; "access_mode", Leaf ]

let event_schema =
  [ "name", Leaf; "topic", Leaf; "partitions", Leaf; "key", Leaf; "schema", Leaf ]
;;

let schema =
  [ ( "infra"
    , Table
        [ ( "scale"
          , Table [ "replicas", Leaf; "availability", Leaf; "cpu", Leaf; "memory", Leaf ]
          )
        ; "env", Table [ "config", User_table; "secrets", Leaf; "build_secrets", Leaf ]
        ; "volumes", Volumes
        ; ( "deploy"
          , Table [ "rollout_strategy", Leaf; "ingress_host", Leaf; "ingress_path", Leaf ]
          )
        ; "labels", Table [ "extra_labels", User_table ]
        ; "rollout", Table [ "strategy", Leaf; "steps", Canary_steps ]
        ] )
  ; ( "service"
    , Table
        [ "schedule", Leaf
        ; "schedule_timezone", Leaf
        ; "scheduled_concurrency", Leaf
        ; "backoff_limit", Leaf
        ; "calls", Leaf
        ; "topics", Leaf
        ] )
  ; "events", Events
  ; "contract", Table [ "language", Leaf ]
  ]
;;

let table_name = function
  | [] -> "the top level"
  | keys -> "[" ^ String.concat "." keys ^ "]"
;;

let rec check_keys path ~at known pairs =
  match pairs with
  | [] -> Ok ()
  | (key, value) :: rest ->
    (match List.assoc_opt key known with
     | None ->
       validation_error
         path
         (Printf.sprintf
            "sol.toml: unknown key %S in %s; the keys Sol reads there are: %s"
            key
            (table_name at)
            (String.concat ", " (List.map fst known)))
     | Some sub ->
       let* () = check_value path ~at:(at @ [ key ]) sub value in
       check_keys path ~at known rest)

and check_value path ~at sub value =
  match sub with
  | Leaf | User_table -> Ok ()
  | Table known ->
    (match value with
     | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs ->
       check_keys path ~at known pairs
     | _ ->
       validation_error
         path
         (Printf.sprintf "sol.toml: %s must be a table" (table_name at)))
  | Volumes ->
    (match value with
     | Otoml.TomlTable volumes | Otoml.TomlInlineTable volumes ->
       List.fold_left
         (fun acc (name, volume) ->
            let* () = acc in
            check_value path ~at:(at @ [ name ]) (Table volume_schema) volume)
         (Ok ())
         volumes
     | _ -> Ok ())
  | Canary_steps ->
    (match value with
     | Otoml.TomlArray steps | Otoml.TomlTableArray steps ->
       List.fold_left
         (fun acc step ->
            let* () = acc in
            match step with
            | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs ->
              check_keys
                path
                ~at
                [ "weight", Leaf; "pause", Table [ "duration", Leaf ] ]
                pairs
            | _ -> Ok ())
         (Ok ())
         steps
     | _ -> Ok ())
  | Events ->
    (match value with
     | Otoml.TomlArray events | Otoml.TomlTableArray events ->
       List.fold_left
         (fun acc event ->
            let* () = acc in
            match event with
            | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs ->
              check_keys path ~at event_schema pairs
            | _ -> Ok ())
         (Ok ())
         events
     | _ ->
       validation_error
         path
         "sol.toml: [[events]] must be an array of tables, e.g. [[events]] name = ...")
;;

let check_known_keys path doc =
  match doc with
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs ->
    check_keys path ~at:[] schema pairs
  | _ -> Ok ()
;;

let refuse_nul path doc =
  let has_nul s = String.contains s '\000' in
  let rec find keys = function
    | Otoml.TomlString s when has_nul s -> Some (List.rev keys)
    | Otoml.TomlArray items | Otoml.TomlTableArray items ->
      List.find_map (find keys) items
    | Otoml.TomlTable members | Otoml.TomlInlineTable members ->
      members
      |> List.find_map (fun (key, value) ->
        if has_nul key then Some (List.rev (key :: keys)) else find (key :: keys) value)
    | _ -> None
  in
  match find [] doc with
  | None -> Ok ()
  | Some keys ->
    validation_error
      path
      (Printf.sprintf
         "%s contains a NUL character, which cannot be written into a manifest"
         (String.concat "." keys))
;;

let load_result path =
  try
    if not (Sys.file_exists path)
    then Ok empty
    else
      let* doc =
        match Otoml.Parser.from_file_result path with
        | Ok d -> Ok d
        | Error msg ->
          Error (Toml_syntax { path; message = Printf.sprintf "sol.toml: %s" msg })
      in
      let* () = check_known_keys path doc in
      let* () = refuse_nul path doc in
      let replicas =
        Otoml.Helpers.find_integer_opt doc [ "infra"; "scale"; "replicas" ]
      in
      let* availability =
        Otoml.Helpers.find_string_opt doc [ "infra"; "scale"; "availability" ]
        |> validate_opt path Sol_cli_availability.of_string
      in
      let* cpu =
        Otoml.Helpers.find_string_opt doc [ "infra"; "scale"; "cpu" ]
        |> validate_opt path cpu_quantity_of_string
      in
      let* memory =
        Otoml.Helpers.find_string_opt doc [ "infra"; "scale"; "memory" ]
        |> validate_opt path memory_quantity_of_string
      in
      let* env_config =
        match Otoml.find_opt doc Otoml.get_value [ "infra"; "env"; "config" ] with
        | None -> Ok []
        | Some v ->
          (try Otoml.get_table_values Otoml.get_string v |> Result.ok with
           | Otoml.Type_error _ ->
             validation_error
               path
               "sol.toml: [infra.env] config must be an inline table of string values, \
                e.g. config = { KEY = \"val\" }")
      in
      let* secret_keys =
        match Otoml.find_opt doc Otoml.get_value [ "infra"; "env"; "secrets" ] with
        | None -> Ok []
        | Some v ->
          (try Otoml.get_array Otoml.get_string v |> Result.ok with
           | Otoml.Type_error _ ->
             validation_error
               path
               "sol.toml: [infra.env] secrets must be an array of strings, e.g. secrets \
                = [\"KEY1\", \"KEY2\"]")
      in
      let* build_secret_keys =
        match Otoml.find_opt doc Otoml.get_value [ "infra"; "env"; "build_secrets" ] with
        | None -> Ok []
        | Some v ->
          (try Otoml.get_array Otoml.get_string v |> Result.ok with
           | Otoml.Type_error _ ->
             validation_error
               path
               "sol.toml: [infra.env] build_secrets must be an array of strings, e.g. \
                build_secrets = [\"BUILD_TOKEN\"]")
      in
      let* () =
        match List.find_opt (fun key -> List.mem key secret_keys) build_secret_keys with
        | None -> Ok ()
        | Some key ->
          validation_error
            path
            (Printf.sprintf
               "sol.toml: [infra.env] %S is declared in both secrets (runtime) and \
                build_secrets (build time); a build that can read a runtime secret is a \
                build that can leak it, so a key must be one or the other"
               key)
      in
      let* () =
        let reserved_identity =
          [ "SOL_UNIT"; "SOL_CALLED_BY"; "SOL_TRUSTED_WORKLOAD_ISSUER" ]
        in
        let reserved_development =
          [ "SOL_ALLOW_UNVERIFIED_JWT"; "SOL_ALLOW_PLAINTEXT_PEER_AUTH" ]
        in
        match
          List.find_opt
            (fun key ->
               List.mem_assoc key env_config
               || List.mem key secret_keys
               || List.mem key build_secret_keys)
            (reserved_identity @ reserved_development)
        with
        | None -> Ok ()
        | Some key when List.mem key reserved_identity ->
          validation_error
            path
            (Printf.sprintf
               "sol.toml: [infra.env] config, secrets and build_secrets may not set %s \
                -- it is projected from the declared calls graph and must not be spoofed"
               key)
        | Some key ->
          validation_error
            path
            (Printf.sprintf
               "sol.toml: [infra.env] config, secrets and build_secrets may not set %s \
                -- it enables a development-only authentication posture, and only local \
                tooling sets it"
               key)
      in
      let* volumes = parse_volumes path doc in
      let* rollout_strategy =
        match
          Otoml.Helpers.find_string_opt doc [ "infra"; "deploy"; "rollout_strategy" ]
        with
        | None -> Ok None
        | Some s ->
          let* strategy = parse_rollout_strategy path s in
          Ok (Some strategy)
      in
      let* ingress_host =
        Otoml.Helpers.find_string_opt doc [ "infra"; "deploy"; "ingress_host" ]
        |> validate_opt path hostname_of_string
      in
      let* ingress_path =
        Otoml.Helpers.find_string_opt doc [ "infra"; "deploy"; "ingress_path" ]
        |> validate_opt path ingress_path_of_string
      in
      let* extra_labels =
        match
          Otoml.find_opt doc Otoml.get_value [ "infra"; "labels"; "extra_labels" ]
        with
        | None -> Ok []
        | Some v ->
          let* pairs =
            try Otoml.get_table_values Otoml.get_string v |> Result.ok with
            | Otoml.Type_error _ ->
              validation_error
                path
                "sol.toml: [infra.labels] extra_labels must be an inline table of string \
                 values, e.g. extra_labels = { key = \"val\" }"
          in
          let rec validate_keys = function
            | [] -> Ok pairs
            | (k, _) :: rest ->
              let* () =
                validate_extra_label_key k
                |> Result.map_error (fun message -> Validation { path; message })
              in
              validate_keys rest
          in
          validate_keys pairs
      in
      let* progressive_delivery =
        match Otoml.Helpers.find_string_opt doc [ "infra"; "rollout"; "strategy" ] with
        | None -> Ok None
        | Some "canary" ->
          let* steps = parse_steps path doc in
          if steps = []
          then
            validation_error
              path
              "sol.toml: [infra.rollout] strategy \"canary\" requires at least one step \
               in steps = [...]"
          else Ok (Some (Canary { steps }))
        | Some "blue-green" -> Ok (Some Blue_green)
        | Some other ->
          validation_error
            path
            (Printf.sprintf
               "sol.toml: unsupported [infra.rollout] strategy %S — valid values are \
                \"canary\" and \"blue-green\""
               other)
      in
      let schedule = Otoml.Helpers.find_string_opt doc [ "service"; "schedule" ] in
      let schedule_timezone =
        Otoml.Helpers.find_string_opt doc [ "service"; "schedule_timezone" ]
      in
      let* scheduled_concurrency =
        match
          Otoml.Helpers.find_string_opt doc [ "service"; "scheduled_concurrency" ]
        with
        | None -> Ok None
        | Some s ->
          let* c = parse_scheduled_concurrency path s in
          Ok (Some c)
      in
      let backoff_limit =
        Otoml.Helpers.find_integer_opt doc [ "service"; "backoff_limit" ]
      in
      let* calls =
        match Otoml.find_opt doc Otoml.get_value [ "service"; "calls" ] with
        | None -> Ok []
        | Some v ->
          (try Otoml.get_array Otoml.get_string v |> Result.ok with
           | Otoml.Type_error _ ->
             validation_error
               path
               "sol.toml: [service] calls must be an array of strings, e.g. calls = \
                [\"checkout/checkout_svc\"]")
      in
      let* topics =
        match Otoml.find_opt doc Otoml.get_value [ "service"; "topics" ] with
        | None -> Ok []
        | Some v ->
          (try Otoml.get_array Otoml.get_string v |> Result.ok with
           | Otoml.Type_error _ ->
             validation_error
               path
               "sol.toml: [service] topics must be an array of strings, e.g. topics = \
                [\"my-topic\"]")
      in
      let* events = parse_events path doc in
      let* contract_language =
        match Otoml.find_opt doc Otoml.get_value [ "contract"; "language" ] with
        | None -> Ok None
        | Some v ->
          (try
             match binding_language_of_string (Otoml.get_string v) with
             | Ok language -> Ok (Some language)
             | Error message ->
               validation_error path (Printf.sprintf "sol.toml: %s" message)
           with
           | Otoml.Type_error _ ->
             validation_error
               path
               "sol.toml: [contract] language must be a string, e.g. language = \
                \"typescript\"")
      in
      let* () =
        if events = [] || contract_language <> None
        then Ok ()
        else
          validation_error
            path
            "sol.toml: [[events]] declares a contract but [contract] language is missing \
             — state the binding language, e.g. [contract] language = \"ocaml\""
      in
      Ok
        { replicas
        ; availability
        ; cpu
        ; memory
        ; env_config
        ; secret_keys
        ; build_secret_keys
        ; volumes
        ; rollout_strategy
        ; ingress_host
        ; ingress_path
        ; extra_labels
        ; progressive_delivery
        ; schedule
        ; schedule_timezone
        ; scheduled_concurrency
        ; backoff_limit
        ; calls
        ; topics
        ; events
        ; contract_language
        }
  with
  | Otoml.Type_error message -> Error (Validation { path; message })
;;
