open Result.Syntax

type command =
  { argv : string list
  ; cwd : string
  }

type recipe =
  { label : string
  ; language : Sol_cli_compat.language
  ; build : command option
  ; launch : command
  ; artifact : string
  ; env : (string * string) list
  }

type plan =
  { builds : command list
  ; launches : recipe list
  ; redact : string list
  }

let label (svc : Sol_cli_manifest.service) = svc.domain ^ "/" ^ svc.name

let join root path =
  match path with
  | "" | "." -> root
  | path -> Filename.concat root path
;;

let relative_under ~prefix dir =
  match prefix with
  | "" | "." -> dir
  | prefix ->
    if String.equal dir prefix
    then ""
    else
      String.sub
        dir
        (String.length prefix + 1)
        (String.length dir - String.length prefix - 1)
;;

let read_json_opt path =
  match In_channel.with_open_bin path In_channel.input_all with
  | text ->
    (match Yojson.Safe.from_string text with
     | json -> Ok (Some json)
     | exception Yojson.Json_error msg -> Error (Printf.sprintf "%s: %s" path msg))
  | exception Sys_error msg ->
    if Sys.file_exists path then Error (Printf.sprintf "%s: %s" path msg) else Ok None
;;

let optional_string_field ~what json key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | None | Some `Null -> Ok None
     | Some (`String value) -> Ok (Some value)
     | Some _ -> Error (Printf.sprintf "%s: %s must be text" what key))
  | _ -> Error (Printf.sprintf "%s: expected a JSON object" what)
;;

let strings_field ~what value =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | `String item :: rest -> go (item :: acc) rest
    | _ -> Error (Printf.sprintf "%s must be a list of strings" what)
  in
  match value with
  | `List entries -> go [] entries
  | _ -> Error (Printf.sprintf "%s must be a list of strings" what)
;;

