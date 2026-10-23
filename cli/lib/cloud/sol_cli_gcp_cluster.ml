(* Shared by generation decisions and native ownership/recovery attribution. *)
let kafka_authority_resources : Sol_cli_kafka_authority.authority_resources =
  { secret = "google_secret_manager_secret.kafka[0]"
  ; version = "google_secret_manager_secret_version.kafka[0]"
  }
;;

open Result.Syntax

let service_account_id_min_length = 6
let service_account_id_max_length = 30
let account_id_suffixes = [ "-cert-manager"; "-provisioner"; "-thanos"; "-loki" ]

let longest_account_id_suffix =
  List.fold_left
    (fun longest suffix ->
       if String.length suffix > String.length longest then suffix else longest)
    ""
    account_id_suffixes
;;

let valid_service_account_id id =
  let length = String.length id in
  length >= service_account_id_min_length
  && length <= service_account_id_max_length
  && (match id.[0] with
      | 'a' .. 'z' -> true
      | _ -> false)
  && (match id.[length - 1] with
      | 'a' .. 'z' | '0' .. '9' -> true
      | _ -> false)
  && String.for_all
       (function
         | 'a' .. 'z' | '0' .. '9' | '-' -> true
         | _ -> false)
       id
;;

let validate_cluster_name cluster_name =
  match
    List.find_opt
      (fun suffix -> not (valid_service_account_id (cluster_name ^ suffix)))
      account_id_suffixes
  with
  | None -> Ok ()
  | Some suffix ->
    let account_id = cluster_name ^ suffix in
    Error
      (Printf.sprintf
         "GCP service-account ids must be %d-%d characters and match \
          ^[a-z](?:[-a-z0-9]{4,28}[a-z0-9])$, but cluster name %S derives the account id \
          %S (%d characters) by appending %S. Shorten the cluster name to at most %d \
          characters; the longest suffix a derived id appends is %S."
         service_account_id_min_length
         service_account_id_max_length
         cluster_name
         account_id
         (String.length account_id)
         suffix
         (service_account_id_max_length - String.length longest_account_id_suffix)
         longest_account_id_suffix)
;;

type gcp_outputs =
  { cluster_name : string
  ; project_id : string
  ; region : string
  ; artifact_registry : string
  ; loki_gcs_bucket : string option
  ; loki_workload_identity_sa_email : string option
  ; thanos_gcs_bucket : string option
  ; thanos_workload_identity_sa_email : string option
  ; cert_manager_workload_identity_sa_email : string option
  ; provisioner_service_account : string
  ; database_egress_cidrs : string list
  ; (* See the AWS counterpart: null when no database was created. *)
    postgres_url : string option
  ; (* The trust anchor a client needs for this provider's sslmode; Cloud SQL's per-instance
       server CA. Null when no database was created. See the AWS counterpart. *)
    postgres_ca_cert : string option
  ; kafka_authority : string option
  }

let gcp_outputs_of_json text =
  let open Result.Syntax in
  let* value, string, optional_string =
    Sol_cli_cluster.outputs_reader ~provider:"GCP" text
  in
  let* kafka_authority = Sol_cli_kafka_authority.reference_output text in
  let* cluster_name = string "cluster_name" in
  let* project_id = string "project_id" in
  let* region = string "region" in
  let* artifact_registry = string "artifact_registry" in
  let* loki_gcs_bucket = optional_string "loki_gcs_bucket" in
  let* loki_workload_identity_sa_email =
    optional_string "loki_workload_identity_sa_email"
  in
  let* thanos_gcs_bucket = optional_string "thanos_gcs_bucket" in
  let* thanos_workload_identity_sa_email =
    optional_string "thanos_workload_identity_sa_email"
  in
  let* cert_manager_workload_identity_sa_email =
    optional_string "cert_manager_workload_identity_sa_email"
  in
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
    | _ -> Error "GCP Terraform output \"database_egress_cidrs\" is not a list of strings"
  in
  let* provisioner_service_account = string "provisioner_service_account" in
  let* postgres_url = optional_string "postgres_url" in
  let* postgres_ca_cert = optional_string "postgres_ca_cert" in
  Ok
    { cluster_name
    ; project_id
    ; region
    ; artifact_registry
    ; loki_gcs_bucket
    ; loki_workload_identity_sa_email
    ; thanos_gcs_bucket
    ; thanos_workload_identity_sa_email
    ; cert_manager_workload_identity_sa_email
    ; provisioner_service_account
    ; database_egress_cidrs
    ; postgres_url
    ; postgres_ca_cert
    ; kafka_authority
    }
;;

