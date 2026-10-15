type form =
  | Checkout
  | Installed of { version : string }

type t =
  { dir : string
  ; form : form
  }

type error =
  | Invalid_sol_home of string
  | Bundle_version_mismatch of
      { dir : string
      ; bundle : string
      ; binary : string option
      }
  | Missing_bundle of
      { expected : string
      ; version : string
      }
  | Not_found

let fix =
  "  Set SOL_HOME to a Sol checkout or to this release's bundle and re-run:\n\
  \    export SOL_HOME=/path/to/sol"
;;

let error_to_string = function
  | Invalid_sol_home dir ->
    Printf.sprintf
      "SOL_HOME=%s is neither a Sol checkout (framework/ocaml/sol-svc/lib/dune and \
       framework/ocaml/kafka-eio-service/lib/dune, outside any _build tree) nor a \
       release bundle (a VERSION file and platform/).\n\
       %s"
      dir
      fix
  | Bundle_version_mismatch { dir; bundle; binary } ->
    Printf.sprintf
      "SOL_HOME=%s is the bundle of release %s, but this sol is %s; a release uses only \
       its own assets.\n\
       %s"
      dir
      bundle
      (match binary with
       | Some v -> "release " ^ v
       | None -> "a development build")
      fix
  | Missing_bundle { expected; version } ->
    Printf.sprintf
      "this is sol release %s, but its assets are not at %s. Reinstall the release \
       archive so bin/sol and share/sol/%s/ sit under one prefix, or set SOL_HOME to \
       that bundle."
      version
      expected
      version
  | Not_found ->
    Printf.sprintf
      "cannot locate Sol's platform assets: no Sol checkout above this binary.\n%s"
      fix
;;

let inside_build_context dir = String.split_on_char '/' dir |> List.mem "_build"

let is_checkout dir =
  (not (inside_build_context dir))
  && Sys.file_exists (Filename.concat dir "framework/ocaml/sol-svc/lib/dune")
  && Sys.file_exists (Filename.concat dir "framework/ocaml/kafka-eio-service/lib/dune")
;;

let rec realpath path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
  in
  try
    let target = Unix.readlink path in
    let target =
      if Filename.is_relative target
      then Filename.concat (Filename.dirname path) target
      else target
    in
    realpath target
  with
  | Unix.Unix_error ((Unix.EINVAL | Unix.ENOENT), _, _) -> path
;;

let rec find_ancestor pred dir =
  if pred dir
  then Some dir
  else (
    let parent = Filename.dirname dir in
    if parent = dir then None else find_ancestor pred parent)
;;

let running_binary_dir () =
  let exe =
    try Unix.readlink "/proc/self/exe" with
    | Unix.Unix_error _ -> Sys.executable_name
  in
  Filename.dirname (realpath exe)
;;

let first_line path =
  match open_in path with
  | exception Sys_error _ -> None
  | ic ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         match String.trim (input_line ic) with
         | "" -> None
         | line -> Some line
         | exception End_of_file -> None)
;;

let bundle_version dir =
  if Sys.file_exists (Filename.concat dir "platform/shared/components.json")
  then first_line (Filename.concat dir "VERSION")
  else None
;;

let installed_dir ~exe_dir ~version =
  Filename.concat (Filename.dirname exe_dir) (Filename.concat "share/sol" version)
;;

let resolve_from ~sol_home ~exe_dir ~release_version =
  match sol_home with
  | Some dir ->
    if is_checkout dir
    then Ok { dir; form = Checkout }
    else (
      match bundle_version dir with
      | Some bundle when Some bundle = release_version ->
        Ok { dir; form = Installed { version = bundle } }
      | Some bundle ->
        Error (Bundle_version_mismatch { dir; bundle; binary = release_version })
      | None -> Error (Invalid_sol_home dir))
  | None ->
    (match release_version with
     | Some version ->
       let dir = installed_dir ~exe_dir ~version in
       (match bundle_version dir with
        | Some bundle when bundle = version -> Ok { dir; form = Installed { version } }
        | Some _ | None -> Error (Missing_bundle { expected = dir; version }))
     | None ->
       (match find_ancestor is_checkout exe_dir with
        | Some dir -> Ok { dir; form = Checkout }
        | None -> Error Not_found))
;;

let resolve () =
  resolve_from
    ~sol_home:(Sol_cli_string.env "SOL_HOME")
    ~exe_dir:(running_binary_dir ())
    ~release_version:Sol_cli_build_info.release_version
;;

let dir t = t.dir
let form t = t.form

type cloud_role =
  | Bootstrap
  | Cluster
  | Platform
  | Authorization

let cloud_root_rel provider role =
  Printf.sprintf
    "platform/cloud/%s/%s"
    (Sol_cli_provider.to_string provider)
    (match role with
     | Bootstrap -> "bootstrap"
     | Cluster -> "cluster"
     | Platform -> "platform"
     | Authorization -> "authorization")
;;