let workspaces_of json =
  match Sol_cli_json.field [ "workspaces" ] json with
  | `Null -> Ok []
  | `Assoc fields ->
    (match List.assoc_opt "packages" fields with
     | None | Some `Null -> Ok []
     | Some packages -> strings_field ~what:"workspaces.packages" packages)
  | workspaces -> strings_field ~what:"workspaces" workspaces
;;

let glob_matches pattern path =
  let plen = String.length pattern
  and slen = String.length path in
  let rec go p s =
    if p = plen
    then s = slen
    else (
      match pattern.[p] with
      | '*' when p + 1 < plen && pattern.[p + 1] = '*' ->
        let rec any s' = s' <= slen && (go (p + 2) s' || any (s' + 1)) in
        any s
      | '*' ->
        let rec any s' =
          s' <= slen && (go (p + 1) s' || (s' < slen && path.[s'] <> '/' && any (s' + 1)))
        in
        any s
      | '?' -> s < slen && path.[s] <> '/' && go (p + 1) (s + 1)
      | c -> s < slen && path.[s] = c && go (p + 1) (s + 1))
  in
  go 0 0
;;

let normalize_workspace_entry entry =
  let entry =
    if String.length entry >= 2 && String.sub entry 0 2 = "./"
    then String.sub entry 2 (String.length entry - 2)
    else entry
  in
  let rec strip_trailing s =
    let len = String.length s in
    if len > 0 && s.[len - 1] = '/' then strip_trailing (String.sub s 0 (len - 1)) else s
  in
  strip_trailing entry
;;

let declares ~entry ~relative_dir =
  let entry = normalize_workspace_entry entry in
  String.equal entry relative_dir || glob_matches entry relative_dir
;;

let npm_project_root ~root ~unit_dir =
  let rec up dir =
    if String.equal dir "" || String.equal dir "."
    then Ok None
    else (
      let parent = Filename.dirname dir in
      let parent = if String.equal parent "." then "" else parent in
      let relative_dir = relative_under ~prefix:parent unit_dir in
      let package_path = Filename.concat (join root parent) "package.json" in
      let* package = read_json_opt package_path in
      match package with
      | None -> up parent
      | Some json ->
        let* entries =
          workspaces_of json
          |> Result.map_error (fun msg -> Printf.sprintf "%s: %s" package_path msg)
        in
        if List.exists (fun entry -> declares ~entry ~relative_dir) entries
        then Ok (Some parent)
        else up parent)
  in
  match up unit_dir with
  | Ok (Some npm_root) -> Ok npm_root
  | Ok None -> Ok unit_dir
  | Error _ as error -> error
;;

let entry_in_unit ~root ~unit_dir ~package_path ~package_json =
  let* main = optional_string_field ~what:package_path package_json "main" in
  match main with
  | Some main -> Ok main
  | None ->
    let tsconfig_path = Filename.concat (join root unit_dir) "tsconfig.json" in
    let* tsconfig = read_json_opt tsconfig_path in
    let* out_dir =
      match tsconfig with
      | None -> Ok "dist"
      | Some json ->
        (match Sol_cli_json.field [ "compilerOptions" ] json with
         | `Null -> Ok "dist"
         | `Assoc fields ->
           (match List.assoc_opt "outDir" fields with
            | None | Some `Null -> Ok "dist"
            | Some (`String out_dir) -> Ok out_dir
            | Some _ ->
              Error
                (Printf.sprintf "%s: compilerOptions.outDir must be text" tsconfig_path))
         | _ ->
           Error (Printf.sprintf "%s: compilerOptions must be an object" tsconfig_path))
    in
    Ok (Filename.concat out_dir "index.js")
;;

let dev_registry_url = "http://localhost:8081"

let dev_env =
  [ "LOKI_URL", "http://localhost:3100"
  ; "PUSHGATEWAY_URL", "http://localhost:9091"
  ; "TEMPO_URL", "http://localhost:4318"
  ; (* Bare local processes have no projected ServiceAccount token, so they opt
       in explicitly to the shared-key caller path (DEC-063). Deployed units
       never set this: the key is reserved in sol.toml and sol secret set. *)
    "SOL_ALLOW_PLAINTEXT_PEER_AUTH", "1"
  ]
;;

let dev_identity ~root (svc : Sol_cli_manifest.service) =
  Sol_cli_manifest.identity_env
    ~workspace:(Filename.basename root)
    ~domain:svc.Sol_cli_manifest.domain
    ~service:(Sol_cli_kubernetes_name.normalize svc.Sol_cli_manifest.name)
    ~primitive:(Sol_cli_manifest.primitive_label svc.Sol_cli_manifest.primitive)
    ()
;;

let set_env key value env =
  let rec replace = function
    | [] -> [ key, value ]
    | (candidate, _) :: rest when String.equal candidate key -> (key, value) :: rest
    | entry :: rest -> entry :: replace rest
  in
  replace env
;;

let local_secret_env ~secret_values ~secret_keys ~database_consumer ~unit_address =
  let* () =
    let resource_keys =
      Sol_cli_manifest.required_secret_keys
        ~transport:Sol_cli_manifest.Sasl_ssl
        ~db_uses_target:true
        []
    in
    match List.find_opt (fun key -> List.mem key resource_keys) secret_keys with
    | None -> Ok ()
    | Some key ->
      Error
        (Printf.sprintf
           "%s is a resource connection input, not an application secret. Declare the \
            resource in uses; local execution supplies only the connections the unit \
            consumes."
           key)
  in
  let unit_values =
    Option.value ~default:[] (List.assoc_opt unit_address secret_values)
  in
  let find key = List.assoc_opt key unit_values in
  let missing =
    secret_keys
    |> List.filter (fun key ->
      match find key with
      | None | Some "" -> true
      | Some _ -> false)
    |> List.sort_uniq String.compare
  in
  match missing with
  | _ :: _ ->
    Error
      ("missing local secret value(s): "
       ^ String.concat ", " missing
       ^ ". Add them to sol/secrets.local/"
       ^ unit_address
       ^ ".env.")
  | [] ->
    let values =
      (if database_consumer then "POSTGRES_URL" :: secret_keys else secret_keys)
      |> List.sort_uniq String.compare
      |> List.filter_map (fun key -> Option.map (fun value -> key, value) (find key))
    in
    Ok values
;;

let recipe_of_ocaml ~root ~base_env ~secret_env (svc : Sol_cli_manifest.service) =
  let dir = svc.Sol_cli_manifest.dir in
  Ok
    { label = label svc
    ; language = Sol_cli_compat.Ocaml
    ; build = None
    ; launch = { argv = [ "_build/default/" ^ dir ^ "/bin/main.exe" ]; cwd = "" }
    ; artifact = dir ^ "/bin/main.exe"
    ; env =
        List.fold_left (fun env (key, value) -> set_env key value env) base_env secret_env
        @ dev_identity ~root svc
    }
;;

let recipe_of_typescript ~root ~base_env ~secret_env (svc : Sol_cli_manifest.service) =
  let unit_dir = svc.Sol_cli_manifest.dir in
  let package_path = Filename.concat (join root unit_dir) "package.json" in
  let* package =
    match read_json_opt package_path with
    | Ok (Some json) -> Ok json
    | Ok None ->
      Error
        (Printf.sprintf
           "declares language: typescript, but its package.json could not be read (%s: \
            no such file)"
           package_path)
    | Error msg ->
      Error
        (Printf.sprintf
           "declares language: typescript, but its package.json could not be read (%s)"
           msg)
  in
  let* package_name =
    let* name = optional_string_field ~what:package_path package "name" in
    match name with
    | Some name -> Ok name
    | None ->
      Error
        "declares language: typescript, but its package.json declares no name, so there \
         is no npm package to build"
  in
  let* npm_root = npm_project_root ~root ~unit_dir in
  let* () =
    if Sys.file_exists (Filename.concat (join root npm_root) "node_modules")
    then Ok ()
    else
      Error
        (Printf.sprintf
           "has no installed dependencies; run `npm ci` in %s"
           (match npm_root with
            | "" | "." -> "."
            | dir -> dir))
  in
  let build =
    if String.equal npm_root unit_dir
    then { argv = [ "npm"; "run"; "build" ]; cwd = npm_root }
    else { argv = [ "npm"; "run"; "build"; "--workspace"; package_name ]; cwd = npm_root }
  in
  let* entry = entry_in_unit ~root ~unit_dir ~package_path ~package_json:package in
  Ok
    { label = label svc
    ; language = Sol_cli_compat.Typescript
    ; build = Some build
    ; launch =
        { argv =
            [ "node"; Filename.concat (relative_under ~prefix:npm_root unit_dir) entry ]
        ; cwd = npm_root
        }
    ; artifact = Filename.concat unit_dir entry
    ; env =
        List.fold_left (fun env (key, value) -> set_env key value env) base_env secret_env
        @ dev_identity ~root svc
    }
;;

let recipe ~root ~base_env ~secret_env (svc : Sol_cli_manifest.service) language =
  match language with
  | Sol_cli_compat.Ocaml -> recipe_of_ocaml ~root ~base_env ~secret_env svc
  | Sol_cli_compat.Typescript -> recipe_of_typescript ~root ~base_env ~secret_env svc
;;

let runtime_environment () =
  let inherited_keys = [ "PATH"; "HOME"; "TMPDIR"; "TMP"; "TEMP"; "LANG"; "LC_ALL" ] in
  Unix.environment ()
  |> Array.to_list
  |> List.filter_map (fun entry ->
    match String.index_opt entry '=' with
    | None -> None
    | Some equals ->
      let key = String.sub entry 0 equals in
      if not (List.mem key inherited_keys)
      then None
      else Some (key, String.sub entry (equals + 1) (String.length entry - equals - 1)))
;;

let workload_of (facts : Sol_cli_workspace_model.t) (svc : Sol_cli_manifest.service) =
  List.find_opt
    (fun (w : Sol_cli_workspace_model.workload) ->
       String.equal w.Sol_cli_workspace_model.service.Sol_cli_manifest.domain svc.domain
       && String.equal w.Sol_cli_workspace_model.service.Sol_cli_manifest.name svc.name)
    facts.workloads
;;

let plan ?(secret_values = []) ~root ~facts services =
  let* declared =
    Sol_cli_config.load_declared ~root
    |> Result.map_error (fun error ->
      [ "workspace", Sol_cli_config.error_to_string error ])
  in
  let* () =
    Sol_cli_config.validate_service_uses
      ~path:(Filename.concat root "sol.yml")
      ~resources:declared.resources
      ~services:declared.services
    |> Result.map_error (fun error ->
      [ "workspace", Sol_cli_config.error_to_string error ])
  in
  let base_env = runtime_environment () @ dev_env in
  let resolved =
    services
    |> List.map (fun svc ->
      match workload_of facts svc with
      | None -> Error (label svc, "is not part of this workspace")
      | Some workload ->
        (match workload.config with
         | Error error -> Error (label svc, Sol_cli_toml.parse_error_to_string error)
         | Ok config ->
           let secret_keys = config.Sol_cli_toml.secret_keys in
           let database_consumer =
             Sol_cli_resource_binding.service_uses_resource_type
               (Some declared)
               svc.name
               "postgres"
           in
           let kafka_consumer =
             Sol_cli_resource_binding.consumes_kafka
               (Some declared)
               svc.name
               ~topics:config.topics
           in
           let resource_env =
             (if database_consumer
              then
                [ ( "POSTGRES_URL"
                  , Sol_cli_local_platform.postgres_url
                      ~host:"localhost"
                      ~port:(Sol_cli_local_platform.postgres_local_port ()) )
                ]
              else [])
             @
             if kafka_consumer
             then
               [ "KAFKA_BROKERS", "localhost:9092"
               ; "SCHEMA_REGISTRY_URL", dev_registry_url
               ; "REDPANDA_ADMIN_URL", "http://localhost:9644"
               ; "KAFKA_SECURITY_PROTOCOL", "plaintext"
               ]
             else []
           in
           let base_env = base_env @ resource_env in
           (match
              local_secret_env
                ~secret_values
                ~secret_keys
                ~database_consumer
                ~unit_address:(svc.domain ^ "/" ^ svc.name)
            with
            | Error message -> Error (label svc, message)
            | Ok secret_env ->
              (match workload.Sol_cli_workspace_model.language with
               | Some language ->
                 (match recipe ~root ~base_env ~secret_env svc language with
                  | Ok recipe -> Ok recipe
                  | Error message -> Error (label svc, message))
               | None ->
                 Error
                   ( label svc
                   , Printf.sprintf
                       "declares no language; add `language: ocaml` (or typescript) \
                        under services.%s in sol.yml"
                       svc.name )))))
  in
  match
    List.filter_map
      (function
        | Error e -> Some e
        | Ok _ -> None)
      resolved
  with
  | _ :: _ as errors -> Error errors
  | [] ->
    let recipes =
      List.filter_map
        (function
          | Ok r -> Some r
          | Error _ -> None)
        resolved
    in
    let dune_targets =
      recipes
      |> List.filter_map (fun r ->
        match r.language with
        | Sol_cli_compat.Ocaml -> Some r.artifact
        | Sol_cli_compat.Typescript -> None)
    in
    let ocaml_build =
      match dune_targets with
      | [] -> []
      | targets -> [ { argv = "dune" :: "build" :: targets; cwd = "" } ]
    in
    let unit_builds = List.filter_map (fun r -> r.build) recipes in
    let redact =
      recipes
      |> List.concat_map (fun recipe ->
        recipe.env
        |> List.filter_map (fun (key, value) ->
          if
            String.equal key "POSTGRES_URL"
            || String.equal key "SOL_API_KEY"
            || List.exists
                 (fun (workload : Sol_cli_workspace_model.workload) ->
                    match workload.config with
                    | Ok config -> List.mem key config.secret_keys
                    | Error _ -> false)
                 facts.workloads
          then Some value
          else None))
      |> List.filter (fun value -> not (String.equal value ""))
      |> List.sort_uniq String.compare
    in
    Ok { builds = ocaml_build @ unit_builds; launches = recipes; redact }
;;

let shell_line ?(prefix = "") (command : command) =
  let in_dir =
    match command.cwd with
    | "" | "." -> ""
    | cwd -> "cd " ^ Filename.quote cwd ^ " && "
  in
  prefix ^ in_dir ^ String.concat " " (List.map Filename.quote command.argv)
;;

let opam_env_prefix = "eval $(opam env 2>/dev/null) 2>/dev/null; "
let build_line command = shell_line ~prefix:opam_env_prefix command
let launch_line command = shell_line command

type child =
  { child_label : string
  ; child_pid : int
  }

type child_failure =
  | Spawn_failed of
      { label : string
      ; message : string
      }
  | Exited of
      { label : string
      ; code : int
      }
  | Signaled of
      { label : string
      ; signal : int
      }
  | Interrupted of int

let child_failure_to_string = function
  | Spawn_failed { label; message } ->
    Printf.sprintf "could not start %s: %s" label message
  | Exited { label; code } -> Printf.sprintf "%s exited with code %d" label code
  | Signaled { label; signal } -> Printf.sprintf "%s was signalled (%d)" label signal
  | Interrupted signal -> Printf.sprintf "interrupted by signal %d" signal
;;

let interrupt_exit_code signal =
  if signal = Sys.sigint then 130 else if signal = Sys.sigterm then 143 else 1
;;

let launch ~output (recipe : recipe) =
  match
    Sol_cli_process.spawn_detached
      ~output
      (Sol_cli_process.cmd
         ~cwd:recipe.launch.cwd
         ~env:recipe.env
         ~inherit_env:false
         recipe.launch.argv)
  with
  | Ok background ->
    Ok { child_label = recipe.label; child_pid = Sol_cli_process.pid background }
  | Error (Sol_cli_process.Spawn_failed message) ->
    Error (Spawn_failed { label = recipe.label; message })
  | Error error ->
    Error
      (Spawn_failed
         { label = recipe.label; message = Sol_cli_process.error_to_string error })
;;

let child_is_running pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> true
  | _, _ -> false
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> true
  | exception Unix.Unix_error _ -> false
;;

let terminate children =
  List.iter
    (fun child ->
       try Unix.kill (-child.child_pid) Sys.sigterm with
       | Unix.Unix_error _ -> ())
    children;
  let deadline = Unix.gettimeofday () +. 2.0 in
  let rec wait () =
    let running = List.filter (fun child -> child_is_running child.child_pid) children in
    if running = [] || Unix.gettimeofday () >= deadline
    then running
    else (
      Unix.sleepf 0.05;
      wait ())
  in
  let stubborn = wait () in
  List.iter
    (fun child ->
       try Unix.kill (-child.child_pid) Sys.sigkill with
       | Unix.Unix_error _ -> ())
    stubborn;
  List.iter
    (fun child ->
       try ignore (Unix.waitpid [] child.child_pid) with
       | Unix.Unix_error _ -> ())
    stubborn
;;

let launch_all ~output recipes =
  let rec go launched = function
    | [] -> Ok (List.rev launched)
    | recipe :: rest ->
      (match launch ~output:(output recipe) recipe with
       | Ok child -> go (child :: launched) rest
       | Error failure ->
         terminate launched;
         Error failure)
  in
  go [] recipes
;;

let invoke_with_stdin ~input_path (recipe : recipe) =
  let input_fd =
    try Ok (Unix.openfile input_path [ Unix.O_RDONLY ] 0) with
    | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  match input_fd with
  | Error message -> Error (Spawn_failed { label = recipe.label; message })
  | Ok input_fd ->
    let close_input () =
      try Unix.close input_fd with
      | Unix.Unix_error _ -> ()
    in
    (match recipe.launch.argv with
     | [] ->
       close_input ();
       Error (Spawn_failed { label = recipe.label; message = "empty invocation argv" })
     | argv ->
       let program = Sol_cli_process.resolve_program (List.hd argv) in
       let env =
         recipe.env |> List.map (fun (key, value) -> key ^ "=" ^ value) |> Array.of_list
       in
       let run_child () =
         (try
            (match recipe.launch.cwd with
             | "" | "." -> ()
             | cwd -> Unix.chdir cwd);
            Unix.dup2 input_fd Unix.stdin;
            Unix.execve program (Array.of_list argv) env
          with
          | Unix.Unix_error (error, _, _) ->
            Sol_cli_report.err
              "sol local invoke: %s: %s"
              program
              (Unix.error_message error)
          | _ -> ());
         Unix._exit 127
       in
       (match
          try Ok (Unix.fork ()) with
          | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
        with
        | Error message ->
          close_input ();
          Error (Spawn_failed { label = recipe.label; message })
        | Ok 0 -> run_child ()
        | Ok pid ->
          close_input ();
          let rec wait () =
            match Unix.waitpid [] pid with
            | _, status -> status
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
          in
          let status = wait () in
          (match status with
           | Unix.WEXITED code -> Ok code
           | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
             Error (Signaled { label = recipe.label; signal }))))
;;

let invoke ~event (recipe : recipe) =
  match event with
  | None -> invoke_with_stdin ~input_path:"/dev/null" recipe
  | Some bytes ->
    (match
       Sol_cli_fs.with_temp_file
         ~prefix:"sol-local-invoke-"
         ~suffix:".event"
         bytes
         (fun path -> invoke_with_stdin ~input_path:path recipe)
     with
     | Ok result -> result
     | Error message -> Error (Spawn_failed { label = recipe.label; message }))
;;

let reap_owned children =
  let rec go = function
    | [] -> None
    | child :: rest ->
      (match Unix.waitpid [ Unix.WNOHANG ] child.child_pid with
       | 0, _ -> go rest
       | _, status -> Some (child, status)
       | exception Unix.Unix_error (Unix.EINTR, _, _) -> None
       | exception Unix.Unix_error _ -> go rest)
  in
  go children
;;

let supervise ?(on_status = fun _ _ -> ()) children =
  if children = []
  then Ok ()
  else (
    let interrupted = ref None in
    let handler signal = interrupted := Some signal in
    let previous_int = Sys.signal Sys.sigint (Sys.Signal_handle handler) in
    let previous_term = Sys.signal Sys.sigterm (Sys.Signal_handle handler) in
    let restore () =
      Sys.set_signal Sys.sigint previous_int;
      Sys.set_signal Sys.sigterm previous_term
    in
    let pending = ref children in
    let stop_rest () =
      terminate !pending;
      pending := []
    in
    let rec loop () =
      match !interrupted with
      | Some signal ->
        stop_rest ();
        Error (Interrupted signal)
      | None ->
        (match reap_owned !pending with
         | None ->
           (try Unix.sleepf 0.05 with
            | Unix.Unix_error (Unix.EINTR, _, _) -> ());
           loop ()
         | Some (child, status) ->
           pending := List.filter (fun c -> c.child_pid <> child.child_pid) !pending;
           on_status child status;
           (match status with
            | Unix.WEXITED 0 -> if !pending = [] then Ok () else loop ()
            | Unix.WEXITED code ->
              stop_rest ();
              Error (Exited { label = child.child_label; code })
            | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
              stop_rest ();
              Error (Signaled { label = child.child_label; signal })))
    in
    let result =
      try loop () with
      | error ->
        restore ();
        raise error
    in
    restore ();
    result)
;;
