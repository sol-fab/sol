open Cmdliner

let norm = Sol_cli_scaffold.normalize
let cap = Sol_cli_scaffold.capitalize_name

module Tree = Sol_cli_scaffold_tree
module Assets = Sol_cli_platform_assets
open Result.Syntax

let always_write _ = Tree.Write

let template_root () =
  let* assets =
    Assets.resolve () |> Result.map_error (fun error -> Assets.error_to_string error)
  in
  Ok (Assets.templates_root assets)
;;

let copy ~kind ~dest ~vars ~rule =
  let* root = template_root () in
  Tree.copy ~root ~kind ~dest ~vars ~rule
;;

let framework_revision () =
  let* assets =
    Assets.resolve () |> Result.map_error (fun error -> Assets.error_to_string error)
  in
  match Assets.revision assets with
  | Ok revision -> Ok revision
  | Error message ->
    (match Sol_cli_build_info.revision with
     | Some revision when Assets.is_revision revision -> Ok revision
     | Some _ | None ->
       Error
         (message
          ^ "\n\
             Refusing to generate a workspace that pins a moving or missing ref. \
             Generate the workspace from a release bundle, or build sol from a git \
             checkout."))
;;

let workspace_vars ~revision ~name rel =
  let v =
    [ "name", name
    ; "Name", cap name
    ; "basename", Filename.basename name
    ; "revision", revision
    ]
  in
  match rel with
  | "app/payments/charge_svc/Dockerfile" ->
    ("repo_dir", "app/payments/charge_svc") :: ("binary", name ^ "-charge-svc") :: v
  | "app/comms/notify_worker/Dockerfile" ->
    ("repo_dir", "app/comms/notify_worker") :: ("binary", name ^ "-notify-worker") :: v
  | _ -> v
;;

let new_workspace name =
  let raw_name = name in
  let name = norm name in
  let* () =
    if Sys.file_exists name
    then Error (Printf.sprintf "%S already exists" name)
    else Ok ()
  in
  let* revision = framework_revision () in
  Sol_cli_report.app "\nScaffolding workspace %S ...\n" name;
  if name <> raw_name
  then (
    let k8s_name = String.map (fun c -> if c = '_' then '-' else c) name in
    Sol_cli_report.app
      "note: %S is not a valid OCaml/SQL identifier, so it is normalized to %S\n\
       (lowercased, '-' -> '_'). Kubernetes namespaces use the hyphenated form\n\
       again, e.g. %s-payments.\n"
      raw_name
      name
      k8s_name);
  let* written =
    copy
      ~kind:"workspace"
      ~dest:name
      ~vars:(workspace_vars ~revision ~name)
      ~rule:always_write
  in
  Sol_cli_report.app
    {|
Done. %d files generated.

  cd %s
  eval $(opam env) && dune build   # verify the scaffold compiles
  sol local deploy     # establish local cluster + infra, build images, deploy (first time ~5 min)
  sol migrate                          # apply DB migrations

  The workspace README.md documents the layout, the framework dependency and
  what the generated Dockerfiles do.

  Framework dependency: this workspace pins the Sol framework packages in
  %s.opam to revision %s, the revision this sol was built from. `opam install
  . --deps-only` fetches that exact commit, so the build is reproducible and no
  Sol checkout is required. To test uncommitted framework changes, install the
  framework from a Sol checkout with:

    bash platform/local/scripts/prepare-framework-deps.sh

  That replaces the package in your local switch; it does not change the
  workspace pin.

  CI/CD: set REGISTRY + REGISTRY_USER + REGISTRY_PASSWORD secrets in GitHub, then
         push to main — .github/workflows/sol-ci.yml handles build/test/deploy.
         sol/environments.yml declares a placeholder prod/aws/us-east-1 target —
         rename it to your real <env> and <provider>/<region>, and set the
         SOL_TARGET repository variable to match, before your first 'sol deploy'.|}
    (List.length written)
    name
    name
    revision;
  Ok ()
;;

let parse_domain_name arg =
  match String.split_on_char '/' arg with
  | [ domain; name ] when domain <> "" && name <> "" -> Ok (norm domain, norm name)
  | _ -> Error (Printf.sprintf "expected domain/name (e.g. payments/charge), got %S" arg)
;;

let ws_of_cwd () = norm (Filename.basename (Sys.getcwd ()))

type component_kind =
  | Service
  | Worker
  | Function

let component_suffix = function
  | Service -> "svc"
  | Worker -> "worker"
  | Function -> "fn"
;;

