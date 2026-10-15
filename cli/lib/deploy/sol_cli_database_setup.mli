(** The database setup step's contract — ADR 0007. *)

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
    Secret it owns — when Sol's own deletion of the Job does not happen. It only starts
    once the Job finishes, so it does not bound a Job that never finishes. *)
val crash_backstop_seconds : int

(** How long the Job may live in total. Strictly greater than the coordinator's wait
    window: the waiter giving up is not the Job being over. *)
val active_deadline_seconds : int
