(** The database setup step's contract — ADR 0007. *)

(** The variable carrying the setup image's digest reference. *)
val image_env : string

(** The resolved setup image. Requires a digest reference: a tag can move under a Job
    that runs with the database's administrative credential. Unlike the migration
    runner, this image is public — the error names the variable to set and how to find
    a digest, not an artifact to publish. *)
val setup_image : unit -> (string, string) result

(** The DDL role: it owns the schema's objects. *)
val ddl_role : string

(** The DML role: it reads and writes what the DDL role creates. *)
val dml_role : string

(** Idempotent role creation with the grants that make the roles usable. Passwords
    arrive as [psql] variables, so this text carries no secret. *)
val role_sql : string

(** The backstop for collecting a finished Job — and, by cascade, the transient master
    Secret it owns — when Sol's own deletion of the Job does not happen. *)
val crash_backstop_seconds : int