let component_module kind name =
  match kind with
  | Service -> "Handler"
  | Worker -> cap name ^ "_worker"
  | Function -> cap name ^ "_fn"
;;

let component_vars kind ~ws ~domain ~name =
  let suffix = component_suffix kind in
  let dir = Printf.sprintf "app/%s/%s_%s" domain name suffix in
  let lib = Printf.sprintf "%s_%s_%s_%s" ws domain name suffix in
  [ "lib", lib
  ; "dir", dir
  ; "repo_dir", dir
  ; "name", name
  ; "domain", domain
  ; "Mod", component_module kind name
  ; "binary", name ^ "-" ^ suffix
  ; "basename", Filename.basename ws
  ]
;;

let template_kind suffix = function
  | Sol_cli_compat.Ocaml -> suffix
  | Sol_cli_compat.Typescript -> suffix ^ "-ts"
;;

let new_component kind ?(language = Sol_cli_compat.Ocaml) ~label arg =
  let ws = ws_of_cwd () in
  let* domain, name = parse_domain_name arg in
  let suffix = component_suffix kind in
  let dir = Printf.sprintf "app/%s/%s_%s" domain name suffix in
  let* root =
    Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ())
    |> Result.map_error Sol_cli_workspace.workspace_error_to_string
  in
  let unit_name = Filename.basename dir in
  let lang = Sol_cli_compat.to_string language in
  let* declaration = Sol_cli_sol_yml.plan ~root ~name:unit_name ~dir ~language in
  Sol_cli_report.app "\nScaffolding %s %s/%s_%s (%s) ...\n" label domain name suffix lang;
  let vars = component_vars kind ~ws ~domain ~name in
  let* _ =
    copy
      ~kind:(template_kind suffix language)
      ~dest:dir
      ~vars:(fun _ -> vars)
      ~rule:always_write
  in
  let* outcome = Sol_cli_sol_yml.commit declaration in
  (match outcome with
   | Sol_cli_sol_yml.Declared ->
     Sol_cli_report.app "  sol.yml: added %s, declared language: %s" unit_name lang
   | Sol_cli_sol_yml.Language_added ->
     Sol_cli_report.app "  sol.yml: declared language: %s for %s" lang unit_name
   | Sol_cli_sol_yml.Already_declared ->
     Sol_cli_report.app "  sol.yml: %s already declares language: %s" unit_name lang);
  Ok dir
;;

let new_svc ?language arg =
  let* dir = new_component Service ?language ~label:"svc" arg in
  (match Option.value ~default:Sol_cli_compat.Ocaml language with
   | Sol_cli_compat.Ocaml ->
     Sol_cli_report.app "\nDone.  Build: dune build %s/bin/main.exe" dir
   | Sol_cli_compat.Typescript ->
     Sol_cli_report.app
       "\nDone.  Install and build:\n  cd %s && npm install && npm run build"
       dir);
  Ok ()
;;

let new_worker ?language arg =
  let* dir = new_component Worker ?language ~label:"worker" arg in
  (match Option.value ~default:Sol_cli_compat.Ocaml language with
   | Sol_cli_compat.Ocaml ->
     Sol_cli_report.app
       "\nDone.  Replace the stub Message module with your event module, then:";
     Sol_cli_report.app "  dune build %s/bin/main.exe" dir
   | Sol_cli_compat.Typescript ->
     Sol_cli_report.app
       "\nDone.  Install and build:\n  cd %s && npm install && npm run build"
       dir);
  Ok ()
;;

let new_fn ?language arg =
  match Option.value ~default:Sol_cli_compat.Ocaml language with
  | Sol_cli_compat.Typescript ->
    Error
      "TypeScript -fn is not supported yet: Sol has no TypeScript function runtime \
       contract. Use --language ocaml, or track the -fn capability in \
       internal/specs/framework-conventions.md."
  | Sol_cli_compat.Ocaml ->
    let* dir = new_component Function ~label:"fn" arg in
    Sol_cli_report.app "\nDone.  Build: dune build %s/bin/main.exe" dir;
    Ok ()
;;

let event_vars ~ws ~team ~name =
  [ "team", team
  ; "name", name
  ; "Mod", cap name
  ; "Team", cap team
  ; "lib", ws ^ "_" ^ team ^ "_events"
  ]
;;

let event_rule module_ = function
  | "events/{{team}}/dune" -> Tree.Patch_modules module_
  | "events/{{team}}/sol.toml" -> Tree.Skip_if_exists
  | _ -> Tree.Write
;;

