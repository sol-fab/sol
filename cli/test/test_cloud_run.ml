let out stdout = { Sol_cli_cloud_run.stdout; stderr = "" }
let out_with_warning stdout stderr = { Sol_cli_cloud_run.stdout; stderr }
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
    ; provider_service = "sol-test"
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

let describe_json_with_latest ~latest ~revision ~percent =
  Yojson.Safe.to_string
    (`Assoc
        [ ( "spec"
          , `Assoc
              [ ( "template"
                , `Assoc
                    [ ( "spec"
                      , `Assoc
                          [ ( "containers"
                            , `List [ `Assoc [ "image", `String "repo@sha256:abc123" ] ] )
                          ] )
                    ] )
              ] )
        ; ( "metadata"
          , `Assoc
              [ "name", `String "sol-test"
              ; ( "labels"
                , `Assoc
                    [ "sol-owned", `String "cloud-run-experiment"
                    ; "sol-service", `String "sol-test"
                    ] )
              ] )
        ; ( "status"
          , `Assoc
              [ "url", `String "https://service.example"
              ; "latestReadyRevisionName", `String latest
              ; ( "traffic"
                , `List
                    [ `Assoc [ "revisionName", `String revision; "percent", `Int percent ]
                    ] )
              ] )
        ])
;;

let describe_json ~revision ~percent =
  describe_json_with_latest ~latest:revision ~revision ~percent
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
  check "non-Google JWKS refused" (Result.is_error (Sol_cli_cloud_run.preflight bad_jwks));
  let bad_separator =
    { (request ()) with
      identity = { (request ()).identity with callers = [ "subject,with,comma", "unit" ] }
    }
  in
  check
    "caller separator is refused"
    (Result.is_error (Sol_cli_cloud_run.preflight bad_separator))
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
          | "gcloud" :: "run" :: "services" :: "list" :: _ -> Ok (out "")
          | "gcloud" :: "run" :: "deploy" :: _ -> Ok (out "deployed")
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (out (describe_json ~revision:"rev-1" ~percent:100))
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
    { Sol_cli_cloud_run.run =
        (fun _ -> Ok (out (describe_json ~revision:"rev-1" ~percent:100)))
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
            Ok
              (out
                 (describe_json_with_latest
                    ~latest:(if !revision = "rev-prev" then "rev-current" else !revision)
                    ~revision:!revision
                    ~percent:100))
          | "gcloud" :: "run" :: "services" :: "update-traffic" :: _ ->
            revision := "rev-prev";
            Ok (out "done")
          | _ -> Error "unexpected")
    ; http =
        (fun ~url ~token ->
          match url, token with
          | url, None when String.ends_with ~suffix:"/readyz" url -> Ok (200, "")
          | url, Some _ when String.ends_with ~suffix:"/quote" url -> Ok (200, "")
          | url, None when String.ends_with ~suffix:"/quote" url -> Ok (401, "")
          | _ -> Error "unexpected")
    }
  in
  revision := "rev-current";
  match
    Sol_cli_cloud_run.rollback
      runner
      (request ())
      ~revision:"rev-prev"
      ~token:"token"
      ~on_revision_moved:(fun _ -> Ok ())
  with
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
            then Ok (out (describe_json ~revision:"rev-1" ~percent:100))
            else Error "not found"
          | "gcloud" :: "run" :: "services" :: "delete" :: _ ->
            present := false;
            deleted := true;
            Ok (out "deleted")
          | "gcloud" :: "run" :: "services" :: "list" :: _ ->
            if !present then Ok (out "sol-test") else Ok (out "")
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  let record = Filename.temp_file "sol-cloud-run-record-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove record with
      | Sys_error _ -> ())
    (fun () ->
       let channel = open_out record in
       output_string
         channel
         (Yojson.Safe.to_string
            (`Assoc
                [ "project", `String "p"
                ; "region", `String "r"
                ; "service", `String "sol-test"
                ; "provider_service", `String "sol-test"
                ; "revision", `String "rev-1"
                ; "url", `String "https://service.example"
                ; "image", `String "repo@sha256:abc123"
                ]));
       close_out channel;
       match
         Sol_cli_cloud_run.destroy
           runner
           ~project:"p"
           ~region:"r"
           ~service:"sol-test"
           ~record
       with
       | Ok () -> check "destroy deletes and verifies absence" !deleted
       | Error e -> check ("destroy " ^ Sol_cli_cloud_run.failure_to_string e) false)
;;

let test_partial_deploy () =
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "list" :: _ -> Ok (out "")
          | "gcloud" :: "run" :: "deploy" :: _ -> Error "deploy failed"
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (out (describe_json ~revision:"rev-old" ~percent:100))
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
          | "gcloud" :: "run" :: "services" :: "list" :: _ -> Ok (out "")
          | "gcloud" :: "run" :: "deploy" :: _ -> Ok (out "deployed")
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (out (describe_json ~revision:"rev-new" ~percent:0))
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
            Ok (out (describe_json ~revision:!described ~percent:100))
          | "gcloud" :: "run" :: "services" :: "update-traffic" :: _ -> Ok (out "updated")
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  match
    Sol_cli_cloud_run.rollback
      runner
      (request ())
      ~revision:"rev-wanted"
      ~token:"token"
      ~on_revision_moved:(fun _ -> Ok ())
  with
  | Error (Unknown _) -> check "rollback refuses unobserved target revision" true
  | _ -> check "rollback refuses unobserved target revision" false
;;

let test_destroy_requires_matching_ownership () =
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (out (describe_json ~revision:"rev-1" ~percent:100))
          | "gcloud" :: "run" :: "services" :: "delete" :: _ ->
            check "unowned destroy never deletes" false;
            Ok (out "deleted")
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  match
    Sol_cli_cloud_run.destroy
      runner
      ~project:"p"
      ~region:"r"
      ~service:"sol-test"
      ~record:"/definitely/missing/record.json"
  with
  | Error (Refused _) -> check "destroy without ownership record refuses" true
  | _ -> check "destroy without ownership record refuses" false
;;

let test_destroy_refuses_stale_record () =
  let record = Filename.temp_file "sol-cloud-run-stale-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove record with
      | Sys_error _ -> ())
    (fun () ->
       let channel = open_out record in
       output_string
         channel
         (Yojson.Safe.to_string
            (`Assoc
                [ "project", `String "p"
                ; "region", `String "r"
                ; "service", `String "sol-test"
                ; "provider_service", `String "sol-test"
                ; "revision", `String "rev-old"
                ; "url", `String "https://service.example"
                ; "image", `String "repo@sha256:abc123"
                ]));
       close_out channel;
       let runner =
         { Sol_cli_cloud_run.run =
             (fun argv ->
               match argv with
               | "gcloud" :: "run" :: "services" :: "list" :: _ -> Ok (out "sol-test")
               | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
                 Ok (out (describe_json ~revision:"rev-new" ~percent:100))
               | "gcloud" :: "run" :: "services" :: "delete" :: _ ->
                 check "stale record never deletes" false;
                 Ok (out "deleted")
               | _ -> Error "unexpected")
         ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
         }
       in
       match
         Sol_cli_cloud_run.destroy
           runner
           ~project:"p"
           ~region:"r"
           ~service:"sol-test"
           ~record
       with
       | Error (Refused _) -> check "stale record refuses destroy" true
       | _ -> check "stale record refuses destroy" false)
;;

let test_rollback_records_before_verification () =
  let described = ref "rev-current" in
  let recorded = ref None in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (out (describe_json ~revision:!described ~percent:100))
          | "gcloud" :: "run" :: "services" :: "update-traffic" :: _ ->
            described := "rev-prev";
            Ok (out "updated")
          | _ -> Error "unexpected")
    ; http =
        (fun ~url ~token ->
          match url, token with
          | url, None when String.ends_with ~suffix:"/readyz" url -> Ok (200, "")
          | url, Some _ when String.ends_with ~suffix:"/quote" url -> Ok (200, "")
          | url, None when String.ends_with ~suffix:"/quote" url -> Ok (200, "")
          | _ -> Error "unexpected")
    }
  in
  match
    Sol_cli_cloud_run.rollback
      runner
      (request ())
      ~revision:"rev-prev"
      ~token:"token"
      ~on_revision_moved:(fun revision ->
        recorded := Some revision;
        Ok ())
  with
  | Error (Partial (_, Some observed)) ->
    check
      ("rollback reports observed revision after verification failure: "
       ^ observed.revision)
      (observed.revision = "rev-prev");
    check
      "rollback records the moved revision before verification fails"
      (!recorded = Some "rev-prev")
  | _ -> check "rollback refuses unauthenticated serving state" false
;;

let test_rollback_reconciles_traffic_error () =
  let described = ref "rev-current" in
  let recorded = ref None in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (out (describe_json ~revision:!described ~percent:100))
          | "gcloud" :: "run" :: "services" :: "update-traffic" :: _ ->
            (* The mutation applied, but the CLI reported a transport failure afterward. *)
            described := "rev-prev";
            Error "simulated transport failure"
          | _ -> Error "unexpected")
    ; http =
        (fun ~url ~token ->
          match url, token with
          | url, None when String.ends_with ~suffix:"/readyz" url -> Ok (200, "")
          | url, Some _ when String.ends_with ~suffix:"/quote" url -> Ok (200, "")
          | url, None when String.ends_with ~suffix:"/quote" url -> Ok (401, "")
          | _ -> Error "unexpected")
    }
  in
  (match
     Sol_cli_cloud_run.rollback
       runner
       (request ())
       ~revision:"rev-prev"
       ~token:"token"
       ~on_revision_moved:(fun revision ->
         recorded := Some revision;
         Ok ())
   with
   | Ok observed ->
     check "reconciled traffic error is successful" (observed.revision = "rev-prev")
   | Error e ->
     check ("reconciled traffic error " ^ Sol_cli_cloud_run.failure_to_string e) false);
  check "reconciled traffic error records the moved revision" (!recorded = Some "rev-prev")
;;

let test_rollback_refuses_unreconciled_traffic_error () =
  let described = ref "rev-current" in
  let recorded = ref None in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok (out (describe_json ~revision:!described ~percent:100))
          | "gcloud" :: "run" :: "services" :: "update-traffic" :: _ ->
            Error "simulated transport failure"
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  (match
     Sol_cli_cloud_run.rollback
       runner
       (request ())
       ~revision:"rev-prev"
       ~token:"token"
       ~on_revision_moved:(fun revision ->
         recorded := Some revision;
         Ok ())
   with
   | Error (Partial (_, Some observed)) ->
     check
       "unreconciled traffic error reports the unchanged serving revision"
       (observed.revision = "rev-current")
   | _ -> check "unreconciled traffic error fails" false);
  check "unreconciled traffic error does not record" (!recorded = None)
;;

let test_destroy_refuses_unowned_live_service () =
  let record = Filename.temp_file "sol-cloud-run-record-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove record with
      | Sys_error _ -> ())
    (fun () ->
       let channel = open_out record in
       output_string
         channel
         (Yojson.Safe.to_string
            (`Assoc
                [ "project", `String "p"
                ; "region", `String "r"
                ; "service", `String "sol-test"
                ; "provider_service", `String "sol-test"
                ; "revision", `String "rev-1"
                ; "url", `String "https://service.example"
                ; "image", `String "repo@sha256:abc123"
                ]));
       close_out channel;
       let runner =
         { Sol_cli_cloud_run.run =
             (fun argv ->
               match argv with
               | "gcloud" :: "run" :: "services" :: "list" :: _ -> Ok (out "sol-test")
               | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
                 (* A pre-existing service: matching record but no adapter labels. *)
                 Ok
                   (out
                      (Yojson.Safe.to_string
                         (`Assoc
                             [ "metadata", `Assoc [ "name", `String "sol-test" ]
                             ; ( "status"
                               , `Assoc
                                   [ "url", `String "https://pre-existing.example"
                                   ; "latestReadyRevisionName", `String "rev-1"
                                   ; ( "traffic"
                                     , `List
                                         [ `Assoc
                                             [ "revisionName", `String "rev-1"
                                             ; "percent", `Int 100
                                             ]
                                         ] )
                                   ] )
                             ])))
               | "gcloud" :: "run" :: "services" :: "delete" :: _ ->
                 check "unowned live service never deletes" false;
                 Ok (out "deleted")
               | _ -> Error "unexpected")
         ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
         }
       in
       match
         Sol_cli_cloud_run.destroy
           runner
           ~project:"p"
           ~region:"r"
           ~service:"sol-test"
           ~record
       with
       | Error (Refused _) -> check "unowned live service refuses destroy" true
       | _ -> check "unowned live service refuses destroy" false)
;;

let test_verify_writes_release_record () =
  let record = Filename.temp_file "sol-cloud-run-release-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove record with
      | Sys_error _ -> ())
    (fun () ->
       let runner =
         { Sol_cli_cloud_run.run =
             (fun _ -> Ok (out (describe_json ~revision:"rev-verified" ~percent:100)))
         ; http =
             (fun ~url ~token ->
               match url, token with
               | url, None when String.ends_with ~suffix:"/readyz" url -> Ok (200, "")
               | url, Some _ when String.ends_with ~suffix:"/quote" url -> Ok (200, "")
               | url, None when String.ends_with ~suffix:"/quote" url -> Ok (401, "")
               | _ -> Error "unexpected")
         }
       in
       match
         Sol_cli_cloud_run.verify
           runner
           { (request ()) with
             image = "requested@sha256:different"
           ; record = Some record
           }
           ~token:"token"
       with
       | Ok _ ->
         let text = In_channel.with_open_bin record In_channel.input_all in
         check "verify writes release record" (String.contains text 'r');
         check
           "release record names observed revision"
           (String.length text > 0
            &&
            match Yojson.Safe.from_string text with
            | `Assoc _ -> true
            | _ -> false)
       | Error e ->
         check ("verify release record " ^ Sol_cli_cloud_run.failure_to_string e) false)
;;

let test_deploy_refuses_unowned_service () =
  let deployed = ref false in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "list" :: _ -> Ok (out "sol-test")
          | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
            Ok
              (out
                 (Yojson.Safe.to_string
                    (`Assoc
                        [ "metadata", `Assoc [ "name", `String "sol-test" ]
                        ; ( "status"
                          , `Assoc
                              [ "url", `String "https://pre-existing.example"
                              ; "latestReadyRevisionName", `String "rev-old"
                              ; ( "traffic"
                                , `List
                                    [ `Assoc
                                        [ "revisionName", `String "rev-old"
                                        ; "percent", `Int 100
                                        ]
                                    ] )
                              ] )
                        ])))
          | "gcloud" :: "run" :: "deploy" :: _ ->
            deployed := true;
            Ok (out "deployed")
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  (match Sol_cli_cloud_run.deploy runner (request ()) with
   | Error (Refused _) -> check "deploy refuses unowned pre-existing service" true
   | _ -> check "deploy refuses unowned pre-existing service" false);
  check "unowned deploy did not mutate" (not !deployed)
;;

let test_destroy_refuses_provider_record_mismatch () =
  let record = Filename.temp_file "sol-cloud-run-provider-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove record with
      | Sys_error _ -> ())
    (fun () ->
       let channel = open_out record in
       output_string
         channel
         (Yojson.Safe.to_string
            (`Assoc
                [ "project", `String "p"
                ; "region", `String "r"
                ; "service", `String "sol-test"
                ; "provider_service", `String "checkout-svc"
                ; "revision", `String "rev-1"
                ; "url", `String "https://service.example"
                ; "image", `String "repo@sha256:abc123"
                ]));
       close_out channel;
       let runner =
         { Sol_cli_cloud_run.run =
             (fun argv ->
               match argv with
               | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
                 Ok (out (describe_json ~revision:"rev-1" ~percent:100))
               | "gcloud" :: "run" :: "services" :: "delete" :: _ ->
                 check "mismatched provider record never deletes" false;
                 Ok (out "deleted")
               | _ -> Error "unexpected")
         ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
         }
       in
       match
         Sol_cli_cloud_run.destroy
           runner
           ~project:"p"
           ~region:"r"
           ~service:"sol-test"
           ~record
       with
       | Error (Refused _) -> check "mismatched provider record refuses destroy" true
       | _ -> check "mismatched provider record refuses destroy" false)
;;

let test_destroy_unreadable_inventory_is_unknown () =
  let record = Filename.temp_file "sol-cloud-run-record-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove record with
      | Sys_error _ -> ())
    (fun () ->
       let channel = open_out record in
       output_string
         channel
         (Yojson.Safe.to_string
            (`Assoc
                [ "project", `String "p"
                ; "region", `String "r"
                ; "service", `String "sol-test"
                ; "provider_service", `String "sol-test"
                ; "revision", `String "rev-1"
                ; "url", `String "https://service.example"
                ; "image", `String "repo@sha256:abc123"
                ]));
       close_out channel;
       let runner =
         { Sol_cli_cloud_run.run =
             (fun argv ->
               match argv with
               | "gcloud" :: "run" :: "services" :: "describe" :: _ ->
                 Ok (out (describe_json ~revision:"rev-1" ~percent:100))
               | "gcloud" :: "run" :: "services" :: "delete" :: _ -> Ok (out "deleted")
               | "gcloud" :: "run" :: "services" :: "list" :: _ ->
                 Error "inventory unavailable"
               | _ -> Error "unexpected")
         ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
         }
       in
       match
         Sol_cli_cloud_run.destroy
           runner
           ~project:"p"
           ~region:"r"
           ~service:"sol-test"
           ~record
       with
       | Error (Unknown _) -> check "unreadable inventory is unknown" true
       | _ -> check "unreadable inventory is unknown" false)
;;

let test_provider_naming () =
  (match Sol_cli_cloud_run.provider_service_of "checkout_svc" with
   | Ok provider -> check "checkout_svc maps to checkout-svc" (provider = "checkout-svc")
   | Error e ->
     check
       ("checkout_svc provider mapping " ^ Sol_cli_cloud_run.failure_to_string e)
       false);
  check
    "invalid provider name is refused"
    (Result.is_error (Sol_cli_cloud_run.provider_service_of "_"));
  let checkout =
    { (request ()) with service = "checkout_svc"; provider_service = "checkout-svc" }
  in
  check
    "checkout_svc preflight accepts canonical provider"
    (Result.is_ok (Sol_cli_cloud_run.preflight checkout));
  let mismatched = { checkout with provider_service = "checkout_svc" } in
  check
    "provider/Sol name mismatch is refused"
    (Result.is_error (Sol_cli_cloud_run.preflight mismatched))
;;

let test_describe_error_is_not_absence () =
  let deployed = ref false in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "list" :: _ ->
            Error "ERROR: Cannot find service [sol-test]"
          | "gcloud" :: "run" :: "deploy" :: _ ->
            deployed := true;
            Ok (out "deployed")
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  (match Sol_cli_cloud_run.deploy runner (request ()) with
   | Error (Unknown _) -> check "failed inventory is unknown, not absent" true
   | _ -> check "failed inventory is unknown, not absent" false);
  check "failed inventory did not mutate" (not !deployed)
;;

let test_inventory_warning_is_unknown () =
  let deployed = ref false in
  let runner =
    { Sol_cli_cloud_run.run =
        (fun argv ->
          match argv with
          | "gcloud" :: "run" :: "services" :: "list" :: _ ->
            Ok (out_with_warning "" "WARNING: scope could not be fully enumerated")
          | "gcloud" :: "run" :: "deploy" :: _ ->
            deployed := true;
            Ok (out "deployed")
          | _ -> Error "unexpected")
    ; http = (fun ~url:_ ~token:_ -> Ok (200, ""))
    }
  in
  (match Sol_cli_cloud_run.deploy runner (request ()) with
   | Error (Unknown _) -> check "warning-bearing inventory is unknown" true
   | _ -> check "warning-bearing inventory is unknown" false);
  check "warning-bearing inventory did not mutate" (not !deployed)
;;

let () =
  test_ingress ();
  test_provider_naming ();
  test_describe_error_is_not_absence ();
  test_inventory_warning_is_unknown ();
  test_preflight ();
  test_deploy_argv ();
  test_deploy_and_verify ();
  test_verify_does_not_accept_unauth ();
  test_rollback ();
  test_destroy ();
  test_partial_deploy ();
  test_deploy_requires_serving_revision ();
  test_rollback_requires_target_traffic ();
  test_destroy_requires_matching_ownership ();
  test_destroy_refuses_unowned_live_service ();
  test_destroy_refuses_stale_record ();
  test_destroy_refuses_provider_record_mismatch ();
  test_destroy_unreadable_inventory_is_unknown ();
  test_rollback_records_before_verification ();
  test_rollback_reconciles_traffic_error ();
  test_rollback_refuses_unreconciled_traffic_error ();
  test_verify_writes_release_record ();
  test_deploy_refuses_unowned_service ();
  Printf.printf "%d passed, %d failed\n" !passed !failed;
  if !failed > 0 then exit 1
;;
