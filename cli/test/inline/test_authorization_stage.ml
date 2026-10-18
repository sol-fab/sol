open Sol_cli_authorization_stage

let authorization_resource =
  { Sol_cli_cloud_destroy.address = "aws_iam_role.reconciler"
  ; kind = "aws_iam_role"
  ; name = Some "sol-prod-authorization"
  ; identifier = None
  ; deletion_protection = None
  ; final_snapshot_identifier = None
  ; skip_final_snapshot = None
  }
;;

let represented = Sol_cli_cloud_destroy.State_represented [ authorization_resource ]

let test_state_is_the_evidence () =
  (* The target created the reconciler and its fence, then removed the trust declaration.
     The durable state, not the current configuration, decides that they still exist. *)
  (match destroy_decision ~declared_trust:None ~state:represented with
   | Destroy_established -> ()
   | Never_established ->
     Windtrap.fail
       "a represented authorization root was read as never established because the trust \
        declaration was removed"
   | Destruction_unknown reason ->
     Windtrap.failf "represented authorization state was not readable: %s" reason);
  (match
     destroy_decision
       ~declared_trust:(Some "arn:aws:iam::111122223333:role/sol-ci")
       ~state:represented
   with
   | Destroy_established -> ()
   | Never_established ->
     Windtrap.fail "a represented authorization root must be destroyed"
   | Destruction_unknown reason ->
     Windtrap.failf "represented authorization state was not readable: %s" reason);
  List.iter
    (fun declared_trust ->
       match
         destroy_decision ~declared_trust ~state:Sol_cli_cloud_destroy.State_empty
       with
       | Never_established -> ()
       | Destroy_established ->
         Windtrap.fail "an empty authorization root must be reported as never established"
       | Destruction_unknown reason ->
         Windtrap.failf "an empty authorization root must be readable: %s" reason)
    [ None; Some "arn:aws:iam::111122223333:role/sol-ci" ];
  List.iter
    (fun declared_trust ->
       match
         destroy_decision
           ~declared_trust
           ~state:(Sol_cli_cloud_destroy.State_unreadable "state backend denied")
       with
       | Destruction_unknown reason ->
         Windtrap.equal
           Windtrap.string
           ~msg:"the unreadable state's reason is kept"
           "state backend denied"
           reason
       | Never_established ->
         Windtrap.fail "an unreadable state is not evidence of never being established"
       | Destroy_established ->
         Windtrap.fail "an unreadable state cannot authorize destruction")
    [ None; Some "arn:aws:iam::111122223333:role/sol-ci" ]
;;

let%test "authorization destroy: durable state, not current trust, decides" =
  test_state_is_the_evidence ()
;;

let write path text =
  Result.get_ok (Sol_cli_fs.mkdir_p (Filename.dirname path));
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc text)
;;

let with_tmpdir f =
  let dir = Filename.temp_file "sol-auth-stage-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> ignore (Sol_cli_fs.remove_tree dir)) (fun () -> f dir)
;;

let fake_assets root =
  write (Filename.concat root "framework/ocaml/sol-svc/lib/dune") "";
  write (Filename.concat root "framework/ocaml/kafka-eio-service/lib/dune") "";
  write
    (Filename.concat root "platform/cloud/aws/authorization/main.tf")
    "# authorization\n";
  write (Filename.concat root "platform/shared/components.json") "{}\n";
  match
    Sol_cli_platform_assets.resolve_from
      ~sol_home:(Some root)
      ~exe_dir:"/nonexistent"
      ~release_version:None
  with
  | Ok assets -> assets
  | Error error -> Windtrap.fail (Sol_cli_platform_assets.error_to_string error)
;;

let historical_target : Sol_cli_config.target =
  { name = "prod/aws/us-east-1"
  ; env = "prod"
  ; provider = Sol_cli_provider.Aws
  ; region = "us-east-1"
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = Some "acme-prod"
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = Some "sol-state"
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; shape = Some Sol_cli_profile.Local
  ; provider_fields =
      [ ( "aws"
        , [ "state_lock_table", "sol-lock"
          ; "provisioner_role_arn", "arn:aws:iam::111122223333:role/sol-provisioner"
          ] )
      ]
  ; secret_authorities = []
  }
;;

