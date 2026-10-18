(** The one resolution of a target's resources into bindings.

    Every consumer of a resource — provisioning, workload rendering, local execution and
    rollback — asks this module what a resource *is*, rather than re-deriving it. The
    effective resource graph is [Sol_cli_config.resources], which already applies [omit];
    the binding selection is [Sol_cli_config.resource_binding].

    v1 supports at most one database per target, whatever its ownership. That limit lives
    here, where the effective graph is resolved, and not in a consumer. *)

type t =
  { resource : string
  ; typ : string
  ; ownership : Sol_cli_config.resource_ownership
  ; store : string option
  ; keys : (string * string) list
  ; connection : (string * string) list
  ; (* Class name -> remote path, for a contract with credential classes. *)
    credentials : (string * string) list
  }

(** Resolve every effective resource for a target. Fails when a resource has no type, or
    when the graph declares more than one PostgreSQL resource (the v1 limit, whatever the
    ownership). *)
val resolve : Sol_cli_config.t -> (t list, string) result

(** Resolve an already selected effective resource graph (also used by local planning). *)
val resolve_resources : Sol_cli_config.resource list -> (t list, string) result

(** Whether the resolved graph has a resource of this type that Sol provisions. *)
val provisions : t list -> typ:string -> bool

(** The resolved bindings of one type. *)
val of_type : t list -> typ:string -> t list

(** PostgreSQL selection after binding validation. External credentials are complete
    by construction. Local development publishes class credentials without the
    managed setup Job or its CA. *)
type postgres_credentials =
  { ddl : string
  ; dml : string
  }

type external_postgres =
  { resource : string
  ; store : string
  ; credentials : postgres_credentials
  }

type postgres =
  | No_postgres
  | Managed_postgres of string
  | External_postgres of external_postgres
  | Local_postgres of string

(** [Connection_trust] retains the connection contract; it does not assert that
    external databases need no private CA or add a CA-delivery capability. *)
type postgres_trust =
  | Published_ca
  | Connection_trust

type postgres_use =
  | No_postgres_use
  | Postgres_use of
      { target : string
      ; trust : postgres_trust
      }

(** Credential-class vocabulary shared by resolution and rendering. *)
val ddl_class : string

val dml_class : string

(** Validates complete external URL classes and refuses additional connection/trust
    inputs for which the current PostgreSQL delivery has no implementation. *)
val postgres : t list -> (postgres, string) result

val resolve_postgres : Sol_cli_config.t -> (postgres, string) result
val postgres_resource : postgres -> string option
val postgres_is_managed : postgres -> bool
val postgres_trust : postgres -> postgres_trust
val postgres_use_target : postgres_use -> string option
val postgres_use_ca_target : postgres_use -> string option
