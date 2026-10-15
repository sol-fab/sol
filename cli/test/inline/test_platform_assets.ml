module A = Sol_cli_platform_assets

let mkdir_p path = Result.get_ok (Sol_cli_fs.mkdir_p path)

let touch path =
  mkdir_p (Filename.dirname path);
  close_out (open_out path)
;;

let with_tmpdir f =
  let dir = Filename.temp_file "sol-assets-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree dir))
    (fun () -> f (Unix.realpath dir))
;;

let with_sol_home value f =
  let saved = Sys.getenv_opt "SOL_HOME" in
  Unix.putenv "SOL_HOME" value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv "SOL_HOME" (Option.value saved ~default:""))
    f
;;

let with_runner_ref value f =
  let saved = Sys.getenv_opt A.runner_image_env in
  Unix.putenv A.runner_image_env value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv A.runner_image_env (Option.value saved ~default:""))
    f
;;

let fake_checkout dir =
  touch (Filename.concat dir "framework/ocaml/sol-svc/lib/dune");
  touch (Filename.concat dir "framework/ocaml/kafka-eio-service/lib/dune")
;;

let resolved_dir () = Result.map A.dir (A.resolve ())

let test_sol_home_wins_over_discovery () =
  with_tmpdir (fun dir ->
    fake_checkout dir;
    with_sol_home dir (fun () ->
      match resolved_dir () with
      | Ok got -> Windtrap.equal Windtrap.string ~msg:"SOL_HOME is the root" dir got
      | Error e -> Windtrap.fail (A.error_to_string e)))
;;

let test_invalid_sol_home_is_an_error () =
  with_tmpdir (fun dir ->
    with_sol_home dir (fun () ->
      match A.resolve () with
      | Ok t -> Windtrap.fail ("fell through to " ^ A.dir t)
      | Error (A.Invalid_sol_home got) ->
        Windtrap.equal Windtrap.string ~msg:"names the bad value" dir got;
        let msg = A.error_to_string (A.Invalid_sol_home got) in
        Windtrap.equal
          Windtrap.bool
          ~msg:("says how to fix it: " ^ msg)
          true
          (Sol_cli_string.contains ~needle:"export SOL_HOME" msg)
      | Error e -> Windtrap.fail ("expected Invalid_sol_home: " ^ A.error_to_string e)))
;;

let test_unset_discovers_the_checkout () =
  with_sol_home "" (fun () ->
    match A.resolve () with
    | Error e -> Windtrap.fail (A.error_to_string e)
    | Ok t ->
      Windtrap.equal Windtrap.bool ~msg:"a checkout" true (A.is_checkout (A.dir t));
      Windtrap.equal
        Windtrap.bool
        ~msg:"its components.json exists"
        true
        (Sys.file_exists (A.components_json t)))
;;

let test_build_tree_is_not_a_checkout () =
  with_tmpdir (fun dir ->
    let mirrored = Filename.concat dir "_build/default" in
    fake_checkout mirrored;
    Windtrap.equal Windtrap.bool ~msg:"rejected" false (A.is_checkout mirrored))
;;

let test_asset_paths () =
  with_tmpdir (fun dir ->
    fake_checkout dir;
    with_sol_home dir (fun () ->
      let t = A.resolve () |> Result.get_ok in
      Windtrap.equal
        Windtrap.string
        ~msg:"cluster root"
        (dir ^ "/platform/cloud/gcp/cluster")
        (A.cloud_root t Sol_cli_provider.Gcp A.Cluster);
      Windtrap.equal
        Windtrap.string
        ~msg:"authorization root"
        (dir ^ "/platform/cloud/aws/authorization")
        (A.cloud_root t Sol_cli_provider.Aws A.Authorization);
      Windtrap.equal
        Windtrap.string
        ~msg:"components"
        (dir ^ "/platform/shared/components.json")
        (A.components_json t);
      Windtrap.equal
        Windtrap.string
        ~msg:"dashboard"
        (dir ^ "/platform/shared/observability/dashboards/x.json")
        (A.dashboard t "x.json");
      with_runner_ref "" (fun () ->
        match A.migration_runner_image t with
        | Ok image ->
          Windtrap.fail
            ("a checkout resolved a runner without an explicit reference: " ^ image)
        | Error msg ->
          Windtrap.equal
            Windtrap.bool
            ~msg:"a checkout without a reference names the variable"
            true
            (Sol_cli_string.contains ~needle:A.runner_image_env msg))))