let with_fake_terraform ~show_out ~show_stderr ~show_exit f =
  let dir = Filename.temp_file "sol-auth-tf-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "terraform" in
  let script =
    Printf.sprintf
      {|#!/bin/sh
printf '%%s\n' "$*" >> %s
case "$*" in
  *" show -json"*)
    printf '%%s' %s
    printf '%%s' %s >&2
    exit %d
    ;;
  *)
    exit 0
    ;;
esac
|}
      log
      (Filename.quote show_out)
      (Filename.quote show_stderr)
      show_exit
  in
  Out_channel.with_open_text bin (fun oc -> output_string oc script);
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  let old_data = Sys.getenv_opt "XDG_DATA_HOME" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Unix.putenv "XDG_DATA_HOME" dir;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (match old_data with
       | Some value -> Unix.putenv "XDG_DATA_HOME" value
       | None -> Unix.putenv "XDG_DATA_HOME" "");
      ignore (Sol_cli_fs.remove_tree dir))
    (fun () -> f ~log)
;;

let run_destroy ~show_out ~show_stderr ~show_exit =
  with_tmpdir (fun root ->
    let assets = fake_assets (Filename.concat root "assets") in
    let log_base = Filename.concat root "logs" in
    Unix.mkdir log_base 0o755;
    let run_log = Sol_cli_run_log.create ~base:log_base ~prefix:"test" () in
    with_fake_terraform ~show_out ~show_stderr ~show_exit (fun ~log ->
      let outcome =
        Sol_cli_authorization_stage.destroy ~assets ~run_log ~target:historical_target
      in
      let calls =
        try In_channel.with_open_text log In_channel.input_all with
        | Sys_error _ -> ""
      in
      outcome, calls))
;;

let%test "authorization destroy: an empty state is never established" =
  let outcome, calls = run_destroy ~show_out:"{}" ~show_stderr:"" ~show_exit:0 in
  (match outcome with
   | Ok Sol_cli_authorization_stage.Not_declared -> ()
   | Ok Sol_cli_authorization_stage.Established ->
     Windtrap.fail "an empty authorization state was reported as destroyed"
   | Error message -> Windtrap.failf "an empty state failed to read: %s" message);
  Windtrap.equal
    Windtrap.bool
    ~msg:"an empty state does not run terraform destroy"
    false
    (Sol_cli_string.contains ~needle:"destroy" calls)
;;

let%test "authorization destroy: an unreadable state refuses, it does not skip" =
  let outcome, calls =
    run_destroy ~show_out:"" ~show_stderr:"state backend denied" ~show_exit:1
  in
  (match outcome with
   | Error message ->
     Windtrap.equal
       Windtrap.bool
       ~msg:"the refusal names the unreadable state"
       true
       (Sol_cli_string.contains ~needle:"could not be read" message)
   | Ok _ -> Windtrap.fail "an unreadable authorization state must not be skipped");
  Windtrap.equal
    Windtrap.bool
    ~msg:"an unreadable state does not run terraform destroy"
    false
    (Sol_cli_string.contains ~needle:"destroy" calls)
;;

let%test "authorization destroy: removed trust still yields destroy variables" =
  match destroy_root_vars historical_target with
  | Error message ->
    Windtrap.failf
      "the removed trust declaration blocked the destroy variables: %s"
      message
  | Ok vars ->
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"the destroy vars carry the provider's placeholder trust principal"
      (Some "arn:aws:iam::000000000000:role/sol-destroy-placeholder")
      (List.assoc_opt "reconciler_trust_principal_arn" vars)
;;

let%test "authorization destroy: an unresolved prior apply is not empty-state evidence" =
  match
    Sol_cli_state_guard.verdict
      ~constructive:true
      ~accept_unresolved:false
      (Sol_cli_supervised.Unresolved
         { reason = "the authorization apply was interrupted"; dir = "/record" })
  with
  | Sol_cli_state_guard.Refuse message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the guard names the provider-may-have-changed risk"
      true
      (Sol_cli_string.contains ~needle:"without recording it" message)
  | Sol_cli_state_guard.Proceed
  | Sol_cli_state_guard.Warn _
  | Sol_cli_state_guard.Acknowledge _ ->
    Windtrap.fail
      "an unresolved authorization apply must not let an empty state claim \
       never-established"
;;
