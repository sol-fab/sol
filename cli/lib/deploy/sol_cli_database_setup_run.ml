(** The database setup phase — ADR 0007.

    **Three objects, three lifetimes.** Applying them as one list and deleting that list
    would either destroy the DDL/DML credentials 2b consumes or leave the master alive
    after the Job:

    | Object          | Applied     | Owner                | Deleted                    |
    |-----------------|-------------|----------------------|----------------------------|
    | output Secrets  | before Job  | Sol, no ownerRef     | **never** — 2b consumes them |
    | transient Secret| before Job  | patched Job ownerRef | after the Job (long or short) |
    | script ConfigMap| before Job  | Sol                  | after the Job              |

    **Per target, not per unit.** There is one database per target, so this runs once
    per plan and not once per spec: run it from the plan-level runner, never from
    [apply_workload_phased], which is per-spec and would start one Job per consuming
    unit against a single database.

    **Write ordering.** Sol is the sole password authority and writes the output Secrets
    before the Job starts, so a failed Job leaves credentials present-but-unused and a
    re-run overwrites them.

    **Re-deploy: delete, then create.** A Job's pod template is immutable, so "run every
    deploy" cannot be a patch; the existing Job is removed before the new one is applied.
    That also makes a changed script, image or volume a re-create by construction. *)

open Result.Syntax

let kubectl ~ctx ?(timeout_s = 30.) args = Sol_cli_kubectl.run ~timeout_s ~ctx args

let apply_doc ~ctx ~what doc =
  Sol_cli_fs.with_temp_file
    ~prefix:"sol-db-setup-"
    ~suffix:".yaml"
    (Sol_cli_yaml.render [ doc ])
    (fun file ->
       Sol_cli_kubectl.apply ~ctx ~file
       |> Result.map_error (fun e ->
         Printf.sprintf "kubectl apply (%s): %s" what (Sol_cli_process.error_to_string e)))
  |> Result.join
;;

(** The Job's UID, read back immediately after creation so the transient Secret can be
    given an owner. *)
let job_uid ~ctx ~namespace ~job_name =
  let* r =
    kubectl
      ~ctx
      ~timeout_s:15.
      [ "get"; "job"; job_name; "-n"; namespace; "-o"; "jsonpath={.metadata.uid}" ]
    |> Result.map_error (fun e ->
      Printf.sprintf "kubectl get job (uid): %s" (Sol_cli_process.error_to_string e))
  in
  match Sol_cli_string.non_blank r.Sol_cli_process.stdout with
  | Some uid -> Ok uid
  | None -> Error (Printf.sprintf "job %s/%s has no uid" namespace job_name)
;;

(** Give the transient Secret an owner, so that anything which deletes the Job — the
    cascade, or the TTL backstop while Sol is not running — collects the Secret too.

    **The crash window is real and is not hidden by this call:** Sol can die between
    creating the Job and patching the Secret, and then nothing owns the Secret. It is
    deleted explicitly below on the normal path; if Sol dies before that, it survives
    until the next deploy of the same target replaces it. *)
let own_secret_with_job ~ctx ~namespace ~job_name ~secret_name =
  let* uid = job_uid ~ctx ~namespace ~job_name in
  (* Built as a value rather than as a JSON string: the repository guards against
     hand-built manifest text, and a patch is manifest text. *)
  let patch =
    `Assoc
      [ ( "metadata"
        , `Assoc
            [ ( "ownerReferences"
              , `List
                  [ `Assoc
                      [ "apiVersion", `String "batch/v1"
                      ; "kind", `String "Job"
                      ; "name", `String job_name
                      ; "uid", `String uid
                      ]
                  ] )
            ] )
      ]
    |> Yojson.Safe.to_string
  in
  kubectl
    ~ctx
    [ "patch"; "secret"; secret_name; "-n"; namespace; "--type=merge"; "-p"; patch ]
  |> Result.map_error (fun e ->
    Printf.sprintf "kubectl patch secret (owner): %s" (Sol_cli_process.error_to_string e))
  |> Result.map (fun _ -> ())
;;

(** Best effort, and the code says so: a failure here is a warning, not an error. The
    cost differs by object, so the caller passes the consequence rather than the operation.
    For the script it is nothing. For the transient Secret it is the master surviving
    until the next deploy of this target — or until the Job's [ttlSecondsAfterFinished]
    cascade collects it, if the owner reference was patched before Sol died — and the
    warning says that, because a reader needs the risk, not the failed verb. *)
let delete ~ctx ~namespace ~what ?risk name =
  let warn reason =
    match risk with
    | Some risk -> Sol_cli_report.warn "warning: %s (%s)" risk reason
    | None ->
      Sol_cli_report.warn "warning: could not delete %s/%s: %s" namespace name reason
  in
  (* This runs from [~finally], where an exception would replace the phase's own error
     with a cleanup error and hide what actually went wrong. *)
  try
    kubectl
      ~ctx
      [ "delete"; what; name; "-n"; namespace; "--ignore-not-found"; "--wait=false" ]
    |> Result.iter_error (fun e -> warn (Sol_cli_process.error_to_string e))
  with
  | exn -> warn (Printexc.to_string exn)
;;

(** Delete exactly what the Job owned: the Job, its script, and the transient Secret.
    The output Secrets are deliberately **not** here — 2b delivers them. *)
