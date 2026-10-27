let passed = ref 0
let failed = ref 0

let check name condition =
  incr passed;
  if not condition
  then (
    incr failed;
    Printf.eprintf "FAIL %s\n" name)
;;

let request ?(record = None) () =
  Sol_cli_cloud_run.
    { project = "sol-qualification"
    ; region = "us-west1"
    ; service = "sol-test"
    ; image = "us-west1-docker.pkg.dev/p/r/image@sha256:abc123"
    ; identity =
        { unit = "checkout/checkout_svc"
        ; callers = [ "103076866099743206289", "checkout/checkout_svc" ]
        ; issuer = "https://accounts.google.com"
        ; jwks_uri = "https://www.googleapis.com/oauth2/v3/certs"
        }
    ; ingress = Public
    ; record
    }
;;

let describe_json ~revision ~percent =
  Yojson.Safe.to_string
    (`Assoc
        [ ( "status"
          , `Assoc
              [ "url", `String "https://service.example"
              ; "latestReadyRevisionName", `String revision
              ; ( "traffic"
                , `List
                    [ `Assoc [ "revisionName", `String revision; "percent", `Int percent ]
                    ] )
              ] )
        ])
;;

let test_ingress () =
  check
    "public ingress is explicit"
    (Result.is_ok (Sol_cli_cloud_run.ingress_of_string "public"));
  check
    "private ingress is refused"
    (Result.is_error (Sol_cli_cloud_run.ingress_of_string "private"))
;;

let test_preflight () =
  (match Sol_cli_cloud_run.preflight (request ()) with
   | Ok () -> check "request preflight" true
   | Error e -> check ("request preflight " ^ Sol_cli_cloud_run.failure_to_string e) false);
  let bad_image = { (request ()) with image = "image:latest" } in
  check "mutable image refused" (Result.is_error (Sol_cli_cloud_run.preflight bad_image));
  let bad_caller =
    { (request ()) with
      identity =
        { (request ()).identity with callers = [ "system:serviceaccount:x:y", "x/y" ] }
    }
  in
  check
    "Kubernetes caller refused"
    (Result.is_error (Sol_cli_cloud_run.preflight bad_caller));
  let bad_jwks =
    { (request ()) with
      identity = { (request ()).identity with jwks_uri = "https://example/certs" }
    }
  in
  check "non-Google JWKS refused" (Result.is_error (Sol_cli_cloud_run.preflight bad_jwks))
;;

let test_deploy_argv () =
  let argv = Sol_cli_cloud_run.deploy_argv (request ()) in
  let joined = String.concat " " argv in
  check "deploy uses image" (String.contains joined '@');
  check "deploy uses google scheme" (String.contains joined 'g');
  check
    "deploy sets env"
    (List.exists
       (fun value ->
          String.starts_with ~prefix:"SOL_WORKLOAD_SUBJECT_SCHEME=google" value)
       argv
     || List.exists (fun value -> String.starts_with ~prefix:"--set-env-vars=" value) argv
     || String.contains joined '=')
;;

let test_deploy_and_verify () =
  let calls = ref [] in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          calls := argv :: !calls;
          match argv with
          | "gcloud" :: "run" :: "deploy" :: _ -> Ok "deployed"
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (describe_json ~revision:"rev-1" ~percent:100)
          | _ -> Error ("unexpected " ^ String.concat " " argv))
    ; http =
        (fun ~url ~token ->
          match url, token with
          | url, None when String.ends_with ~suffix:"/readyz" url -> Ok (200, "")
          | url, Some _ when String.ends_with ~suffix:"/quote" url -> Ok (200, "")
          | url, None when String.ends_with ~suffix:"/quote" url -> Ok (401, "")
          | _ -> Error "unexpected HTTP path")
    }
  in
  let req = request () in
  (match Sol_cli_cloud_run.deploy runner req with
   | Ok release ->
     check "deploy records revision" (release.revision = "rev-1");
     check "deploy records current URL" (release.url = "https://service.example")
   | Error e -> check ("deploy " ^ Sol_cli_cloud_run.failure_to_string e) false);
  (match Sol_cli_cloud_run.verify runner req ~token:"token" with
   | Ok observed -> check "verify observes URL" (observed.url = "https://service.example")
   | Error e -> check ("verify " ^ Sol_cli_cloud_run.failure_to_string e) false);
  (match Sol_cli_cloud_run.verify runner req ~token:"" with
   | Error (Refused _) -> check "verify refuses missing token" true
   | _ -> check "verify refuses missing token" false);
  check "deploy calls provider" (List.exists (fun argv -> List.mem "deploy" argv) !calls)
