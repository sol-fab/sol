(** Renders the database setup step — ADR 0007.

    **Write ordering: the authority first, the projections last.** Sol is the sole password
    authority. The DDL and DML passwords are generated once and recorded in the target's
    authority Secret ({!authority_name}), which is the durable source of truth for every
    later deploy: an ordinary deploy reuses the recorded passwords instead of generating
    new ones, and a projection an operator deleted is rebuilt from the authority rather
    than regenerated.

    The order follows from what has been *verified* at each step. A bootstrap writes the
    authority **before** Postgres is touched, so an interruption leaves a recoverable record
    instead of roles whose password nobody knows. The output Secrets — the projections
    consumers actually read — are written **after** the Job succeeds, because only then has
    Postgres accepted the password they carry. Writing them first hands a replacement
    password to pods that can restart before the server knows it, which is how a running
    release breaks on the next deploy. A failed Job now leaves the previous projections
    untouched, and the authority makes the next deploy a repair rather than a loss.

    **The rendered output carries the passwords in plaintext** ([stringData]), so
    where it goes matters. It is rendered in memory and handed to the existing apply
    path, which writes it to a temp file, runs a server-side dry run, applies, and
    deletes the file. kubectl does not echo the file, so the passwords do not reach a
    log or a terminal; the residual is the temp file's lifetime on the host.

    **Re-deploy behaviour: delete, then create.** A Job's pod template is immutable, so
    "run every deploy" (which is what makes the script the drift-repair path) cannot be
    a patch. The coordinator deletes an existing setup Job and applies the new one, so a
    changed image, script or volume — including 2d's CA change — is a re-create by
    construction rather than a failure.

    The script carries its own guarantees ([ON_ERROR_STOP], the blank-input refusal, the
    print mitigation). Nothing here re-derives them: the invocation must not be able to
    lose what the script enforces. *)

module Y = Sol_cli_yaml

let resource ~api_version ~kind fields =
  Y.document
    (Y.map (("apiVersion", Y.string api_version) :: ("kind", Y.string kind) :: fields))
;;

let metadata ~ns ~name = Y.map [ "name", Y.string name; "namespace", Y.string ns ]

(** The Job makes no Kubernetes API calls: the kubelet fetches the transient Secret for
    the env vars on the pod's behalf, and the container talks only to Postgres. Mounting
    an identity token it cannot use is unnecessary credential surface. *)
let automount_service_account_token = false

let setup_name target = target ^ "-db-setup"
let script_name target = target ^ "-db-setup-script"

(** The **password authority**: the target's record of the DDL and DML passwords, and the
    only place they are generated. It is durable — it outlives the Job, which is deleted
    with its transient Secret — because it is what makes a later deploy a *repair* (re-apply
    the recorded passwords) rather than a rotation (generate new ones and invalidate what is
    running).

    It lives in the migration namespace, beside the credentials it authorizes. It is not a
    consumer projection: consumers read the class Secrets, which are derived from this. *)
let authority_name target = target ^ "-db-credentials"

(** Where the database CA is mounted: the trust anchor [sslmode=verify-full] verifies the
    endpoint against ({!ca_cert_path} is what the connection URL names). Defined once, with
    the manifest's other mount contracts: the setup Job, the workload pods and the URL must
    all name the same path. *)
let ca_mount_path = Sol_cli_manifest_cluster_env.db_ca_mount_path

let ca_file_name = Sol_cli_manifest_cluster_env.db_ca_file_name
let ca_cert_path = Sol_cli_manifest_cluster_env.db_ca_file

(** The database CA, as a ConfigMap. A provider's public root is not a secret, so a
    ConfigMap is the right object rather than a Secret. The same name is mounted by the
    setup Job and, once 2b delivers the class credentials, by every consuming unit — so
    downstream nothing knows which provider supplied the CA. *)
let ca_configmap_name target = target ^ "-db-ca"

let ca_configmap_doc ~ns ~target ~ca_cert =
  resource
    ~api_version:"v1"
    ~kind:"ConfigMap"
    [ "metadata", metadata ~ns ~name:(ca_configmap_name target)
    ; "data", Y.map [ ca_file_name, Y.literal ca_cert ]
    ]
;;

let secret_name target = setup_name target
let job_name target = setup_name target

(** The credential classes (ADR 0007) and the key every class Secret carries.

    The class name *is* the output Secret's name suffix: one definition serves the Sol
    writer, the external writer and the reader, so none of them can drift. *)