;;

let write path text =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc text;
  close_out oc
;;

let fake_install prefix ~version =
  mkdir_p (Filename.concat prefix "bin");
  let bundle = Filename.concat prefix ("share/sol/" ^ version) in
  write (Filename.concat bundle "VERSION") (version ^ "\n");
  write (Filename.concat bundle "platform/shared/components.json") "{}\n";
  bundle
;;

let digest = "ghcr.io/o/sol-migration-runner@sha256:" ^ String.make 64 'a'

let form_name = function
  | Ok t ->
    (match A.form t with
     | A.Checkout -> "checkout:" ^ A.dir t
     | A.Installed { version } -> "installed:" ^ version ^ ":" ^ A.dir t)
  | Error (A.Invalid_sol_home _) -> "invalid-sol-home"
  | Error (A.Bundle_version_mismatch _) -> "bundle-version-mismatch"
  | Error (A.Missing_bundle _) -> "missing-bundle"
  | Error A.Not_found -> "not-found"
;;

let check_form name want got =
  Windtrap.equal Windtrap.string ~msg:name want (form_name got)
;;

let with_layout f =
  with_tmpdir (fun root ->
    fake_checkout root;
    let prefix = Filename.concat root "prefix" in
    let bundle = fake_install prefix ~version:"v1.2.3" in
    f ~root ~bin:(Filename.concat prefix "bin") ~bundle)
;;

let test_sol_home_beats_installed () =
  with_layout (fun ~root ~bin ~bundle:_ ->
    with_tmpdir (fun other ->
      fake_checkout other;
      check_form
        "SOL_HOME checkout over the installed bundle"
        ("checkout:" ^ other)
        (A.resolve_from
           ~sol_home:(Some other)
           ~exe_dir:bin
           ~release_version:(Some "v1.2.3")));
    ignore root)
;;