;;

let test_verify_does_not_accept_unauth () =
  let runner =
    { Sol_cli_cloud_run.run = (fun _ -> Ok (describe_json ~revision:"rev-1" ~percent:100))
    ; http =
        (fun ~url ~token ->
          match url, token with
          | url, None when String.ends_with ~suffix:"/readyz" url -> Ok (200, "")
          | url, Some _ when String.ends_with ~suffix:"/quote" url -> Ok (200, "")
          | url, None when String.ends_with ~suffix:"/quote" url -> Ok (200, "")
          | _ -> Error "unexpected")
    }
  in
  match Sol_cli_cloud_run.verify runner (request ()) ~token:"token" with
  | Error (Unknown _) -> check "unauthorized 200 fails verify" true
  | _ -> check "unauthorized 200 fails verify" false
;;

let test_rollback () =
  let revision = ref "" in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (describe_json ~revision:!revision ~percent:100)
          | "gcloud" :: "run" :: "services" :: "update-traffic" :: _ ->
            revision := "rev-prev";
            Ok "done"
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  revision := "rev-current";
  match Sol_cli_cloud_run.rollback runner (request ()) ~revision:"rev-prev" with
  | Ok observed ->
    check "rollback observes previous revision" (observed.revision = "rev-prev")
  | Error e -> check ("rollback " ^ Sol_cli_cloud_run.failure_to_string e) false
;;

let test_destroy () =
  let present = ref true in
  let deleted = ref false in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            if !present
            then Ok (describe_json ~revision:"rev-1" ~percent:100)
            else Error "not found"
          | "gcloud" :: "run" :: "services" :: "delete" :: _ ->
            present := false;
            deleted := true;
            Ok "deleted"
          | "gcloud" :: "run" :: "services" :: "list" :: _ ->
            if !present then Ok "sol-test" else Ok ""
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  match Sol_cli_cloud_run.destroy runner ~project:"p" ~region:"r" ~service:"sol-test" with
  | Ok () -> check "destroy deletes and verifies absence" !deleted
  | Error e -> check ("destroy " ^ Sol_cli_cloud_run.failure_to_string e) false
;;

let test_partial_deploy () =
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "deploy" :: _ -> Error "deploy failed"
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (describe_json ~revision:"rev-old" ~percent:100)
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  match Sol_cli_cloud_run.deploy runner (request ()) with
  | Error (Partial (_, Some observed)) ->
    check "partial deploy reports observed revision" (observed.revision = "rev-old")
  | _ -> check "partial deploy reports observed revision" false
;;

let test_deploy_requires_serving_revision () =
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "deploy" :: _ -> Ok "deployed"
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (describe_json ~revision:"rev-new" ~percent:0)
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  match Sol_cli_cloud_run.deploy runner (request ()) with
  | Error (Unknown _) -> check "deploy refuses revision at 0 percent" true
  | _ -> check "deploy refuses revision at 0 percent" false
;;

let test_rollback_requires_target_traffic () =
  let described = ref "rev-current" in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (describe_json ~revision:!described ~percent:100)
          | "gcloud" :: "run" :: "services" :: "update-traffic" :: _ -> Ok "updated"
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  match Sol_cli_cloud_run.rollback runner (request ()) ~revision:"rev-wanted" with
  | Error (Unknown _) -> check "rollback refuses unobserved target revision" true
  | _ -> check "rollback refuses unobserved target revision" false
;;

let () =
  test_ingress ();
  test_preflight ();
  test_deploy_argv ();
  test_deploy_and_verify ();
  test_verify_does_not_accept_unauth ();
  test_rollback ();
  test_destroy ();
  test_partial_deploy ();
  test_deploy_requires_serving_revision ();
  test_rollback_requires_target_traffic ();
  Printf.printf "%d passed, %d failed\n" !passed !failed;
  if !failed > 0 then exit 1
;;
