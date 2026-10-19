(** The in-cluster database setup step — ADR 0007.

    It runs once per target, after the deploy prerequisites and before the migration
    Job: with the database's administrative credential, it creates the DDL and DML roles
    with Sol-generated passwords and writes their credentials to the target's Secrets.

    The step is part of the *provisioning path*, not a consumer: it receives the master
    for the duration of one Job and never appears in the class model as a role. *)

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

(** The operations that touch the roles — and the one that deliberately does not.

    They are distinct because they authorize different things:

    - {!Bootstrap} creates roles that do not exist yet, with freshly generated passwords.
      It **refuses outright if a role is already there**: with no recorded authority, a
      replacement password would silently invalidate the credential that role's consumers
      already hold, and the deploy would look like it succeeded.
    - {!Repair} re-applies the *recorded* passwords, so Postgres is made to match the
      authority again. It may create a role that has gone missing, because the password it
      uses is the one the authority already records — nothing a consumer holds changes.
    - **Rotation** — changing a password that is in use — is deliberately *not* one of
      these. PostgreSQL invalidates the old password immediately on [ALTER], so rotation
      needs overlapping credentials or an explicitly disruptive procedure: an operator
      decision, not a side effect of a deploy. *)
type operation =
  | Bootstrap
  | Repair

let operation_to_string = function
  | Bootstrap -> "bootstrap"
  | Repair -> "repair"
;;

(** Why a bootstrap refusal is a stop, not a defect to work around. *)
let bootstrap_refusal role =
  Printf.sprintf
    "the role %s already exists, but this target records no password authority. Refusing \
     to generate a replacement password for an existing role: the credential its \
     consumers hold would stop working. Recover the authority Secret, or rotate the \
     credentials deliberately."
    role
;;

(** One role's statements for one operation. [setting] is the [current_setting] name the
    password was staged under, so the password never appears in this script's text. *)
let role_statement ~operation ~role ~setting =
  let statement verb =
    Printf.sprintf
      "    EXECUTE format('%s ROLE %s LOGIN PASSWORD %%L', current_setting('%s'));"
      verb
      role
      setting
  in
  match operation with
  | Bootstrap ->
    Printf.sprintf
      "  IF EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') THEN\n\
      \    RAISE EXCEPTION '%s';\n\
      \  END IF;\n\
       %s"
      role
      (bootstrap_refusal role)
      (statement "CREATE")
  | Repair ->
    Printf.sprintf
      "  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') THEN\n\
       %s\n\
      \  ELSE\n\
       %s\n\
      \  END IF;"
      role
      (statement "CREATE")
      (statement "ALTER")
;;

(** The setup script, per operation. The staging prefix, the blank-input refusals and the
    grants are shared: the operations differ only in what they authorize about the roles. *)
let sql ~operation =
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
%s
%s
EXCEPTION WHEN OTHERS THEN
  -- Dynamic role SQL contains passwords: preserve the original code/message,
  -- but replace its sensitive execution context before it reaches any logs.
  RAISE EXCEPTION USING ERRCODE = SQLSTATE, MESSAGE = SQLERRM;
END
$$;
GRANT USAGE ON SCHEMA public TO %s, %s;
GRANT CREATE ON SCHEMA public TO %s;
GRANT %s TO CURRENT_USER;
ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %s;
ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO %s;|sql}
    (role_statement ~operation ~role:ddl_role ~setting:"sol.ddl_password")
    (role_statement ~operation ~role:dml_role ~setting:"sol.dml_password")
    ddl_role
    dml_role
    ddl_role
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
    before it disappears.

    The TTL only starts once the Job *finishes*: a Job that never finishes is never
    collected, which is what {!active_deadline_seconds} bounds. *)
let crash_backstop_seconds = 3600

(** How long the Job may live in total — including image pull, connecting, and the SQL run.

    It must strictly exceed the coordinator's wait window ([wait_interval_s] ×
    [wait_attempts] in {!Sol_cli_database_setup_run}), because the two bound different
    things: the waiter giving up is not the Job being over. Setting them equal kills a
    slow-but-succeeding setup at exactly the moment the waiter stops looking — which is
    indistinguishable from the failure the deadline exists to bound. 600s is the 300s
    window plus 300s for the pull, the connection and the run. *)
let active_deadline_seconds = 600