let test_installed_beats_discovery () =
  with_layout (fun ~root:_ ~bin ~bundle ->
    check_form
      "a release binary uses its bundle, not the checkout around it"
      ("installed:v1.2.3:" ^ bundle)
      (A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v1.2.3")))
;;

let test_release_never_discovers_a_checkout () =
  with_layout (fun ~root:_ ~bin ~bundle:_ ->
    check_form
      "a release whose bundle is absent refuses; it does not reach back"
      "missing-bundle"
      (A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v9.9.9")))
;;

let test_development_build_discovers () =
  with_layout (fun ~root ~bin ~bundle:_ ->
    check_form
      "a development build uses the checkout, never a bundle"
      ("checkout:" ^ root)
      (A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:None))
;;

let test_sol_home_bundle_must_match () =
  with_layout (fun ~root:_ ~bin ~bundle ->
    check_form
      "SOL_HOME naming this release's bundle"
      ("installed:v1.2.3:" ^ bundle)
      (A.resolve_from
         ~sol_home:(Some bundle)
         ~exe_dir:bin
         ~release_version:(Some "v1.2.3"));
    check_form
      "SOL_HOME naming another release's bundle"
      "bundle-version-mismatch"
      (A.resolve_from
         ~sol_home:(Some bundle)
         ~exe_dir:bin
         ~release_version:(Some "v2.0.0"));
    check_form
      "a development build pointed at a bundle"
      "bundle-version-mismatch"
      (A.resolve_from ~sol_home:(Some bundle) ~exe_dir:bin ~release_version:None))
;;

let test_invalid_sol_home_never_falls_through () =
  with_layout (fun ~root:_ ~bin ~bundle:_ ->
    with_tmpdir (fun empty ->
      check_form
        "invalid SOL_HOME with a valid bundle and checkout both available"
        "invalid-sol-home"
        (A.resolve_from
           ~sol_home:(Some empty)
           ~exe_dir:bin
           ~release_version:(Some "v1.2.3"))))
;;

let test_empty_sol_home_is_unset () =
  let saved = Sys.getenv_opt "SOL_HOME" in
  Unix.putenv "SOL_HOME" "";
  let read = Sol_cli_string.env "SOL_HOME" in
  Unix.putenv "SOL_HOME" (Option.value saved ~default:"");
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"SOL_HOME=\"\" reads as unset"
    None
    read;
  Unix.putenv "SOL_HOME" "  ";
  let read = Sol_cli_string.env "SOL_HOME" in
  Unix.putenv "SOL_HOME" (Option.value saved ~default:"");
  Windtrap.equal (Windtrap.option Windtrap.string) ~msg:"blank reads as unset" None read
;;

let installed_runner ~file =
  with_layout (fun ~root:_ ~bin ~bundle ->
    Option.iter (write (Filename.concat bundle "migration-runner-image")) file;
    match A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v1.2.3") with
    | Error e -> Error (A.error_to_string e)
    | Ok t -> A.migration_runner_image t)
;;

let test_installed_runner_is_published_by_digest () =
  with_runner_ref "" (fun () ->
    (match installed_runner ~file:(Some (digest ^ "\n")) with
     | Ok r -> Windtrap.equal Windtrap.string ~msg:"the bundle's digest" digest r
     | Error msg -> Windtrap.fail msg);
    (match installed_runner ~file:(Some "ghcr.io/o/sol-migration-runner:latest\n") with
     | Error _ -> ()
     | Ok _ -> Windtrap.fail "a floating tag was accepted as the runner");
    (match installed_runner ~file:None with
     | Error msg ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"a bundle without a runner reference says how to fix it"
         true
         (Sol_cli_string.contains ~needle:"reinstall the release archive" msg)
     | Ok _ -> Windtrap.fail "a bundle without a runner reference was accepted");
    match installed_runner ~file:(Some "") with
    | Error _ -> ()
    | Ok _ -> Windtrap.fail "an empty runner reference was accepted")
;;

let setup_digest = "postgres@sha256:" ^ String.make 64 'b'

let with_setup_ref value f =
  let saved = Sys.getenv_opt A.setup_image_env in
  Unix.putenv A.setup_image_env value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv A.setup_image_env (Option.value saved ~default:""))
    f
;;

let installed_setup ~file =
  with_layout (fun ~root:_ ~bin ~bundle ->
    Option.iter (write (Filename.concat bundle "setup-image")) file;
    match A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v1.2.3") with
    | Error e -> Error (A.error_to_string e)
    | Ok t -> A.setup_image t)
;;

(* The setup image follows the runner's rules: a release resolves its own bundled digest, and
   an explicit variable is refused rather than silently preferred. *)
let test_installed_setup_image_is_pinned_by_digest () =
  with_setup_ref "" (fun () ->
    (match installed_setup ~file:(Some (setup_digest ^ "\n")) with
     | Ok r -> Windtrap.equal Windtrap.string ~msg:"the bundle's digest" setup_digest r
     | Error msg -> Windtrap.fail msg);
    (match installed_setup ~file:(Some "postgres:16\n") with
     | Error _ -> ()
     | Ok _ -> Windtrap.fail "a floating tag was accepted as the setup image");
    (match installed_setup ~file:(Some "") with
     | Error _ -> ()
     | Ok _ -> Windtrap.fail "an empty setup reference was accepted");
    match installed_setup ~file:None with
    | Error msg ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"a bundle without a setup image says how to fix it"
        true
        (Sol_cli_string.contains ~needle:"reinstall the release archive" msg)
    | Ok _ -> Windtrap.fail "a bundle without a setup image was accepted")
;;

let test_a_release_refuses_an_explicit_setup_image () =
  with_layout (fun ~root:_ ~bin ~bundle ->
    write (Filename.concat bundle "setup-image") (setup_digest ^ "\n");
    with_setup_ref setup_digest (fun () ->
      match
        A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v1.2.3")
      with
      | Error e -> Windtrap.fail (A.error_to_string e)
      | Ok t ->
        (match A.setup_image t with
         | Error msg ->
           Windtrap.equal
             Windtrap.bool
             ~msg:"a release uses only its own assets"
             true
             (Sol_cli_string.contains ~needle:"uses only its own assets" msg)
         | Ok _ -> Windtrap.fail "a release accepted an explicit setup image")))
;;

(* A checkout has nothing to publish, so its guidance names the public image route and a digest
   lookup — not a Dockerfile of Sol's, which does not exist for this image. *)
let test_checkout_setup_image_guides_the_public_route () =
  with_layout (fun ~root ~bin:_ ~bundle:_ ->
    match A.resolve_from ~sol_home:(Some root) ~exe_dir:root ~release_version:None with
    | Error e -> Windtrap.fail (A.error_to_string e)
    | Ok t ->
      with_setup_ref setup_digest (fun () ->
        (match A.setup_image t with
         | Ok r ->
           Windtrap.equal
             Windtrap.string
             ~msg:"a checkout uses the variable"
             setup_digest
             r
         | Error msg -> Windtrap.fail msg);
        with_setup_ref "" (fun () ->
          match A.setup_image t with
          | Ok _ -> Windtrap.fail "a checkout with no reference must refuse"
          | Error msg ->
            Windtrap.equal
              Windtrap.bool
              ~msg:
                "the guidance names the public digest route, not a Sol artifact to \
                 publish"
              true
              (Sol_cli_string.contains ~needle:"imagetools inspect" msg
               && not (Sol_cli_string.contains ~needle:"Dockerfile" msg)))))
;;

let test_checkout_runner_needs_an_explicit_digest () =
  with_tmpdir (fun dir ->
    fake_checkout dir;
    with_sol_home dir (fun () ->
      let t = A.resolve () |> Result.get_ok in
      with_runner_ref digest (fun () ->
        match A.migration_runner_image t with
        | Ok image ->
          Windtrap.equal Windtrap.string ~msg:"the explicit digest" digest image
        | Error msg -> Windtrap.fail msg);
      with_runner_ref "ghcr.io/o/sol-migration-runner:latest" (fun () ->
        match A.migration_runner_image t with
        | Ok image -> Windtrap.fail ("a floating tag was accepted: " ^ image)
        | Error msg ->
          Windtrap.equal
            Windtrap.bool
            ~msg:"a tag is refused"
            true
            (Sol_cli_string.contains ~needle:"digest reference" msg));
      with_runner_ref "" (fun () ->
        match A.migration_runner_image t with
        | Ok image -> Windtrap.fail ("a checkout resolved a runner: " ^ image)
        | Error msg ->
          Windtrap.equal
            Windtrap.bool
            ~msg:"the refusal says Sol does not publish it"
            true
            (Sol_cli_string.contains ~needle:"does not build or publish the runner" msg))))
;;

let test_release_ignores_an_explicit_runner () =
  with_runner_ref digest (fun () ->
    match installed_runner ~file:(Some (digest ^ "\n")) with
    | Ok image -> Windtrap.fail ("a release accepted an override: " ^ image)
    | Error msg ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the release bundle stays authoritative"
        true
        (Sol_cli_string.contains ~needle:"a release uses only its own assets" msg))
;;

let test_empty_version_is_not_a_bundle () =
  with_layout (fun ~root:_ ~bin ~bundle ->
    write (Filename.concat bundle "VERSION") "";
    check_form
      "empty VERSION"
      "missing-bundle"
      (A.resolve_from ~sol_home:None ~exe_dir:bin ~release_version:(Some "v1.2.3"));
    check_form
      "empty VERSION via SOL_HOME"
      "invalid-sol-home"
      (A.resolve_from
         ~sol_home:(Some bundle)
         ~exe_dir:bin
         ~release_version:(Some "v1.2.3")))
;;

let%test "resolution: SOL_HOME wins over discovery" = test_sol_home_wins_over_discovery ()
let%test "resolution: invalid SOL_HOME is an error" = test_invalid_sol_home_is_an_error ()
let%test "resolution: unset discovers the checkout" = test_unset_discovers_the_checkout ()

let%test "resolution: a build tree is not a checkout" =
  test_build_tree_is_not_a_checkout ()
;;

let%test "resolution: asset paths" = test_asset_paths ()
let%test "precedence: SOL_HOME beats installed" = test_sol_home_beats_installed ()
let%test "precedence: installed beats discovery" = test_installed_beats_discovery ()

let%test "precedence: a release never discovers a checkout" =
  test_release_never_discovers_a_checkout ()
;;

let%test "precedence: a development build discovers" = test_development_build_discovers ()
let%test "precedence: a SOL_HOME bundle must match" = test_sol_home_bundle_must_match ()

let%test "precedence: invalid SOL_HOME never falls through" =
  test_invalid_sol_home_never_falls_through ()
;;

let%test "precedence: empty SOL_HOME is unset" = test_empty_sol_home_is_unset ()

let%test "precedence: installed runner is published by digest" =
  test_installed_runner_is_published_by_digest ()
;;

let%test "runner: a checkout needs an explicit, digest-pinned reference" =
  test_checkout_runner_needs_an_explicit_digest ()
;;

let%test "runner: a release bundle ignores an explicit reference" =
  test_release_ignores_an_explicit_runner ()
;;

let%test "precedence: empty VERSION is not a bundle" =
  test_empty_version_is_not_a_bundle ()
;;

let%test "assets: an installed release pins its own setup image" =
  test_installed_setup_image_is_pinned_by_digest ()
;;

let%test "assets: a release refuses an explicit setup image" =
  test_a_release_refuses_an_explicit_setup_image ()
;;

let%test "assets: a checkout's setup guidance names the public route" =
  test_checkout_setup_image_guides_the_public_route ()
;;

let%test "assets: digest references require a valid image name" =
  let suffix = "@sha256:" ^ String.make 64 'a' in
  let accepts reference =
    with_layout (fun ~root ~bin:_ ~bundle:_ ->
      match A.resolve_from ~sol_home:(Some root) ~exe_dir:root ~release_version:None with
      | Error error -> Windtrap.fail (A.error_to_string error)
      | Ok assets ->
        with_setup_ref reference (fun () -> Result.is_ok (A.setup_image assets)))
  in
  List.iter
    (fun name ->
       Windtrap.equal
         Windtrap.bool
         ~msg:("invalid image: " ^ name)
         false
         (accepts (name ^ suffix)))
    [ ""
    ; "/postgres"
    ; "postgres/"
    ; "a//b"
    ; "Postgres"
    ; "a b"
    ; "https://host/repo"
    ; "repo!"
    ; "a..b"
    ; "repo:"
    ; "repo\n"
    ; "repo:" ^ String.make 129 'a'
    ; String.make 256 'a'
    ];
  List.iter
    (fun name ->
       Windtrap.equal
         Windtrap.bool
         ~msg:("valid image: " ^ name)
         true
         (accepts (name ^ suffix)))
    [ "postgres"
    ; "postgres:16"
    ; "ghcr.io/sol-fab/runner"
    ; "localhost:5000/a/b"
    ; "[::1]:5000/repo"
    ; "a__b/c--d"
    ]
;;
