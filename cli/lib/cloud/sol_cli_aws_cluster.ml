type aws_outputs =
  { cluster_name : string
  ; cluster_access_role_arn : string
  ; deploy_kube_context : string option
  ; cert_manager_irsa_role_arn : string
  ; loki_s3_bucket : string option
  ; loki_irsa_role_arn : string option
  ; thanos_s3_bucket : string option
  ; thanos_irsa_role_arn : string option
  ; grafana_irsa_role_arn : string option
  ; managed_resource_dashboards : Yojson.Safe.t
  ; database_egress_cidrs : string list
  ; (* The database's administrative connection, as the provisioning configuration
       reports it. Null when no database was created. No code read this before; the
       database setup step is its first consumer. *)
    postgres_url : string option
  ; (* The trust anchor a client needs for this provider's sslmode (see
       Sol_cli_provider_registry.postgres_sslmode). Null when no database was
       created. The committed global RDS bundle, coupled to the instance's pinned
       ca_cert_identifier. *)
    postgres_ca_cert : string option
  }

let aws_outputs_of_json text =
  let open Result.Syntax in
  let* value, string, optional_string =
    Sol_cli_cluster.outputs_reader ~provider:"AWS" text
  in
  let* cluster_name = string "cluster_name" in
  let* cluster_access_role_arn = string "cluster_access_role_arn" in
  let* deploy_kube_context = optional_string "deploy_kube_context" in
  let* cert_manager_irsa_role_arn = string "cert_manager_irsa_arn" in
  let* loki_s3_bucket = optional_string "loki_s3_bucket" in
  let* loki_irsa_role_arn = optional_string "loki_irsa_arn" in
  let* thanos_s3_bucket = optional_string "thanos_s3_bucket" in
  let* thanos_irsa_role_arn = optional_string "thanos_irsa_arn" in
  let* grafana_irsa_role_arn = optional_string "grafana_irsa_arn" in
  let database_egress_cidrs = value "database_egress_cidrs" in
  let* database_egress_cidrs =
    match database_egress_cidrs with
    | `Null -> Ok []
    | `List items
      when List.for_all
             (function
               | `String _ -> true
               | _ -> false)
             items ->
      Ok
        (List.map
           (function
             | `String cidr -> cidr
             | _ -> "")
           items)
    | _ -> Error "AWS Terraform output \"database_egress_cidrs\" is not a list of strings"
  in
  let* postgres_url = optional_string "postgres_url" in
  let* postgres_ca_cert = optional_string "postgres_ca_cert" in
  let managed_resource_dashboards = value "managed_resource_dashboards" in
  match managed_resource_dashboards with
  | `Assoc _ ->
    Ok
      { cluster_name
      ; cluster_access_role_arn
      ; deploy_kube_context
      ; cert_manager_irsa_role_arn
      ; loki_s3_bucket
      ; loki_irsa_role_arn
      ; thanos_s3_bucket
      ; thanos_irsa_role_arn
      ; grafana_irsa_role_arn
      ; managed_resource_dashboards
      ; database_egress_cidrs
      ; postgres_url
      ; postgres_ca_cert
      }
  | _ -> Error "AWS Terraform output \"managed_resource_dashboards\" is not an object"
;;

let cluster_access_role_arn (outputs : aws_outputs) = outputs.cluster_access_role_arn

let provisioner_kubeconfig ?role_arn ~region outputs f =
  let path = Filename.temp_file "sol-platform-provisioner-" ".kubeconfig" in
  let cleanup () = Sol_cli_fs.remove_reporting path in
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
    Sol_cli_report.app "  cluster access identity: %s" (cluster_access_role_arn outputs);
    let env = Sol_cli_cluster.provisioner_kube_env path in
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           ~env
           [ "aws"
           ; "eks"
           ; "update-kubeconfig"
           ; "--region"
           ; region
           ; "--name"
           ; outputs.cluster_name
           ; "--alias"
           ; outputs.cluster_name
           ; "--role-arn"
           ; (match role_arn with
              | Some arn -> arn
              | None -> cluster_access_role_arn outputs)
           ; "--kubeconfig"
           ; path
           ])
    with
    | Ok _ -> Ok (f env)
    | Error _ -> Error "could not establish ephemeral provisioner cluster access")
;;

let deploy_access ~region (outputs : aws_outputs) ~deploy_role_arn () =
  match deploy_role_arn, outputs.deploy_kube_context with
  | Some role_arn, Some context when not (Sol_cli_string.is_blank role_arn) ->
    let path = Filename.temp_file "sol-platform-deploy-" ".kubeconfig" in
    at_exit (fun () -> Sol_cli_fs.remove_reporting path);
    let env = Sol_cli_cluster.provisioner_kube_env path in
    (match
       Sol_cli_process.run
         (Sol_cli_process.cmd
            ~env
            [ "aws"
            ; "eks"
            ; "update-kubeconfig"
            ; "--region"
            ; region
            ; "--name"
            ; outputs.cluster_name
            ; "--alias"
            ; context
            ; "--role-arn"
            ; role_arn
            ; "--kubeconfig"
            ; path
            ])
     with
     | Ok _ ->
       Sol_cli_report.app "  cluster access identity: %s (this run, ephemeral)" role_arn;
       Sol_cli_kube_destination.of_context ~kubeconfig:path context
       |> Result.map Option.some
     | Error error ->
       Error
         (Printf.sprintf
            "could not establish this run's ephemeral deploy-identity cluster access \
             (%s). The environment was provisioned; the deploy identity reaches the \
             cluster only if your credentials may assume %s, and the role's trust policy \
             is yours to set (AUDIT-072). %s"
            role_arn
            role_arn
            (Sol_cli_process.error_to_string error)))
  | _ -> Ok None
;;

let bootstrap_only_capabilities = Sol_cli_bootstrap_window.bootstrap_only
let successor_capabilities = Sol_cli_bootstrap_window.successor

let capability_answer_of_can_i ~env capability =
  Sol_cli_bootstrap_window.can_i
    ~run:(fun argv -> Sol_cli_process.run (Sol_cli_process.cmd ~env argv))
    capability
;;

let successor_probe ~region ~outputs () =
  provisioner_kubeconfig ~region outputs (fun env ->
    Sol_cli_bootstrap_window.probe
      ~run:(fun argv -> Sol_cli_process.run (Sol_cli_process.cmd ~env argv))
      successor_capabilities)
;;

let whoami_retry_interval_s () =
  Sol_cli_duration.env_seconds ~name:"SOL_WHOAMI_RETRY_INTERVAL_S" ~default:10.
;;

let cluster_propagation_attempts = 10
let deescalation_attempts = 18

type whoami_identity =
  { arn : string option
  ; canonical_arn : string option
  ; username : string option
  ; source : string
  }

let single_string_of_json ~what = function
  | `String v -> Ok (Some v)
  | `List [ `String v ] -> Ok (Some v)
  | `List [] -> Error (Printf.sprintf "a %s value was an empty array" what)
  | `List (_ :: _ :: _) ->
    Error (Printf.sprintf "a %s value was an array of more than one element" what)
  | `Null -> Ok None
  | _ ->
    Error (Printf.sprintf "a %s value was neither a string nor an array of strings" what)
;;

let whoami_identity_of_json json : (whoami_identity, string) result =
  match Yojson.Safe.from_string json with
  | exception Yojson.Json_error _ -> Error "the whoami response was not JSON"
  | json ->
    let sub key j = Sol_cli_json.field [ key ] j in
    let status = sub "status" json in
    let user = sub "userInfo" status in
    let extra = sub "extra" user in
    let source = ref "none" in
    let field name = single_string_of_json ~what:name (sub name user) in
    let extra_field name = single_string_of_json ~what:name (sub name extra) in
    Result.bind (extra_field "arn") (fun extra_arn ->
      Result.bind (field "arn") (fun user_arn ->
        Result.bind (extra_field "canonicalArn") (fun extra_canonical ->
          Result.bind (field "canonicalArn") (fun user_canonical ->
            Result.bind (field "username") (fun username ->
              let arn, arn_source =
                match extra_arn with
                | Some _ as v -> v, "extra.arn"
                | None -> user_arn, "userInfo.arn"
              in
              let canonical_arn, canonical_source =
                match extra_canonical with
                | Some _ as v -> v, "extra.canonicalArn"
                | None -> user_canonical, "userInfo.canonicalArn"
              in
              (source
               := match canonical_arn, arn, username with
                  | Some _, _, _ -> canonical_source
                  | None, Some _, _ -> arn_source
                  | None, None, Some _ -> "username"
                  | None, None, None -> "none");
              let identity = { arn; canonical_arn; username; source = !source } in
              match arn, canonical_arn, username with
              | None, None, None ->
                Error
                  "the whoami response carried no arn and no username (is \
                   SelfSubjectReview supported by this cluster and kubectl?)"
              | _ -> Ok identity)))))
;;

let index_of_substring ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec scan i =
    if i + n > h
    then None
    else if String.sub haystack i n = needle
    then Some i
    else scan (i + 1)
  in
  scan 0
;;

let role_name_of_arn arn =
  let after needle =
    match index_of_substring ~needle arn with
    | None -> None
    | Some i ->
      let from = i + String.length needle in
      Some (String.sub arn from (String.length arn - from))
  in
  match after "assumed-role/" with
  | Some rest ->
    (match String.index_opt rest '/' with
     | Some i -> String.sub rest 0 i
     | None -> rest)
  | None ->
    (match after ":role/" with
     | Some name -> name
     | None ->
       (match String.rindex_opt arn '/' with
        | Some i when i + 1 < String.length arn ->
          String.sub arn (i + 1) (String.length arn - i - 1)
        | _ -> arn))
;;

let principal_role_name (i : whoami_identity) =
  match i.canonical_arn, i.arn, i.username with
  | Some a, _, _ -> Some (role_name_of_arn a)
  | None, Some a, _ -> Some (role_name_of_arn a)
  | None, None, Some u -> Some u
  | None, None, None -> None
;;

let normalize_role_arn arn =
  match index_of_substring ~needle:":role/" arn with
  | None -> arn
  | Some i ->
    let prefix = String.sub arn 0 (i + 6) in
    let name = String.sub arn (i + 6) (String.length arn - i - 6) in
    prefix
    ^
      (match String.rindex_opt name '/' with
      | Some j when j + 1 < String.length name ->
        String.sub name (j + 1) (String.length name - j - 1)
      | _ -> name)
;;

let principal_matches ~expected (identity : whoami_identity) =
  match identity.canonical_arn with
  | Some arn -> Some (String.equal arn expected)
  | None ->
    (match identity.arn with
     | Some arn -> Some (String.equal arn expected)
     | None -> None)
;;

type credential_assumption =
  | Credential_assumable
  | Credential_refused
  | Credential_unchecked

let refusal_is_deescalation assumption detail =
  match assumption with
  | Credential_assumable -> Sol_cli_cloud_lifecycle.Principal_refused_by_cluster detail
  | Credential_refused ->
    Sol_cli_cloud_lifecycle.Principal_probe_failed
      (Printf.sprintf
         "the cluster refused the probe (%s) and the provisioning role could not be \
          assumed, so a broken credential cannot be told apart from a revoked one"
         detail)
  | Credential_unchecked ->
    Sol_cli_cloud_lifecycle.Principal_probe_failed
      (Printf.sprintf
         "the cluster refused the probe (%s) and the identity check could not be \
          performed, so the refusal is not evidence"
         detail)
;;

let deescalation_principal_check ~expected_arn ~assumable_role_arn env =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "whoami"; "-o"; "json" ])
  with
  | Ok r ->
    (match whoami_identity_of_json r.stdout with
     | Ok identity ->
       let shown =
         match identity.canonical_arn, identity.arn with
         | Some a, _ | None, Some a -> a
         | None, None -> "(unnamed)"
       in
       (match principal_matches ~expected:expected_arn identity with
        | Some true -> Sol_cli_cloud_lifecycle.Principal_confirmed shown
        | Some false -> Sol_cli_cloud_lifecycle.Principal_unexpected shown
        | None ->
          Sol_cli_cloud_lifecycle.Principal_probe_failed "the response named no principal")
     | Error why -> Sol_cli_cloud_lifecycle.Principal_probe_failed why)
  | Error (Sol_cli_process.Non_zero r) ->
    let detail = String.trim (r.stderr ^ " " ^ r.stdout) in
    if Sol_cli_kubectl.classify (Sol_cli_process.Non_zero r) = Refused
    then (
      let assumption =
        if Sol_cli_string.is_blank assumable_role_arn
        then Credential_unchecked
        else (
          match
            Sol_cli_process.run
              (Sol_cli_process.cmd
                 ~env
                 [ "aws"
                 ; "sts"
                 ; "assume-role"
                 ; "--role-arn"
                 ; assumable_role_arn
                 ; "--role-session-name"
                 ; "sol-deescalation-check"
                 ])
          with
          | Ok _ -> Credential_assumable
          | Error (Sol_cli_process.Non_zero _) -> Credential_refused
          | Error _ -> Credential_unchecked)
      in
      refusal_is_deescalation assumption detail)
    else Sol_cli_cloud_lifecycle.Principal_probe_failed detail
  | Error e ->
    Sol_cli_cloud_lifecycle.Principal_probe_failed (Sol_cli_process.error_to_string e)
;;

let deescalation_probe ~region ~outputs ~window_role_arn ~assumable_role_arn () =
  match
    provisioner_kubeconfig ~role_arn:window_role_arn ~region outputs (fun env ->
      let principal =
        deescalation_principal_check
          ~expected_arn:(normalize_role_arn window_role_arn)
          ~assumable_role_arn
          env
      in
      let probes =
        match principal with
        | Sol_cli_cloud_lifecycle.Principal_unexpected _
        | Sol_cli_cloud_lifecycle.Principal_probe_failed _
        | Sol_cli_cloud_lifecycle.Principal_refused_by_cluster _ -> []
        | _ ->
          bootstrap_only_capabilities
          |> List.map (fun capability ->
            capability, capability_answer_of_can_i ~env capability)
      in
      principal, probes)
  with
  | Ok v -> v
  | Error e -> Sol_cli_cloud_lifecycle.Principal_probe_failed e, []
;;

let whoami_capture_path ~run_id =
  let name = Printf.sprintf "whoami-capture-%s.json" run_id in
  match Sol_cli_string.env "SOL_QUALIFICATION_CAPTURE_DIR" with
  | Some dir -> Some (Filename.concat dir name)
  | None ->
    (match Sol_cli_string.env "HOME" with
     | Some home -> Some (Filename.concat (Filename.concat home ".sol-qual") name)
     | None -> None)
;;

let persist_whoami_capture ~run_id json =
  match whoami_capture_path ~run_id with
  | None ->
    Sol_cli_report.app
      "  whoami capture: no writable path (set HOME or SOL_QUALIFICATION_CAPTURE_DIR)"
  | Some path ->
    let dir = Filename.dirname path in
    let written =
      let open Result.Syntax in
      let* () = Sol_cli_fs.mkdir_p ~perm:0o700 dir in
      let* () =
        match Unix.chmod dir 0o700 with
        | () -> Ok ()
        | exception Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)
      in
      Sol_cli_fs.write_atomic ~perm:0o600 path json
    in
    (match written with
     | Ok () -> Sol_cli_report.app "  whoami capture: %s" path
     | Error reason ->
       Sol_cli_report.app
         "  whoami capture: could not write %s (%s) -- the raw response is in this log \
          above"
         path
         reason)
;;

let verify_whoami_shape ~region ~outputs ~window_role_arn =
  let open Result.Syntax in
  let fail message = Error message in
  let* interval_s = whoami_retry_interval_s () in
  let expected = normalize_role_arn window_role_arn in
  let run_id = Printf.sprintf "%d" (int_of_float (Unix.gettimeofday ())) in
  let rec attempt remaining =
    let outcome =
      provisioner_kubeconfig ~role_arn:window_role_arn ~region outputs (fun env ->
        Sol_cli_process.run
          (Sol_cli_process.cmd ~env [ "kubectl"; "auth"; "whoami"; "-o"; "json" ]))
    in
    let outcome =
      match outcome with
      | Ok (Ok r) -> Ok r
      | Ok (Error (Sol_cli_process.Non_zero r)) ->
        Error
          (Printf.sprintf
             "kubectl exited %d (%s)"
             r.exit_code
             (String.trim (r.stderr ^ " " ^ r.stdout)))
      | Ok (Error e) -> Error (Sol_cli_process.error_to_string e)
      | Error e -> Error e
    in
    match outcome with
    | Ok r ->
      let json = String.trim r.stdout in
      persist_whoami_capture ~run_id json;
      let identity_result = whoami_identity_of_json json in
      (match identity_result with
       | Error why ->
         fail
           (Printf.sprintf
              "the authorizer's whoami response did not match the parser (%s). The run \
               stops here rather than spending a bootstrap on a verification that cannot \
               succeed. Raw response: %s"
              why
              json)
       | Ok identity ->
         let source = identity.source in
         Sol_cli_report.app "  whoami shape: parsed (identity source: %s)" source;
         let matched = principal_matches ~expected identity in
         let named =
           match identity.canonical_arn, identity.arn with
           | Some a, _ -> a
           | None, Some a -> a
           | None, None -> "(unnamed)"
         in
         (match matched with
          | Some false ->
            fail
              (Printf.sprintf
                 "the authorizer answered as a different principal than the provisioner \
                  whose elevation this run manages (%s, from %s). The run stops here: \
                  the de-escalation comparison would be about somebody else."
                 named
                 source)
          | None -> fail "the authorizer's answer named no principal at all"
          | Some true ->
            if source <> "extra.canonicalArn" && source <> "userInfo.canonicalArn"
            then
              fail
                (Printf.sprintf
                   "the principal came from %s rather than canonicalArn, which is the \
                    field the de-escalation comparison depends on. The run stops rather \
                    than validating a path the verification does not use. Raw response: \
                    %s"
                   source
                   json)
            else Ok ()))
    | Error why ->
      if remaining <= 1
      then
        fail
          (Printf.sprintf
             "the authorizer could not be reached to check the whoami shape (%s). The \
              gate not having run is a failure, not a pass: the run stops before the \
              platform install rather than discovering an unreadable shape at \
              de-escalation."
             why)
      else (
        Sol_cli_report.app
          "  whoami shape: not reachable yet (%s); retrying in %.0fs"
          why
          interval_s;
        Unix.sleepf interval_s;
        attempt (remaining - 1))
  in
  attempt cluster_propagation_attempts
;;

let await_deescalation ~region ~outputs ~window_role_arn ~assumable_role_arn ~before =
  let open Result.Syntax in
  let* interval_s = whoami_retry_interval_s () in
  let rec loop remaining =
    let principal, probes =
      deescalation_probe ~region ~outputs ~window_role_arn ~assumable_role_arn ()
    in
    let verdict =
      Sol_cli_cloud_lifecycle.deescalation_transition
        ~before
        ~after_principal:principal
        ~after:probes
    in
    match verdict with
    | Sol_cli_cloud_lifecycle.Deescalated -> Ok ()
    | _ when remaining <= 1 ->
      Error (Sol_cli_cloud_lifecycle.deescalation_verdict_to_string verdict)
    | verdict ->
      Sol_cli_report.app
        "  awaiting effective de-escalation: %s"
        (Sol_cli_cloud_lifecycle.deescalation_verdict_to_string verdict);
      Unix.sleepf interval_s;
      loop (remaining - 1)
  in
  loop deescalation_attempts
;;

let deescalation_principal_to_string = function
  | Sol_cli_cloud_lifecycle.Principal_confirmed arn -> "confirmed " ^ arn
  | Sol_cli_cloud_lifecycle.Principal_refused_by_cluster why ->
    "refused by the cluster: " ^ why
  | Sol_cli_cloud_lifecycle.Principal_probe_failed why -> "no evidence: " ^ why
  | Sol_cli_cloud_lifecycle.Principal_unexpected who -> "unexpected " ^ who
;;

let capability_answer_to_string = function
  | Sol_cli_cloud_lifecycle.Permitted -> "permitted"
  | Sol_cli_cloud_lifecycle.Denied -> "denied"
  | Sol_cli_cloud_lifecycle.Indeterminate why -> "indeterminate: " ^ why
;;

let window_control_failure = Sol_cli_bootstrap_window.control_failure

let observe_bootstrap_window_result
      ~region
      ~outputs
      ~window_role_arn
      ~assumable_role_arn
      ()
  =
  let open Result.Syntax in
  let* interval_s = whoami_retry_interval_s () in
  let rec attempt remaining =
    let control =
      deescalation_probe ~region ~outputs ~window_role_arn ~assumable_role_arn ()
    in
    let principal, probes = control in
    let permitted =
      probes
      |> List.exists (fun (_, answer) ->
        Sol_cli_cloud_lifecycle.answer_is_permitted answer)
    in
    let indeterminate =
      List.filter_map Sol_cli_cloud_lifecycle.indeterminate_reason probes
    in
    match permitted, indeterminate with
    | true, [] ->
      Sol_cli_report.app
        "  bootstrap window control: principal=%s; %s"
        (deescalation_principal_to_string principal)
        (probes
         |> List.map (fun (capability, answer) ->
           Printf.sprintf
             "%s=%s"
             (Sol_cli_cloud_lifecycle.capability_label capability)
             (capability_answer_to_string answer))
         |> String.concat ", ");
      Ok control
    | _ ->
      if remaining <= 1
      then Error (window_control_failure ~permitted indeterminate)
      else (
        Sol_cli_report.app
          "  bootstrap window control: not yet permitted; retrying in %.0fs"
          interval_s;
        Unix.sleepf interval_s;
        attempt (remaining - 1))
  in
  attempt cluster_propagation_attempts
;;

let aws_cloud_ready ~region outputs =
  let cluster = outputs.cluster_name in
  let status args =
    Sol_cli_cluster.process_output ([ "aws" ] @ args @ [ "--region"; region ])
  in
  match
    ( status
        [ "eks"
        ; "describe-cluster"
        ; "--name"
        ; cluster
        ; "--query"
        ; "cluster.status"
        ; "--output"
        ; "text"
        ]
    , status
        [ "eks"
        ; "describe-addon"
        ; "--cluster-name"
        ; cluster
        ; "--addon-name"
        ; "aws-ebs-csi-driver"
        ; "--query"
        ; "addon.status"
        ; "--output"
        ; "text"
        ] )
  with
  | Some cluster_status, Some addon_status
    when String.trim cluster_status = "ACTIVE" && String.trim addon_status = "ACTIVE" ->
    true
  | _ -> false
;;

let database_egress_cidrs_json outputs =
  match outputs.database_egress_cidrs with
  | [] -> None
  | cidrs ->
    Some (`List (List.map (fun cidr -> `String cidr) cidrs) |> Yojson.Safe.to_string)
;;

let platform_vars outputs _context ~cluster_issuer:_ ~region =
  Ok
    { Sol_cli_cluster.fixed =
        [ "cloud_provider=aws"
        ; "aws_region=" ^ region
        ; "cert_manager_irsa_role_arn=" ^ outputs.cert_manager_irsa_role_arn
        ; "managed_resource_dashboards="
          ^ Yojson.Safe.to_string outputs.managed_resource_dashboards
        ]
    ; optional =
        [ "loki_s3_bucket", outputs.loki_s3_bucket
        ; "loki_irsa_role_arn", outputs.loki_irsa_role_arn
        ; "thanos_s3_bucket", outputs.thanos_s3_bucket
        ; "thanos_irsa_role_arn", outputs.thanos_irsa_role_arn
        ; "grafana_irsa_role_arn", outputs.grafana_irsa_role_arn
        ; "database_egress_cidrs", database_egress_cidrs_json outputs
        ]
    }
;;

let label = "AWS"
let of_outputs_json = aws_outputs_of_json

let cluster ~region ~provisioner_role_arn ~deploy_role_arn outputs : Sol_cli_cluster.t =
  { name = outputs.cluster_name
  ; check_identity =
      (fun ~cluster_access_role_arn ->
        match cluster_access_role_arn with
        | Some arn when arn <> outputs.cluster_access_role_arn ->
          Error "AWS cluster_access_role_arn output does not match the validated target"
        | _ -> Ok ())
  ; platform_vars = platform_vars outputs
  ; with_access =
      (fun f -> provisioner_kubeconfig ~region outputs (fun env -> f ~env) |> Result.join)
  ; ready = (fun () -> aws_cloud_ready ~region outputs)
  ; deploy_access = (fun () -> deploy_access ~region outputs ~deploy_role_arn ())
  ; bootstrap_window =
      (let window_role_arn = outputs.cluster_access_role_arn in
       let assumable_role_arn = Option.value ~default:"" provisioner_role_arn in
       if Sol_cli_string.is_blank window_role_arn
       then Sol_cli_cluster.No_role_declared
       else (
         let before = ref [] in
         Sol_cli_cluster.Verified
           { principal = window_role_arn
           ; gate = (fun () -> verify_whoami_shape ~region ~outputs ~window_role_arn)
           ; observe =
               (fun () ->
                 let open Result.Syntax in
                 let* _, probes =
                   observe_bootstrap_window_result
                     ~region
                     ~outputs
                     ~window_role_arn
                     ~assumable_role_arn
                     ()
                 in
                 before := probes;
                 Ok ())
           ; deescalated =
               (fun () ->
                 await_deescalation
                   ~region
                   ~outputs
                   ~window_role_arn
                   ~assumable_role_arn
                   ~before:!before)
           ; successor =
               (fun () ->
                 match successor_probe ~region ~outputs () with
                 | Error why ->
                   Error
                     (Printf.sprintf
                        "the durable cluster-access identity could not be probed for the \
                         authority the lifecycle needs next: %s"
                        why)
                 | Ok probes ->
                   (match Sol_cli_cloud_lifecycle.successor_authority probes with
                    | Ok () -> Ok ()
                    | Error why ->
                      Error
                        (Printf.sprintf
                           "the durable cluster-access identity was not demonstrated to \
                            hold the authority the lifecycle needs next: %s"
                           why)))
           }))
  }
;;

let credentials ~operation ~leaves_target_standing : (unit, string) result =
  let profile = Sol_cli_string.env "AWS_PROFILE" in
  match Sol_cli_aws_credentials.resolve ~run:Sol_cli_cluster.process_output ~profile with
  | Error detail ->
    Error
      (Sol_cli_aws_credentials.unresolved_message
         ~operation
         ~profile
         ~leaves_target_standing
         ~detail)
  | Ok credentials ->
    Sol_cli_aws_credentials.install credentials;
    Sol_cli_report.app "  credentials: %s" credentials.principal;
    Ok ()
;;