let gcp_platform_toolchain_result () : (unit, string) result =
  match
    Sol_cli_process.run (Sol_cli_process.cmd [ "gke-gcloud-auth-plugin"; "--version" ])
  with
  | Ok _ -> Ok ()
  | _ ->
    Error
      "the platform cannot reach a GKE cluster without `gke-gcloud-auth-plugin`, which \
       is not on PATH: the kubeconfig gcloud writes names it as its credential plugin, \
       so every Kubernetes call would fail with \"executable gke-gcloud-auth-plugin not \
       found\". Install it (`gcloud components install gke-gcloud-auth-plugin`) and \
       re-run. Nothing has been changed."
;;

let gcp_provisioner_kubeconfig_result
      ~region
      outputs
      (f : env:(string * string) list -> ('a, string) result)
  : ('a, string) result
  =
  let* () = gcp_platform_toolchain_result () in
  let path = Filename.temp_file "sol-platform-provisioner-" ".kubeconfig" in
  let cleanup () = Sol_cli_fs.remove_reporting path in
  at_exit cleanup;
  Fun.protect ~finally:cleanup (fun () ->
    let env = Sol_cli_cluster.provisioner_kube_env path in
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           ~env
           [ "gcloud"
           ; "container"
           ; "clusters"
           ; "get-credentials"
           ; outputs.cluster_name
           ; "--region"
           ; region
           ; "--project"
           ; outputs.project_id
           ; "--impersonate-service-account"
           ; outputs.provisioner_service_account
           ; "--quiet"
           ])
    with
    | Ok _ -> f ~env
    | Error (Sol_cli_process.Non_zero result) ->
      Error
        (Printf.sprintf
           "could not establish ephemeral cluster access as %s: gcloud exited %d%s"
           outputs.provisioner_service_account
           result.exit_code
           (let detail = String.trim result.stderr in
            if detail = "" then "" else ":\n" ^ detail))
    | Error error ->
      Error
        (Printf.sprintf
           "could not run gcloud to establish cluster access: %s"
           (Sol_cli_process.error_to_string error)))
;;

let gcp_cloud_ready outputs =
  let project = outputs.project_id in
  let region = outputs.region in
  let cluster = outputs.cluster_name in
  let status argv = Sol_cli_cluster.process_output ([ "gcloud" ] @ argv) in
  match
    ( status
        [ "container"
        ; "clusters"
        ; "describe"
        ; cluster
        ; "--region"
        ; region
        ; "--project"
        ; project
        ; "--format"
        ; "value(status)"
        ]
    , status
        [ "sql"
        ; "instances"
        ; "describe"
        ; cluster ^ "-postgres"
        ; "--project"
        ; project
        ; "--format"
        ; "value(state)"
        ] )
  with
  | Some cluster_status, Some sql_state
    when String.trim cluster_status = "RUNNING" && String.trim sql_state = "RUNNABLE" ->
    true
  | _ -> false
;;

let deploy_access ~region (outputs : gcp_outputs) () =
  let open Result.Syntax in
  let* () = gcp_platform_toolchain_result () in
  let path = Filename.temp_file "sol-gcp-deploy-" ".kubeconfig" in
  at_exit (fun () -> Sol_cli_fs.remove_reporting path);
  gcp_provisioner_kubeconfig_result ~region outputs (fun ~env ->
    let run args =
      Sol_cli_process.run (Sol_cli_process.cmd ~env args)
      |> Result.map (fun (output : Sol_cli_process.output) -> output.stdout)
      |> Result.map_error Sol_cli_process.error_to_string
    in
    let* token =
      run
        [ "kubectl"
        ; "create"
        ; "token"
        ; "sol-deploy"
        ; "-n"
        ; "monitoring"
        ; "--duration=1h"
        ]
    in
    let* cluster =
      run [ "kubectl"; "config"; "view"; "-o"; "jsonpath={.clusters[0].name}" ]
    in
    let cluster = String.trim cluster in
    if cluster = ""
    then Error "the GCP provisioner kubeconfig names no cluster for the deploy context"
    else (
      let provisioner_kubeconfig =
        match List.assoc_opt "KUBECONFIG" env with
        | Some value when not (Sol_cli_string.is_blank value) -> value
        | _ -> ""
      in
      if provisioner_kubeconfig = ""
      then Error "the GCP provisioner kubeconfig has no KUBECONFIG path"
      else
        let* provisioner_kubeconfig = Sol_cli_fs.read_file provisioner_kubeconfig in
        let* () = Sol_cli_fs.write_atomic ~perm:0o600 path provisioner_kubeconfig in
        let token = String.trim token in
        let* _ =
          run
            [ "kubectl"
            ; "config"
            ; "set-credentials"
            ; "sol-deploy"
            ; "--token"
            ; token
            ; "--kubeconfig"
            ; path
            ]
        in
        let* _ =
          run
            [ "kubectl"
            ; "config"
            ; "set-context"
            ; "sol-deploy"
            ; "--cluster"
            ; cluster
            ; "--user"
            ; "sol-deploy"
            ; "--kubeconfig"
            ; path
            ]
        in
        Sol_cli_kube_destination.of_context ~kubeconfig:path "sol-deploy"
        |> Result.map Option.some))
;;

let database_egress_cidrs_json outputs =
  match outputs.database_egress_cidrs with
  | [] -> None
  | cidrs ->
    Some (`List (List.map (fun cidr -> `String cidr) cidrs) |> Yojson.Safe.to_string)