let ddl_class = "ddl"

let dml_class = "dml"

(** Every class this contract has. Delivery must cover all of them: the reader asks for each
    one and must not learn from a missing Secret that the target is externally bound. *)
let postgres_classes = [ ddl_class; dml_class ]

let postgres_url_key = "POSTGRES_URL"
let creds_name ~credential_class target = target ^ "-" ^ credential_class ^ "-creds"
let ddl_creds_name target = creds_name ~credential_class:ddl_class target
let dml_creds_name target = creds_name ~credential_class:dml_class target

(** One output Secret: a class's connection URL under the consumer key.

    [POSTGRES_URL] is the same key the classes read today, so 2b's delivery selects the
    Secret by class and changes nothing about what the workload reads. The value is the
    derived URL ({!Sol_cli_database_setup_url}), never the master: the master lives only in
    the transient Secret, which the coordinator deletes. *)
let output_secret_doc ~ns ~name ~postgres_url =
  resource
    ~api_version:"v1"
    ~kind:"Secret"
    [ "metadata", metadata ~ns ~name
    ; "type", Y.string "Opaque"
    ; "stringData", Y.map [ postgres_url_key, Y.quoted postgres_url ]
    ]
;;

(** The *external* owner's writer of the same object: ESO renders a class Secret from the
    binding's remote path for that class.

    One ExternalSecret per class, because the class is the outer dimension: a contract with
    classes resolves one contract key ([POSTGRES_URL]) to a *different* remote path per
    class — the migrator's in [ddl], the application's in [dml]. The object name and the
    key are the ones {!ddl_creds_name} / {!dml_creds_name} and {!postgres_url_key} define,
    so an external target delivers the same Secret the reader already asks for: the reader
    does not branch on ownership.

    [creationPolicy: Owner] makes the Secret the ExternalSecret's, so removing the
    ExternalSecret removes the credential. *)
let class_external_secret_doc ~ns ~target ~credential_class ~store ~remote_path =
  let name = creds_name ~credential_class target in
  resource
    ~api_version:"external-secrets.io/v1"
    ~kind:"ExternalSecret"
    [ "metadata", metadata ~ns ~name
    ; ( "spec"
      , Y.map
          [ "refreshInterval", Y.string "1h"
          ; "target", Y.map [ "name", Y.string name; "creationPolicy", Y.string "Owner" ]
          ; ( "data"
            , Y.list
                [ Y.map
                    [ "secretKey", Y.string postgres_url_key
                    ; "remoteRef", Y.map [ "key", Y.string remote_path ]
                    ; ( "sourceRef"
                      , Y.map
                          [ ( "storeRef"
                            , Y.map
                                [ "name", Y.string store; "kind", Y.string "SecretStore" ]
                            )
                          ] )
                    ]
                ] )
          ] )
    ]
;;

(** The transient Secret. It carries the master for the duration of one Job and is never
    part of a target's inputs.

    The [ownerReference] to the Job is **not** set here: the Job does not exist yet when
    Sol writes this, so its UID is unknown. The coordinator patches the reference in
    after creating the Job (one call, from the UID the create returns), which is what
    makes a later Job deletion — including the [ttlSecondsAfterFinished] backstop —
    collect this Secret by cascade. *)
let transient_secret_doc ~ns ~target ~master_url ~ddl_password ~dml_password =
  resource
    ~api_version:"v1"
    ~kind:"Secret"
    [ "metadata", metadata ~ns ~name:(secret_name target)
    ; "type", Y.string "Opaque"
    ; ( "stringData"
      , Y.map
          [ "POSTGRES_URL", Y.quoted master_url
          ; "SOL_DDL_PASSWORD", Y.quoted ddl_password
          ; "SOL_DML_PASSWORD", Y.quoted dml_password
          ] )
    ]
;;

