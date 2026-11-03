(** Provider-native addresses for Sol-managed secret authority.

    The application consumption contract is provider-independent, but the authority is
    not: AWS Secrets Manager and GCP Secret Manager name secrets differently. This module
    is the single definition of those names. The writer (`sol secret set`), the deployment
    planner that carries references, the workload authorization root and the CSI
    projection all consume it rather than reconstructing a spelling.

    No value crosses this module. A [t] is a reference and the nonconfidential metadata
    that establishes its owner. *)

type provider =
  | Aws
  | Gcp

type kind =
  | Application
  | Database

type scope =
  { provider : provider
  ; environment : string
  ; (* The target's normalized identity. One environment can contain more than one
       target, so the environment alone does not scope an authority. *)
    target : string
  ; project : string option
  ; region : string option
  }

type t =
  { provider : provider
  ; environment : string
  ; target : string
  ; name : string
  ; project : string option
  ; region : string option
  ; identity : string
  ; kind : kind
  ; (* The exact reference a CSI [SecretProviderClass] parameter uses: an AWS
       Secrets Manager name, or a GCP version resource name. *)
    resource_name : string
  }

val provider_to_string : provider -> string

(** The provider name a [SecretProviderClass] selects. *)
val spc_provider_name : provider -> string

val kind_to_string : kind -> string

(** A target's provider scope. [project] is the GCP project; [region] is the AWS region.
    A provider-native reference that cannot name its store is not constructible. *)
val scope
  :  provider:provider
  -> environment:string
  -> target:string
  -> project:string option
  -> region:string option
  -> (scope, string) result

val application
  :  scope:scope
  -> domain:string
  -> unit:string
  -> key:string
  -> (t, string) result

(** [part] is a stable suffix such as [authority], [ddl-creds] or [dml-creds]. The
    database authority and its class projections are distinct provider secrets even
    though they belong to one target, so a projection can be rewritten without touching
    the authority that records the passwords. *)
val database : scope:scope -> part:string -> (t, string) result

(** The provider-native reference an operator or a diagnostic may see. It is never a
    value and never a credential. *)
val reference : t -> string

(** The provider reference a CSI [SecretProviderClass] parameter names. *)
val spc_reference : t -> string

(** Nonconfidential ownership metadata. Both providers carry the same three facts under
    their native label/tag spelling; an authority whose metadata does not say Sol owns it
    is refused rather than adopted. *)
val ownership_labels : t -> (string * string) list

(** The mount filename a projected key uses. Secret names are unrelated to the key the
    application names, so the file is exactly the environment variable name. *)
val normalized_key : string -> string