;;

let platform_vars outputs context ~cluster_issuer:_ ~region:_ =
  Ok
    { Sol_cli_cluster.fixed = [ "cloud_provider=gcp"; "storage_class_name=standard-rwo" ]
    ; optional =
        [ ( "kafka_authority"
          , match context with
            | Sol_cli_cluster.Install -> outputs.kafka_authority
            | Destruction -> None )
        ; "loki_gcs_bucket", outputs.loki_gcs_bucket
        ; "loki_workload_identity_sa_email", outputs.loki_workload_identity_sa_email
        ; "thanos_gcs_bucket", outputs.thanos_gcs_bucket
        ; "thanos_workload_identity_sa_email", outputs.thanos_workload_identity_sa_email
        ; ( "cert_manager_workload_identity_sa_email"
          , outputs.cert_manager_workload_identity_sa_email )
        ; "database_egress_cidrs", database_egress_cidrs_json outputs
        ; "cert_manager_dns01_project", Some outputs.project_id
        ; "gcp_provisioner_service_account", Some outputs.provisioner_service_account
        ]
    }
;;

let label = "GCP"
let of_outputs_json = gcp_outputs_of_json

let probe_bootstrap ~region ~outputs () =
  gcp_provisioner_kubeconfig_result ~region outputs (fun ~env ->
    Ok
      (Sol_cli_bootstrap_window.probe
         ~run:(fun argv -> Sol_cli_process.run (Sol_cli_process.cmd ~env argv))
         Sol_cli_bootstrap_window.bootstrap_only))
;;

let probe_successor ~region ~outputs () =
  gcp_provisioner_kubeconfig_result ~region outputs (fun ~env ->
    Ok
      (Sol_cli_bootstrap_window.probe
         ~run:(fun argv -> Sol_cli_process.run (Sol_cli_process.cmd ~env argv))
         Sol_cli_bootstrap_window.successor))
;;

(* Establish that the temporary installation window is effective before the
   privileged platform apply, so a window that did not take effect is reported
   as a missing window rather than discovered as a Kubernetes RBAC denial
   inside the apply. *)
let bootstrap_window_control ~region ~outputs () =
  let open Result.Syntax in
  let* probes = probe_bootstrap ~region ~outputs () in
  let permitted = Sol_cli_bootstrap_window.permitted probes in
  let indeterminate = Sol_cli_bootstrap_window.indeterminate probes in
  match permitted, indeterminate with
  | true, [] ->
    Sol_cli_report.app
      "  bootstrap window control: provisioner %s holds a bootstrap-only capability"
      outputs.provisioner_service_account;
    Ok probes
  | _ -> Error (Sol_cli_bootstrap_window.control_failure ~permitted indeterminate)
;;

let cluster ~region outputs : Sol_cli_cluster.t =
  let before = ref [] in
  { name = outputs.cluster_name
  ; check_identity = (fun ~cluster_access_role_arn:_ -> Ok ())
  ; platform_vars = platform_vars outputs
  ; with_access = (fun f -> gcp_provisioner_kubeconfig_result ~region outputs f)
  ; ready = (fun () -> gcp_cloud_ready outputs)
  ; bootstrap_window =
      Sol_cli_cluster.Verified
        { principal = outputs.provisioner_service_account
        ; gate =
            (fun () -> Result.map ignore (bootstrap_window_control ~region ~outputs ()))
        ; observe =
            (fun () ->
              let open Result.Syntax in
              let* probes = probe_bootstrap ~region ~outputs () in
              before := probes;
              Ok ())
        ; deescalated =
            (fun () ->
              let open Result.Syntax in
              let* after = probe_bootstrap ~region ~outputs () in
              match
                Sol_cli_capability.deescalation_transition
                  ~before:!before
                  ~after_principal:
                    (Sol_cli_capability.Principal_confirmed
                       outputs.provisioner_service_account)
                  ~after
              with
              | Sol_cli_capability.Deescalated -> Ok ()
              | verdict ->
                Error (Sol_cli_capability.deescalation_verdict_to_string verdict))
        ; successor =
            (fun () ->
              match probe_successor ~region ~outputs () with
              | Error why ->
                Error
                  (Printf.sprintf
                     "the durable cluster-access identity could not be probed for the \
                      authority the lifecycle needs next: %s"
                     why)
              | Ok probes ->
                (match Sol_cli_capability.successor_authority probes with
                 | Ok () -> Ok ()
                 | Error why ->
                   Error
                     (Printf.sprintf
                        "the durable cluster-access identity was not demonstrated to \
                         hold the authority the lifecycle needs next: %s"
                        why)))
        }
  ; deploy_access = (fun () -> deploy_access ~region outputs ())
  }