let events_section content =
  match Sol_cli_string.after_opt ~needle:"[[events]]" content with
  | Some rest -> "[[events]]" ^ rest
  | None -> content
;;

let append_event_declaration ~team ~vars =
  let* root = template_root () in
  let rel = "events/{{team}}/sol.toml" in
  let* content = Tree.text ~root ~kind:"event" ~rel in
  let manifest = Printf.sprintf "events/%s/sol.toml" team in
  match Sol_cli_fs.read_file manifest with
  | Error error -> Error error
  | Ok existing ->
    Sol_cli_fs.write_atomic
      manifest
      (existing ^ "\n" ^ events_section (Sol_cli_scaffold.subst vars content))
;;

let new_event arg =
  let ws = ws_of_cwd () in
  let* team, name = parse_domain_name arg in
  let file = Printf.sprintf "events/%s/%s.ml" team name in
  let manifest = Printf.sprintf "events/%s/sol.toml" team in
  let lib = ws ^ "_" ^ team ^ "_events" in
  Sol_cli_report.app "\nScaffolding event %s/%s ...\n" team name;
  let* () =
    if Sys.file_exists file
    then Error (Printf.sprintf "%S already exists" file)
    else Ok ()
  in
  let vars = event_vars ~ws ~team ~name in
  let manifest_existed = Sys.file_exists manifest in
  let* _ =
    copy ~kind:"event" ~dest:"." ~vars:(fun _ -> vars) ~rule:(event_rule (cap name))
  in
  let* () = if manifest_existed then append_event_declaration ~team ~vars else Ok () in
  let* generated = Sol_cli_contract_gen.generate ~root:"." ~check:false in
  List.iter (fun path -> Sol_cli_report.app "  generated  %s" path) generated;
  Sol_cli_report.app "\nDone.  Consumers add (libraries %s) to their dune files." lib;
  Ok ()
;;

let run scaffold arg = Sol_cli_exit.exit_on (scaffold arg |> Sol_cli_exit.of_msg)

let run_with_language scaffold language arg =
  Sol_cli_exit.exit_on (scaffold language arg |> Sol_cli_exit.of_msg)
;;

let language_conv =
  let parse s =
    match Sol_cli_compat.of_string s with
    | Ok language -> Ok language
    | Error message -> Error (`Msg message)
  in
  let print fmt language =
    Format.pp_print_string fmt (Sol_cli_compat.to_string language)
  in
  Arg.conv (parse, print)
;;

let language_arg =
  Arg.(
    value
    & opt language_conv Sol_cli_compat.Ocaml
    & info
        [ "language" ]
        ~docv:"LANGUAGE"
        ~doc:"Implementation language for the unit: ocaml (default) or typescript")
;;

let name_arg docv doc =
  Arg.(required & pos 0 (some Sol_cli_args.text) None & info [] ~docv ~doc)
;;

let workspace_cmd =
  Cmd.v
    (Cmd.info
       "workspace"
       ~doc:"Scaffold a new Sol workspace with a working two-service example")
    Term.(const (run new_workspace) $ name_arg "NAME" "Workspace name, e.g. acme")
;;

let svc_cmd =
  Cmd.v
    (Cmd.info "svc" ~doc:"Add an HTTP service to the current workspace")
    Term.(
      const (run_with_language (fun language arg -> new_svc ~language arg))
      $ language_arg
      $ name_arg "DOMAIN/NAME" "e.g. payments/charge")
;;

let worker_cmd =
  Cmd.v
    (Cmd.info "worker" ~doc:"Add a Kafka consumer worker to the current workspace")
    Term.(
      const (run_with_language (fun language arg -> new_worker ~language arg))
      $ language_arg
      $ name_arg "DOMAIN/NAME" "e.g. comms/notify")
;;

let fn_cmd =
  Cmd.v
    (Cmd.info "fn" ~doc:"Add a scheduled function to the current workspace")
    Term.(
      const (run_with_language (fun language arg -> new_fn ~language arg))
      $ language_arg
      $ name_arg "DOMAIN/NAME" "e.g. billing/monthly_report")
;;

let event_cmd =
  Cmd.v
    (Cmd.info "event" ~doc:"Add a typed Kafka event contract to the current workspace")
    Term.(const (run new_event) $ name_arg "TEAM/NAME" "e.g. payments/charged")
;;

let cmd =
  Cmd.group
    (Cmd.info "new" ~doc:"Scaffold workspace components")
    [ workspace_cmd; svc_cmd; worker_cmd; fn_cmd; event_cmd ]
;;
