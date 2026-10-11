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

(** What a run of the setup step is authorized to do to the roles — and the operation it
    deliberately is not.

    [Bootstrap] creates roles that do not exist yet and refuses if one already does: with no
    recorded authority, a replacement password would silently invalidate the credential that
    role's consumers hold. [Repair] re-applies the recorded passwords, creating a role only
    if it has gone missing. Rotation — changing a password that is in use — is an operator
    decision, not a deploy side effect: PostgreSQL invalidates the old password immediately
    on [ALTER]. *)
type operation =
  | Bootstrap
  | Repair

(** The operation as it is recorded in the cluster. *)
val operation_to_string : operation -> string

(** The setup script for one operation. Passwords arrive as [psql] variables, so this text
    carries no secret; the two operations differ only in what they authorize about roles
    that already exist. *)
val sql : operation:operation -> string

(** The backstop for collecting a finished Job — and, by cascade, the transient master
    Secret it owns — when Sol's own deletion of the Job does not happen. *)
val crash_backstop_seconds : int