let under t rel = Filename.concat t.dir rel
let cloud_root t provider role = under t (cloud_root_rel provider role)
let terraform_trees = [ "platform/cloud"; "platform/shared" ]
let components_json t = under t "platform/shared/components.json"
let templates_root t = under t "platform/shared/templates"

let dashboard t name =
  under t (Filename.concat "platform/shared/observability/dashboards" name)
;;

let alloy_template t = under t "platform/shared/observability/alloy/logs.alloy.tftpl"
let runner_image_file t = Filename.concat t.dir "migration-runner-image"
let runner_image_env = "SOL_MIGRATION_RUNNER_IMAGE"
let setup_image_file t = Filename.concat t.dir "setup-image"
let setup_image_env = "SOL_SETUP_POSTGRES_IMAGE"

let is_digest_ref s =
  match String.index_opt s '@' with
  | Some i ->
    let d = String.sub s (i + 1) (String.length s - i - 1) in
    String.length d = 71
    && String.sub d 0 7 = "sha256:"
    && String.for_all
         (function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false)
         (String.sub d 7 64)
  | None -> false
;;

let not_a_digest_ref ~what ~reason ref_ =
  Printf.sprintf
    "%s %S is not a digest reference (<image>@sha256:<64 hex>); %s"
    what
    ref_
    reason
;;

let published_image_of_bundle ~what ~version ~file ~reason =
  match first_line file with
  | None ->
    Error
      (Printf.sprintf
         "release %s's bundle has no %s reference in %s; reinstall the release archive \
          so the published %s is recorded beside its platform assets"
         version
         what
         file
         what)
  | Some ref_ when is_digest_ref ref_ -> Ok ref_
  | Some ref_ ->
    Error
      (not_a_digest_ref
         ~what:(Printf.sprintf "release %s's %s" version what)
         ~reason
         ref_)
;;

(** **Where an image reference a release bundles comes from, and what counts as pinnable.**
    Source selection, override refusal and digest validation are identical for every such
    image, so they live here once; each accessor supplies its own file, variable and guidance
    — the runner is Sol-built and must be published from a checkout, while the setup image is
    public and only needs a digest pinned, so their instructions must not converge.

    [what] names the image in messages, [reason] completes "it is not a digest reference,
    because…", [on_checkout] is the advice for a source checkout, and [on_installed] the
    advice for a release when the variable is set. [on_checkout] receives the variable
    name. *)
let resolve_image t ~file ~env_var ~what ~checkout_what ~reason ~on_checkout ~on_installed
  =
  let explicit = Sol_cli_string.env env_var in
  match t.form, explicit with
  | Checkout, Some ref_ when is_digest_ref ref_ -> Ok ref_
  | Checkout, Some ref_ -> Error (not_a_digest_ref ~what:env_var ~reason ref_)
  | Checkout, None ->
    Error
      (Printf.sprintf
         "no %s is available: this is a Sol source checkout, and %s"
         checkout_what
         (on_checkout env_var))
  | Installed { version }, Some _ ->
    Error
      (Printf.sprintf
         "%s is set, but this is Sol release %s, whose bundle pins its own %s; a release \
          uses only its own assets. %s"
         env_var
         version
         what
         on_installed)
  | Installed { version }, None -> published_image_of_bundle ~what ~version ~file ~reason
;;

let migration_runner_image t =
  resolve_image
    t
    ~file:(runner_image_file t)
    ~env_var:runner_image_env
    ~what:"migration runner"
    ~checkout_what:"pre-built migration runner"
    ~reason:"the migration runner is pinned by digest, and a tag can move"
    ~on_checkout:(fun env_var ->
      Printf.sprintf
        "Sol does not build or publish the runner (the deploy identity has no \
         registry-write authority, ADR 0002). Publish it from Sol's own recipe \
         (internal/tooling/release/migration-runner.Dockerfile) and set %s to the pushed \
         digest reference, or run from an installed Sol release, whose bundle already \
         pins its runner"
        env_var)
    ~on_installed:"Unset it (the release's runner is already resolved) to continue"
;;

(** The database setup image. Like the runner it is resolved from the installed release's own
    bundle, but unlike the runner it is **public**: there is nothing to publish, only a digest
    to pin, and the guidance says so rather than telling the operator to publish something that
    does not belong to Sol. *)
let setup_image t =
  resolve_image
    t
    ~file:(setup_image_file t)
    ~env_var:setup_image_env
    ~what:"database setup image"
    ~checkout_what:"database setup image"
    ~reason:
      "this Job runs with the database's administrative credential, so an image \
       reference that can move is not acceptable"
    ~on_checkout:(fun env_var ->
      Printf.sprintf
        "there is nothing to publish, only a digest to pin. Set %s to an image pinned by \
         digest, for example postgres@sha256:<64 hex> - `docker buildx imagetools \
         inspect postgres:16` prints the current digest (the plain `docker manifest \
         inspect` form prints the manifest JSON without a digest line), or run from an \
         installed Sol release, whose bundle already pins its setup image"
        env_var)
    ~on_installed:"Unset it (the release's setup image is already resolved) to continue"
;;
