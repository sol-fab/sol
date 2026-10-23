type t

(** Whether a reference is [<image>@sha256:<64 hex>]. Shared with the database setup
    step, which pins a public image the same way the runner is pinned: a tag can move. *)
val is_digest_ref : string -> bool

type form =
  | Checkout
  | Installed of { version : string }

type error =
  | Invalid_sol_home of string
  | Bundle_version_mismatch of
      { dir : string
      ; bundle : string
      ; binary : string option
      }
  | Missing_bundle of
      { expected : string
      ; version : string
      }
  | Not_found

val error_to_string : error -> string

val resolve_from
  :  sol_home:string option
  -> exe_dir:string
  -> release_version:string option
  -> (t, error) result

val resolve : unit -> (t, error) result
val dir : t -> string
val form : t -> form

(** Whether [value] is a lowercase 40-hex commit. The one rule callers use to
    decide that a framework revision may be pinned. *)
val is_revision : string -> bool

(** The exact Sol revision this asset tree belongs to: the release bundle's
    REVISION file, or HEAD of the checkout. Refuses a missing or malformed
    revision rather than letting a caller pin a moving ref. *)
val revision : t -> (string, string) result

type cloud_role =
  | Bootstrap
  | Cluster
  | Platform
  | Authorization

val cloud_root_rel : Sol_cli_provider.t -> cloud_role -> string
val cloud_root : t -> Sol_cli_provider.t -> cloud_role -> string
val terraform_trees : string list
val components_json : t -> string
val templates_root : t -> string
val dashboard : t -> string -> string
val alloy_template : t -> string
val runner_image_env : string
val migration_runner_image : t -> (string, string) result

(** The variable that pins the public database setup image on a source checkout. *)
val setup_image_env : string

(** The database setup image, resolved from the installed release's own bundle like the runner
    — see {!migration_runner_image} for the rules the two share. On a checkout it falls back
    to {!setup_image_env}, whose guidance differs because this image is public. *)
val setup_image : t -> (string, string) result

val is_checkout : string -> bool
val find_ancestor : (string -> bool) -> string -> string option
