(** Renders the database setup step — ADR 0007.

    **Write ordering.** Sol is the sole password authority: it generates the DDL and DML
    passwords and writes them, together with the master connection, into the transient
    Secret *and* into the output Secrets, **before** the Job runs. The Job only applies
    the roles. So a Job that fails leaves output Secrets that are present but unused, and
    a re-run overwrites them — rather than a Job that succeeded followed by a Sol write
    that failed, leaving consumers with no credential at all.

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

let setup_name workload = workload ^ "-db-setup"
let script_name workload = workload ^ "-db-setup-script"

(** Where the database CA will be mounted. Rendered **empty** today: 2d changes the cloud
    output to [sslmode=verify-full&sslrootcert=...] and populates this volume, without
    that change having to touch this renderer. *)
let ca_mount_path = "/etc/sol/db-ca"

let secret_name workload = setup_name workload
let job_name workload = setup_name workload

(** The transient Secret. It carries the master for the duration of one Job and is never
    part of a workload's inputs.

    The [ownerReference] to the Job is **not** set here: the Job does not exist yet when
    Sol writes this, so its UID is unknown. The coordinator patches the reference in
    after creating the Job (one call, from the UID the create returns), which is what
    makes a later Job deletion — including the [ttlSecondsAfterFinished] backstop —
    collect this Secret by cascade. *)
let transient_secret_doc ~ns ~workload ~master_url ~ddl_password ~dml_password =
  resource
    ~api_version:"v1"
    ~kind:"Secret"
    [ "metadata", metadata ~ns ~name:(secret_name workload)
    ; "type", Y.string "Opaque"
    ; ( "stringData"
      , Y.map
          [ "POSTGRES_URL", Y.quoted master_url
          ; "SOL_DDL_PASSWORD", Y.quoted ddl_password
          ; "SOL_DML_PASSWORD", Y.quoted dml_password
          ] )
    ]
;;

(** The script, as a ConfigMap. It carries no secret: the passwords arrive through the
    environment, and the script reads them with [\getenv]. *)
let script_configmap_doc ~ns ~workload =
  resource
    ~api_version:"v1"
    ~kind:"ConfigMap"
    [ "metadata", metadata ~ns ~name:(script_name workload)
    ; "data", Y.map [ "setup.sql", Y.literal Sol_cli_database_setup.role_sql ]
    ]
;;

let env_from_secret workload keys =
  List.map
    (fun key ->
       Y.map
         [ "name", Y.string key
         ; ( "valueFrom"
           , Y.map
               [ ( "secretKeyRef"
                 , Y.map [ "name", Y.string (secret_name workload); "key", Y.string key ]
                 )
               ] )
         ])
    keys
;;

(** The Job. [psql] is invoked with the connection string from the environment and the
    script from a file — never [-c] and never [argv], which is what the script's
    [\getenv] and dollar-quoted block require. [ON_ERROR_STOP] is the script's first
    line rather than a flag here, so an invocation change cannot lose it. *)
let job_doc ~ns ~workload ~image =
  resource
    ~api_version:"batch/v1"
    ~kind:"Job"
    [ "metadata", metadata ~ns ~name:(job_name workload)
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
                                         workload
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
                                  , Y.map [ "name", Y.string (script_name workload) ] )
                                ]
                            ; (* Empty on purpose: 2d supplies the CA here. A projected
                                 volume with no sources is valid, so the pod spec does
                                 not change shape when 2d lands. *)
                              Y.map
                                [ "name", Y.string "db-ca"
                                ; "projected", Y.map [ "sources", Y.list [] ]
                                ]
                            ] )
                      ] )
                ] )
          ] )
    ]
;;

(** In write order: the Secret Sol writes first, then the script, then the Job. *)
let docs ~ns ~workload ~master_url ~ddl_password ~dml_password ~image =
  [ transient_secret_doc ~ns ~workload ~master_url ~ddl_password ~dml_password
  ; script_configmap_doc ~ns ~workload
  ; job_doc ~ns ~workload ~image
  ]
;;