let cleanup ~ctx ~namespace ~job_name ~configmap_name ~secret_name =
  (* [delete] already swallows its own exceptions. This wraps the whole body anyway:
     this function runs from [~finally], where anything that escapes replaces the phase's
     own error with a cleanup error and hides the real cause. *)
  try
    delete ~ctx ~namespace ~what:"job" job_name;
    delete ~ctx ~namespace ~what:"configmap" configmap_name;
    delete
      ~ctx
      ~namespace
      ~what:"secret"
      ~risk:
        (Printf.sprintf
           "the database master credential may still be present at Secret %s/%s"
           namespace
           secret_name)
      secret_name
  with
  | exn -> Sol_cli_report.warn "warning: cleanup raised: %s" (Printexc.to_string exn)
;;

(** The namespaces that must receive the DML credential: one per unit that declares it
    uses the Sol-provisioned `postgres` resource.

    This is the declared signal, not a resolved one. Deriving consumers from
    `POSTGRES_URL` in a unit's resolved secrets would not work today: `default_secrets`
    still adds `POSTGRES_URL` to *every* unit, so that enumeration would name every
    namespace. It becomes meaningful only after 2b — and 2b is what consumes these
    Secrets, so the resolved signal cannot be what gates them.

    It names the resource, not the type, so a consumer of a *different*, externally bound
    postgres resource is not handed a Sol-written credential: the external database is
    responsible for its own roles, and only the Sol-provisioned one's consumers get the DML
    credential. That ownership resolution already exists
    ([Sol_cli_resource_binding.provisions]); this asks it once and passes the name. *)
let dml_namespaces ~declared ~resource (plan : Sol_cli_deployment_plan.t) =
  plan.Sol_cli_deployment_plan.services
  |> List.filter (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Sol_cli_deployment_plan.service_uses_resource declared spec.source_name resource)
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Sol_cli_deployment_plan.namespace_to_string spec.namespace)
  |> List.sort_uniq String.compare
;;

let wait_interval_s = 2.

(** 300s, matching the migration Job ([cmd_migrate], [Sol_cli_contract]) rather than the
    migration *gate*'s 120s: this runs DDL against the database, the same class of work,
    and a false timeout fails a deploy that was about to succeed. *)
let wait_attempts = 150

let run
      ~ctx
      ~namespace
      ~target
      ~master_url
      ~ddl_password
      ~dml_password
      ~image
      ~output_secrets
  =
  let module Render = Sol_cli_database_setup_render in
  let job_name = Render.job_name target in
  let secret_name = Render.secret_name target in
  let configmap_name = Render.script_name target in
  let job =
    Sol_cli_migration_job.{ namespace; job_name; configmap_name = Some configmap_name }
  in
  let transient =
    Render.transient_secret_doc
      ~ns:namespace
      ~target
      ~master_url
      ~ddl_password
      ~dml_password
  in
  let script = Render.script_configmap_doc ~ns:namespace ~target in
  let job_doc = Render.job_doc ~ns:namespace ~target ~image in
  (* Re-deploy: a Job's pod template is immutable, so an existing one is removed rather
     than patched. A first deploy finds nothing and this is a no-op. Deliberately outside
     the [Fun.protect] below: nothing has been created yet, so there is nothing this call
     can leak. *)
  delete ~ctx ~namespace ~what:"job" job_name;
  (* Every path from the first apply runs [cleanup], including every early return. A
     [let*] chain that returned early would leave the transient Secret — the master — in
     the cluster with no owner and no later delete, which is the exact leak this step
     exists to prevent. The failure that matters most is [own_secret_with_job] failing:
     the Job exists, the Secret is not owned by it, and only this [finally] collects it. *)
  Fun.protect
    ~finally:(fun () -> cleanup ~ctx ~namespace ~job_name ~configmap_name ~secret_name)
    (fun () ->
       (* Sol writes, before the Job runs, both the credentials the Job *consumes* (the
         transient Secret) and the credentials consumers will consume (the output
         Secrets). The Job produces the roles those credentials belong to; it does not
         receive them. *)
       let* () =
         List.fold_left
           (fun acc (what, doc) ->
              let* () = acc in
              apply_doc ~ctx ~what doc)
           (Ok ())
           ([ "transient secret", transient; "setup script", script ]
            @ List.map (fun doc -> "output secret", doc) output_secrets)
       in
       let* () = apply_doc ~ctx ~what:"setup job" job_doc in
       let* () = own_secret_with_job ~ctx ~namespace ~job_name ~secret_name in
       let outcome =
         Sol_cli_migration_job.wait
           ~ctx
           ~interval_s:wait_interval_s
           ~attempts:wait_attempts
           job
       in
       match outcome with
       | Sol_cli_migration_job.Succeeded -> Ok ()
       | Sol_cli_migration_job.Failed ->
         Error
           (Printf.sprintf
              "database setup for target %s failed; the roles were not created"
              namespace)
       | Sol_cli_migration_job.Timed_out _ ->
         Error
           (Printf.sprintf
              "database setup for target %s timed out; the roles may be partially created"
              namespace)
       | Sol_cli_migration_job.Unstartable { reason; detail } ->
         Error
           (Printf.sprintf
              "database setup for target %s could not start: %s%s"
              namespace
              reason
              (match detail with
               | Some d -> " (" ^ d ^ ")"
               | None -> "")))
;;
