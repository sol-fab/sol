let target : Sol_cli_config.target =
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
  ; state_bucket = None
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; shape = Some Sol_cli_profile.Local
  ; provider_fields = []
  ; secret_authorities = []
  }
;;

let fake_terraform ~log ~stdout ~exit_code =
  Printf.sprintf
    {|#!/bin/sh
printf '%%s\n' "$*" >> %s
printf '%%s' %s
exit %d
|}
    log
    (Filename.quote stdout)
    exit_code
;;

let with_fake_terraform ~stdout ~exit_code f =
  let dir = Filename.temp_file "sol-fake-terraform-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let bin = Filename.concat dir "terraform" in
  let oc = open_out bin in
  output_string oc (fake_terraform ~log ~stdout ~exit_code);
  close_out oc;
  Unix.chmod bin 0o755;
  let infra = Filename.concat dir "infra" in
  Unix.mkdir infra 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      (try Unix.rmdir infra with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f ~log ~infra)
;;

let reconcile ~infra ~act =
  Sol_cli_cloud_wiring.reconcile_ownership
    ~provider:Sol_cli_provider.Aws
    ~target_cfg:target
    ~cluster_name:"acme-prod"
    ~infra_dir:infra
    ~var_files:[]
    ~vars:[]
    ~act
;;

let imports log =
  In_channel.with_open_text log In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter (fun line -> Sol_cli_string.contains ~needle:"import" line)
;;

let failed_show_is_refused_before_any_import () =
  with_fake_terraform ~stdout:"" ~exit_code:1 (fun ~log ~infra ->
    match reconcile ~infra ~act:true with
    | Ok _ -> Windtrap.fail "an unreadable state must not reconcile successfully"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names the unreadable state"
        true
        (Sol_cli_string.contains ~needle:"could not be read" message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal says nothing is imported"
        true
        (Sol_cli_string.contains ~needle:"ownership is unknown" message);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no import was attempted"
        []
        (imports log))
;;

let malformed_state_is_refused_before_any_import () =
  with_fake_terraform ~stdout:"{ not json" ~exit_code:0 (fun ~log ~infra ->
    match reconcile ~infra ~act:true with
    | Ok _ -> Windtrap.fail "a malformed state must not reconcile successfully"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the refusal names the malformed state"
        true
        (Sol_cli_string.contains ~needle:"invalid" message);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no import was attempted"
        []
        (imports log))
;;

let with_unobservable_provider f =
  let dir = Filename.temp_file "sol-fake-aws-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "aws" in
  let oc = open_out bin in
  output_string oc "#!/bin/sh\nexit 1\n";
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let readable_empty_state_is_not_refused () =
  with_unobservable_provider
  @@ fun () ->
  with_fake_terraform ~stdout:{|{"values": null}|} ~exit_code:0 (fun ~log ~infra ->
    match reconcile ~infra ~act:false with
    | Error message ->
      Windtrap.failf "a readable empty state must not be refused: %s" message
    | Ok reconciliation ->
      Windtrap.equal
        Windtrap.int
        ~msg:"nothing was restored"
        0
        (List.length reconciliation.restored);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"no import was attempted"
        []
        (imports log))
;;

let%test "unreadable state: a failed terraform show refuses before importing" =
  failed_show_is_refused_before_any_import ()
;;

let%test "unreadable state: a malformed state refuses before importing" =
  malformed_state_is_refused_before_any_import ()
;;

let%test "unreadable state: a readable empty state is not refused" =
  readable_empty_state_is_not_refused ()
;;