(** The authority Secret, written on a bootstrap only — an ordinary deploy reads it and
    re-applies what it records.

    It carries the same two values the transient Secret carries and **not** the master: the
    master is never persisted, so this object does not widen what a cluster compromise
    reaches. It is durable by design, so it is not collected by the Job's cleanup. *)
let authority_secret_doc ~ns ~target ~ddl_password ~dml_password =
  resource
    ~api_version:"v1"
    ~kind:"Secret"
    [ "metadata", metadata ~ns ~name:(authority_name target)
    ; "type", Y.string "Opaque"
    ; ( "stringData"
      , Y.map
          [ "SOL_DDL_PASSWORD", Y.quoted ddl_password
          ; "SOL_DML_PASSWORD", Y.quoted dml_password
          ] )
    ]
;;

(** The script for one operation. The ConfigMap name does not change with the operation,
    because the coordinator re-creates the Job on every deploy anyway; the operation is
    recorded in the ConfigMap so "which operation did this run?" is answerable from the
    cluster rather than from a log. *)
let script_configmap_doc ~ns ~target ~operation =
  resource
    ~api_version:"v1"
    ~kind:"ConfigMap"
    [ "metadata", metadata ~ns ~name:(script_name target)
    ; ( "data"
      , Y.map
          [ "setup.sql", Y.literal (Sol_cli_database_setup.sql ~operation)
          ; "operation", Y.string (Sol_cli_database_setup.operation_to_string operation)
          ] )
    ]
;;

let env_from_secret target keys =
  List.map
    (fun key ->
       Y.map
         [ "name", Y.string key
         ; ( "valueFrom"
           , Y.map
               [ ( "secretKeyRef"
                 , Y.map [ "name", Y.string (secret_name target); "key", Y.string key ] )
               ] )
         ])
    keys
;;

(** The Job. [psql] is invoked with the connection string from the environment and the
    script from a file — never [-c] and never [argv], which is what the script's
    [\getenv] and dollar-quoted block require. [ON_ERROR_STOP] is the script's first
    line rather than a flag here, so an invocation change cannot lose it. *)
let job_doc ~ns ~target ~image =
  resource
    ~api_version:"batch/v1"
    ~kind:"Job"
    [ "metadata", metadata ~ns ~name:(job_name target)
    ; ( "spec"
      , Y.map
          [ "backoffLimit", Y.int 0
          ; "ttlSecondsAfterFinished", Y.int Sol_cli_database_setup.crash_backstop_seconds
          ; ( "template"
            , Y.map
                [ ( "spec"
                  , Y.map
                      [ "restartPolicy", Y.string "Never"
                      ; ( "automountServiceAccountToken"
                        , Y.bool automount_service_account_token )
                      ; ( "containers"
                        , Y.list
                            [ Y.map
                                [ "name", Y.string "setup"
                                ; "image", Y.string image
                                ; ( "command"
                                  , Y.list
                                      [ Y.string "/bin/sh"
                                      ; Y.string "-c"
                                      ; Y.string
                                          "exec psql \"$POSTGRES_URL\" --no-psqlrc \
                                           --file=/sql/setup.sql"
                                      ] )
                                ; ( "env"
                                  , Y.list
                                      (env_from_secret
                                         target
                                         [ "POSTGRES_URL"
                                         ; "SOL_DDL_PASSWORD"
                                         ; "SOL_DML_PASSWORD"
                                         ]) )
                                ; ( "volumeMounts"
                                  , Y.list
                                      [ Y.map
                                          [ "name", Y.string "sql"
                                          ; "mountPath", Y.string "/sql"
                                          ; "readOnly", Y.bool true
                                          ]
                                      ; Y.map
                                          [ "name", Y.string "db-ca"
                                          ; "mountPath", Y.string ca_mount_path
                                          ; "readOnly", Y.bool true
                                          ]
                                      ] )
                                ]
                            ] )
                      ; ( "volumes"
                        , Y.list
                            [ Y.map
                                [ "name", Y.string "sql"
                                ; ( "configMap"
                                  , Y.map [ "name", Y.string (script_name target) ] )
                                ]
                            ; Y.map
                                [ "name", Y.string "db-ca"
                                ; ( "configMap"
                                  , Y.map [ "name", Y.string (ca_configmap_name target) ]
                                  )
                                ]
                            ] )
                      ] )
                ] )
          ] )
    ]
;;

(** In write order: the transient Secret Sol writes first, then the script and the CA, then
    the Job.

    Neither the authority nor the projections are here. Both are ordered by verification
    rather than by this list: the authority is written only on a bootstrap, and before the
    Job; the projections only after it succeeds. See {!Sol_cli_database_setup_run.run}. *)
let docs ~ns ~target ~operation ~master_url ~ddl_password ~dml_password ~ca_cert ~image =
  [ transient_secret_doc ~ns ~target ~master_url ~ddl_password ~dml_password
  ; script_configmap_doc ~ns ~target ~operation
  ; ca_configmap_doc ~ns ~target ~ca_cert
  ; job_doc ~ns ~target ~image
  ]
;;