;;

let credentials ~operation ~leaves_target_standing : (unit, string) result =
  let standing_remark =
    if leaves_target_standing
    then
      " The target is still standing and may still be billing; nothing has been changed."
    else " Nothing has been changed."
  in
  match
    Sol_cli_cluster.process_output
      [ "gcloud"; "auth"; "application-default"; "print-access-token" ]
  with
  | Some _ ->
    Sol_cli_report.app "  credentials: Google Application Default Credentials resolved";
    Ok ()
  | None ->
    Error
      (Printf.sprintf
         "cannot resolve Google Application Default Credentials, so Sol cannot \
          %s              this target.%s Run `gcloud auth application-default login` (or \
          fix the              attached service account) and re-run."
         operation
         standing_remark)
;;

let project_id_of_outputs_json text : (string, string) result =
  Sol_cli_cluster.outputs_reader ~provider:"GCP" text
  |> Fun.flip Result.bind (fun (_raw, string, _optional_string) -> string "project_id")
;;

let autopilot_of_describe_json text : (bool, string) result =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error message ->
    (* Keep the provider's own answer beside the parse failure: the describe is
       small (it is projected), and a reader needs to see what came back. *)
    Error (Printf.sprintf "the describe output is not JSON (%s): %s" message text)
  | json ->
    (match Sol_cli_json.assoc (Sol_cli_json.field [ "autopilot" ] json) with
     | None ->
       Error
         (Printf.sprintf
            "the cluster describe carries no autopilot field: %s"
            (Yojson.Safe.to_string json))
     | Some fields ->
       (match List.assoc_opt "enabled" fields with
        | None ->
          (* GKE encodes a standard cluster as an *empty* `autopilot` object:
             the field is present and the provider writes no `enabled` into it
             (observed on a cluster this provider created: `{"autopilot":{}}`).
             An Autopilot cluster always reports `enabled: true`, so an empty
             object is the provider's encoding of standard, not an unreadable
             mode. A describe with the field absent altogether, or with an
             `enabled` that is not a boolean, is still refused. *)
          Ok false
        | Some enabled ->
          (match Sol_cli_json.bool enabled with
           | Some value -> Ok value
           | None ->
             Error
               (Printf.sprintf
                  "the cluster describe's autopilot.enabled is not a boolean: %s"
                  (Yojson.Safe.to_string enabled)))))
;;

let substrate_of_describe ~outputs_json ~region ~cluster_name
  : (Sol_cli_cluster_substrate.t, string) result
  =
  let open Sol_cli_cluster_substrate in
  let project =
    match project_id_of_outputs_json outputs_json with
    | Ok project -> project
    | Error _ -> ""
  in
  if project = ""
  then Ok (Unknown "the cloud root's outputs carry no project to read the cluster from")
  else (
    let cmd =
      Sol_cli_process.cmd
        [ "gcloud"
        ; "container"
        ; "clusters"
        ; "describe"
        ; cluster_name
        ; "--region"
        ; region
        ; "--project"
        ; project
        ; "--format=json(autopilot.enabled)"
        ]
    in
    match Sol_cli_process.run ~echo:false cmd with
    | Ok output ->
      (match autopilot_of_describe_json output.Sol_cli_process.stdout with
       | Ok true -> Ok Autopilot
       | Ok false -> Ok Standard
       | Error message ->
         (* Name the read that failed and the resource it failed on: the caller
            only knows "the existing cluster", which is not enough to act on. *)
         Ok
           (Unknown
              (Printf.sprintf
                 "reading the mode of cluster %s in %s (project %s): %s"
                 cluster_name
                 region
                 project
                 message)))
    | Error (Sol_cli_process.Non_zero failure) ->
      let said =
        String.trim (failure.Sol_cli_process.stderr ^ failure.Sol_cli_process.stdout)
      in
      if Sol_cli_gcloud.says_not_found said
      then Ok Absent
      else
        Ok
          (Unknown
             (if said = ""
              then
                Printf.sprintf
                  "the provider reported exit %d"
                  failure.Sol_cli_process.exit_code
              else said))
    | Error error -> Ok (Unknown (Sol_cli_process.error_to_string error)))
;;
