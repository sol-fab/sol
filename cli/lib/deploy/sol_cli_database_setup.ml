(** The in-cluster database setup step — ADR 0007.

    It runs once per target, after the deploy prerequisites and before the migration
    Job: with the database's administrative credential, it creates the DDL and DML roles
    with Sol-generated passwords and writes their credentials to the target's Secrets.

    The step is part of the *provisioning path*, not a consumer: it receives the master
    for the duration of one Job and never appears in the class model as a role. *)

(** Where the image digest is configured. Mirrors the runner's mechanism
    ([SOL_MIGRATION_RUNNER_IMAGE]): a digest reference is required and a tag is refused.
    The *instruction* differs, because this image is public — see {!setup_image}. *)
let image_env = "SOL_SETUP_POSTGRES_IMAGE"

let not_a_digest_ref ref_ =
  Printf.sprintf
    "%s %S is not a digest reference (<image>@sha256:<64 hex>); this Job runs with the \
     database's administrative credential, so an image reference that can move is not \
     acceptable"
    image_env
    ref_
;;

(** The setup image.

    Unlike the migration runner, this image is **public**: there is nothing to publish,
    only a digest to pin. The error names that resolution rather than telling the
    operator to publish something that does not belong to Sol. *)
let setup_image () =
  match Sol_cli_string.env image_env with
  | Some ref_ when Sol_cli_platform_assets.is_digest_ref ref_ -> Ok ref_
  | Some ref_ -> Error (not_a_digest_ref ref_)
  | None ->
    Error
      (Printf.sprintf
         "no database setup image is configured. Set %s to an image pinned by digest, \
          for example postgres@sha256:<64 hex> - `docker buildx imagetools inspect \
          postgres:16` prints the current digest (the plain `docker manifest inspect` \
          form prints the manifest JSON without a digest line). Unlike the migration \
          runner, this image is public: there is nothing to publish, only a digest to \
          pin"
         image_env)
;;

(** The roles. Fixed names, because the consumer's role determines its credential class
    rather than a user declaration (ADR 0007): the migration Job is DDL, workloads are
    DML, and neither can ask for a higher class. *)
let ddl_role = "sol_migrator"

let dml_role = "sol_app"

(** Idempotent by construction: re-running against a target whose roles exist is a no-op
    in value — the passwords come from the existing Secret, so the [ALTER] re-applies the
    same value rather than churning it.

    **Where the passwords come from — and why this is a file, not [-c].** psql does *not*
    interpolate [:'variable'] inside a dollar-quoted block: the server receives the
    literal text and reports a syntax error. Verified against PostgreSQL 16. So the
    values are read from the environment with [\getenv] — not from argv (which is visible
    in the process list) and not from the script text (which would put them in the
    manifest) — and the block uses [current_setting] to reach them. That requires the
    script on stdin or [-f]; [-c] cannot carry this. The Job's [env:] feeds
    [SOL_DDL_PASSWORD] and [SOL_DML_PASSWORD] from the transient Secret, exactly as it
    feeds the master connection string.

    [set_config] returns the value it set, so the selects project [IS NOT NULL]: without
    it psql prints the password to stdout and the Job's logs capture it. Verified the
    same way.

    **The grants belong here, not in the migrations.** The migration runs as
    [sol_migrator] and creates the schema's objects, so [ALTER DEFAULT PRIVILEGES] for
    that role is what makes everything it later creates reachable by [sol_app]. On
    PostgreSQL 15 and later [public] grants no [CREATE] to [PUBLIC], so [sol_migrator]
    needs it explicitly or the migration cannot create anything. *)
let role_sql =
  Printf.sprintf
    {sql|\set ON_ERROR_STOP on
\getenv ddl_password SOL_DDL_PASSWORD
\getenv dml_password SOL_DML_PASSWORD
SELECT set_config('sol.ddl_password', :'ddl_password', false) IS NOT NULL;
SELECT set_config('sol.dml_password', :'dml_password', false) IS NOT NULL;
DO $$
BEGIN
  IF coalesce(current_setting('sol.ddl_password', true), '') = '' THEN
    RAISE EXCEPTION 'SOL_DDL_PASSWORD is empty; refusing to create a role with no password';
  END IF;
  IF coalesce(current_setting('sol.dml_password', true), '') = '' THEN
    RAISE EXCEPTION 'SOL_DML_PASSWORD is empty; refusing to create a role with no password';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') THEN
    EXECUTE format('CREATE ROLE %s LOGIN PASSWORD %%L', current_setting('sol.ddl_password'));
  ELSE
    EXECUTE format('ALTER ROLE %s LOGIN PASSWORD %%L', current_setting('sol.ddl_password'));
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') THEN
    EXECUTE format('CREATE ROLE %s LOGIN PASSWORD %%L', current_setting('sol.dml_password'));
  ELSE
    EXECUTE format('ALTER ROLE %s LOGIN PASSWORD %%L', current_setting('sol.dml_password'));
  END IF;
END
$$;
GRANT USAGE ON SCHEMA public TO %s, %s;
GRANT CREATE ON SCHEMA public TO %s;
GRANT %s TO CURRENT_USER;
ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %s;
ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO %s;|sql}
    ddl_role
    ddl_role
    ddl_role
    dml_role
    dml_role
    dml_role
    ddl_role
    dml_role
    ddl_role
    (* The admin must hold membership in [ddl_role] to alter that role's default privileges:
       upstream requires membership in (or superuser over) the target role. Cloud SQL's
       `postgres` is [cloudsqlsuperuser], not a true superuser, so it is refused without
       this — observed live. Granting it is not an escalation: the admin created the role
       and already holds admin option on it. *)
    ddl_role
    ddl_role
    dml_role
    ddl_role
    dml_role
;;

(** How long the controller waits before collecting a finished Job — and, by cascade,
    the transient master Secret it owns. This is the *backstop*: Sol deletes the Job
    after completion or failure itself, and the TTL covers the case where Sol's process
    dies between applying and deleting. Long enough to read the Job's logs for evidence
    before it disappears. *)
let crash_backstop_seconds = 3600
