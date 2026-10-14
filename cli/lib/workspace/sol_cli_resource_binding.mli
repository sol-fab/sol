(** The one resolution of a target's resources into bindings.

    Every consumer of a resource — provisioning, workload rendering, local execution and
    rollback — asks this module what a resource *is*, rather than re-deriving it. The
    effective resource graph is [Sol_cli_config.resources], which already applies [omit];
    the binding selection is [Sol_cli_config.resource_binding].

    v1 supports at most one provisioned database per target. That limit lives here, where
    the effective graph is resolved, and not in a consumer. *)

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

(** Whether the resolved graph has a resource of this type that Sol provisions. *)
val provisions : t list -> typ:string -> bool

(** The resolved bindings of one type. *)
val of_type : t list -> typ:string -> t list

(** The single provisioned database, when there is one. *)
val provisioned_database : t list -> t option

(** The resource a target's database consumers read: the provisioned database when Sol owns
    one, otherwise the single externally bound postgres resource. [None] when there is no
    postgres resource at all — [resolve] has already refused a graph with more than one, so
    there is no ambiguous case left for a consumer's `POSTGRES_URL` to fall through. *)
val target_database : t list -> t option
