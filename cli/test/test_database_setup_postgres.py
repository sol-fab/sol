#!/usr/bin/env python3
"""Execute the actual setup generator against an isolated PostgreSQL 16 server.

Roles are cluster-wide: use a private, unexposed container rather than altering
sol_migrator/sol_app on the shared integration server. No provider credentials
or cloud access are used. Missing Docker/PostgreSQL is a failure, never a skip.
"""
import os
import subprocess
import sys
import time
import uuid


def run(argv, **kwargs):
    return subprocess.run(argv, text=True, capture_output=True, timeout=60, **kwargs)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    generator = os.path.abspath(sys.argv[1])
    name = "sol-setup-test-" + uuid.uuid4().hex
    # Deliberately include SQL quoting characters as well as a distinctive canary.
    ddl = "ddl-canary-'quote-\\slash-" + uuid.uuid4().hex
    dml = "dml-canary-'quote-\\slash-" + uuid.uuid4().hex
    secrets = (ddl, dml)
    environment = dict(os.environ, SOL_DDL_PASSWORD=ddl, SOL_DML_PASSWORD=dml)

    def safe(result):
        for secret in secrets:
            # PostgreSQL's error context can include escaped dynamic SQL too.
            for spelling in (secret.split("'")[0],):
                require(spelling not in result.stdout + result.stderr,
                        "setup disclosed a credential in stdout/stderr")
        return result

    def psql(sql, *, role="postgres", env=None):
        result = run(["docker", "exec", "-i", "-e", "SOL_DDL_PASSWORD", "-e", "SOL_DML_PASSWORD",
                      "-e", "PGPASSWORD", name, "psql", "--no-psqlrc", "--host=127.0.0.1",
                      "--username=" + role, "--dbname=postgres", "--file=/dev/stdin"],
                     input=sql, env=env or environment)
        return safe(result)

    def admin(sql):
        result = psql("\\set ON_ERROR_STOP on\n" + sql)
        require(result.returncode == 0, "test SQL failed: " + result.stderr)
        return result.stdout

    def script(operation):
        result = run([generator, operation])
        require(result.returncode == 0, "setup generator failed")
        return result.stdout

    bootstrap, repair = script("bootstrap"), script("repair")
    try:
        started = run(["docker", "run", "--detach", "--rm", "--network=none", "--name", name,
                       "-e", "POSTGRES_PASSWORD=integration-only", "postgres:16-alpine"])
        require(started.returncode == 0, "cannot start isolated PostgreSQL: " + started.stderr)
        environment["PGPASSWORD"] = "integration-only"
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            ready = run(["docker", "exec", name, "pg_isready", "--host=127.0.0.1", "--username=postgres"])
            if ready.returncode == 0:
                break
            time.sleep(0.25)
        else:
            raise AssertionError("isolated PostgreSQL did not become ready")

        for operation in (bootstrap, repair):
            for key in ("SOL_DDL_PASSWORD", "SOL_DML_PASSWORD"):
                for value in ("", None):
                    inputs = dict(environment)
                    if value is None:
                        inputs.pop(key, None)
                    else:
                        inputs[key] = value
                    failed = psql(operation, env=inputs)
                    require(failed.returncode != 0, "missing/empty " + key + " accepted")
                    require(admin("SELECT count(*) FROM pg_roles WHERE rolname IN ('sol_migrator','sol_app');").splitlines()[2].strip() == "0",
                            "rejected credentials created a role")
        print("ok: bootstrap and repair reject unset/empty credentials without creating roles")

        admin("CREATE ROLE limited LOGIN PASSWORD 'integration-only';")
        failed = psql(bootstrap, role="limited")
        require(failed.returncode != 0, "SQL failure reported success")
        require("permission denied to create role" in failed.stderr, "original SQL diagnostic was lost")
        print("ok: a real SQL permission error exits nonzero and discloses no credential")

        result = psql(bootstrap)
        require(result.returncode == 0, "bootstrap failed: " + result.stderr)
        require("sol_migrator" in admin("SELECT rolname FROM pg_roles WHERE rolname IN ('sol_migrator','sol_app');"), "DDL role was not created")
        for role, password in (("sol_migrator", ddl), ("sol_app", dml)):
            logged_in = psql("SELECT current_user;", role=role, env=dict(environment, PGPASSWORD=password))
            require(logged_in.returncode == 0 and role in logged_in.stdout, "generated role cannot authenticate")
        print("ok: generated credentials authenticate both roles; stdout/stderr contain no secrets")

        # An early SQL error must stay fatal even when later grants would succeed.
        failed = psql(bootstrap)
        require(failed.returncode != 0 and "Refusing" in failed.stderr, "bootstrap overwrote existing roles or masked its SQL error")
        print("ok: bootstrap refusal cannot be hidden by subsequent successful grants")

        result = psql(repair)
        require(result.returncode == 0, "recorded credential repair failed: " + result.stderr)
        ddl_env = dict(environment, PGPASSWORD=ddl)
        require(psql("\\set ON_ERROR_STOP on\nCREATE TABLE setup_test (id serial PRIMARY KEY, value text);", role="sol_migrator", env=ddl_env).returncode == 0,
                "DDL role cannot create schema objects")
        dml_env = dict(environment, PGPASSWORD=dml)
        inserted = psql("\\set ON_ERROR_STOP on\nINSERT INTO setup_test(value) VALUES ('ok'); SELECT * FROM setup_test;", role="sol_app", env=dml_env)
        require(inserted.returncode == 0 and "ok" in inserted.stdout,
                "DML role cannot use migrator-created tables and sequences")
        require(psql("\\set ON_ERROR_STOP on\nCREATE TABLE must_not_exist(id int);", role="sol_app", env=dml_env).returncode != 0,
                "DML role gained DDL authority")
        print("ok: repair preserves credentials and grants separate DDL/DML authority")
        safe(run(["docker", "logs", name]))
        print("ok: PostgreSQL server logs also contain no credential canaries")
    finally:
        run(["docker", "rm", "--force", name])


if __name__ == "__main__":
    main()
