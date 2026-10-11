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

(** The target's recorded DDL and DML passwords. *)
type authority =
  { ddl_password : string
  ; dml_password : string
  }

(** Read the authority back from the cluster.

    [Ok None] is a first deploy — nothing recorded yet. A Secret that exists but does not
    carry both values is an **error, not a bootstrap**: treating it as one would generate a
    replacement password for a role that already exists, silently invalidating what its
    consumers hold.

    The values are decoded by kubectl's [base64decode] rather than in Sol, because the
    Secret's stored form is base64 and nothing here should grow a second encoding. *)
let read_authority ~ctx ~namespace ~target =
  let name = Sol_cli_database_setup_render.authority_name target in
  let template =
    "{{index .data \"SOL_DDL_PASSWORD\" | base64decode}}{{\"\\n\"}}{{index .data \
     \"SOL_DML_PASSWORD\" | base64decode}}"
  in
  let unreadable detail =
    Printf.sprintf
      "could not read the target's password authority (Secret %s in namespace %s): %s. \
       The authority is what makes this deploy a repair rather than a rotation, so Sol \
       will not continue past a value it cannot read."
      name
      namespace
      detail
  in
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:[ "get"; "secret"; name; "-n"; namespace; "-o"; "go-template=" ^ template ]
  with
  | Error e -> Error (unreadable (Sol_cli_process.error_to_string e))
  | Ok None -> Ok None
  | Ok (Some text) ->
    (match String.split_on_char '\n' (String.trim text) with
     | [ ddl_password; dml_password ]
       when (not (Sol_cli_string.is_blank ddl_password))
            && not (Sol_cli_string.is_blank dml_password) ->
       Ok (Some { ddl_password; dml_password })
     | _ ->
       Error
         (unreadable
            (Printf.sprintf
               "it does not carry both SOL_DDL_PASSWORD and SOL_DML_PASSWORD")))
;;

(** Which operation this deploy performs, and the passwords it uses.

    An ordinary deploy **reuses** what is recorded: it re-applies the passwords the
    consumers already hold, so Postgres and the projections stay in agreement and nothing a
    running release depends on changes. Only a target with no recorded authority bootstraps,
    and then the passwords are generated exactly once — persisted by the caller's apply,
    before the Job touches Postgres.

    Rotation is deliberately absent: PostgreSQL invalidates the previous password the moment
    [ALTER] runs, so it needs overlapping credentials or an explicitly disruptive procedure,
    and that is an operator decision rather than a side effect of a deploy. *)
let resolve ~ctx ~namespace ~target =
  let open Result.Syntax in
  let* recorded = read_authority ~ctx ~namespace ~target in
  match recorded with
  | Some authority ->
    Ok (Sol_cli_database_setup.Repair, authority.ddl_password, authority.dml_password)
  | None ->
    Ok
      ( Sol_cli_database_setup.Bootstrap
      , Sol_cli_database_setup_password.generate ()
      , Sol_cli_database_setup_password.generate () )
;;

let wait_interval_s = 2.

(** 300s, matching the migration Job ([cmd_migrate], [Sol_cli_contract]) rather than the
    migration *gate*'s 120s: this runs DDL against the database, the same class of work,
    and a false timeout fails a deploy that was about to succeed. *)
let wait_attempts = 150

let run
      ~ctx
      ~namespace
      ~ca_namespaces
      ~target
      ~master_url
      ~operation
      ~ddl_password
      ~dml_password
      ~ca_cert
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
  let authority =
    Render.authority_secret_doc ~ns:namespace ~target ~ddl_password ~dml_password
  in
  let script = Render.script_configmap_doc ~ns:namespace ~target ~operation in
  let job_doc = Render.job_doc ~ns:namespace ~target ~image in
  (* The CA is a durable trust anchor, not a per-run credential: the Job mounts it, and the
     consuming units mount the same object after 2b delivers their class Secrets. So it is
     written for the migration namespace and every consuming namespace, and — unlike the
     script and the transient Secret — it is deliberately not collected by [cleanup]. A
     re-run with a rotated CA overwrites it in place. *)
  let ca_docs =
    ca_namespaces
    |> List.sort_uniq String.compare
    |> List.map (fun ns -> Render.ca_configmap_doc ~ns ~target ~ca_cert)
  in
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
       (* A bootstrap persists the passwords *before* Postgres is touched, so an interruption
         leaves a recorded authority and the next deploy repairs from it — rather than roles
         whose password nobody has. A repair writes nothing here: the authority it is
         re-applying is already the record. *)
       let* () =
         match operation with
         | Sol_cli_database_setup.Bootstrap ->
           apply_doc ~ctx ~what:"password authority" authority
         | Sol_cli_database_setup.Repair -> Ok ()
       in
       (* Before the Job: what the Job *consumes* (the transient Secret), the script that
         consumes it, and the trust anchor it verifies the server against. The Job produces
         the roles; it does not receive the class credentials. *)
       let* () =
         List.fold_left
           (fun acc (what, doc) ->
              let* () = acc in
              apply_doc ~ctx ~what doc)
           (Ok ())
           ([ "transient secret", transient; "setup script", script ]
            @ List.map (fun doc -> "database CA", doc) ca_docs)
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
       | Sol_cli_migration_job.Succeeded ->
         (* Only now has Postgres accepted these passwords, so only now do the projections
            consumers read carry a value that works. Writing them before the Job would hand
            a replacement password to pods that can restart before the server knows it.
            A failed Job therefore leaves the previous projections exactly as they were,
            and the recorded authority makes the next deploy a repair. *)
         List.fold_left
           (fun acc doc ->
              let* () = acc in
              apply_doc ~ctx ~what:"class credential" doc)
           (Ok ())
           output_secrets
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

(** The external owner's half of the same contract.

    A target may bind its database externally: the credential does not come from a Sol
    provisioner, it comes from a store the binding names. The *output* is still the class
    Secrets — the same object names, the same key — written by ESO from the remote path the
    binding names per class. That is what keeps the reader one reader: it asks for
    [`<target>-ddl-creds`]/[`<target>-dml-creds`] and does not branch on ownership (a
    consumer branch on ownership is exactly the dual-interpretation the resource-bindings
    design forbids).

    The class is the outer dimension — one ExternalSecret per class — because a contract
    with classes resolves one contract key to a *different* remote path per class. Every
    class must be delivered: the reader asks for each one, so a missing class would be
    indistinguishable from a target that has no database at all.

    Nothing here runs for a Sol-provisioned database; that target's classes are written by
    the setup Job's coordinator ([run]). *)

(** The pure core: which ExternalSecrets an externally bound database needs, one per class
    per namespace that reads it. Separate from the apply so the shape is testable without a
    cluster. *)
let external_credential_docs
      ~target
      ~migration_namespace
      ~dml_namespaces
      ~(binding : Sol_cli_resource_binding.t)
  =
  let module Render = Sol_cli_database_setup_render in
  let* store =
    match binding.Sol_cli_resource_binding.store with
    | Some store -> Ok store
    | None ->
      Error
        (Printf.sprintf
           "the externally bound database %S names no store, so there is nowhere to read \
            its credentials from"
           binding.resource)
  in
  let* classes =
    Sol_cli_result.map_list
      (fun credential_class ->
         match
           List.assoc_opt credential_class binding.Sol_cli_resource_binding.credentials
         with
         | Some remote_path -> Ok (credential_class, remote_path)
         | None ->
           Error
             (Printf.sprintf
                "the externally bound database %S names no remote path for the %S \
                 credential class (binding.credentials.%s), so that class would have no \
                 credential at all"
                binding.resource
                credential_class
                credential_class))
      Render.postgres_classes
  in
  (* The DDL class is what the migration path reads, so it lands where migrations run; the
     DML class lands wherever a unit declares it consumes the resource. *)
  let namespaces_for_class credential_class =
    if String.equal credential_class Render.ddl_class
    then [ migration_namespace ]
    else dml_namespaces
  in
  Ok
    (List.concat_map
       (fun (credential_class, remote_path) ->
          namespaces_for_class credential_class
          |> List.sort_uniq String.compare
          |> List.map (fun ns ->
            Render.class_external_secret_doc
              ~ns
              ~target
              ~credential_class
              ~store
              ~remote_path))
       classes)
;;

let run_external_credentials
      ~ctx
      ~target
      ~migration_namespace
      ~dml_namespaces
      ~(binding : Sol_cli_resource_binding.t)
  =
  let* docs =
    external_credential_docs ~target ~migration_namespace ~dml_namespaces ~binding
  in
  List.fold_left
    (fun acc doc ->
       let* () = acc in
       apply_doc ~ctx ~what:"external database credential" doc)
    (Ok ())
    docs
;;
