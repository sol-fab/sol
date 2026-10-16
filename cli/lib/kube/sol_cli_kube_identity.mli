(** Kubernetes-owned identity facts, not kubeconfig user/context labels. *)
type t = private
  { principal : string
  ; cluster : string
  ; endpoint : string
  ; configuration : string
  }

type error =
  | Command of string * Sol_cli_process.error
  | Invalid of string

(** Reuses explicit destination, current credentials and TLS verification. Cluster
    identity is the server-returned kube-system namespace UID, never a local alias.
    No credentials/raw kubeconfig/namespace objects escape this interface. *)
val observe : ctx:Sol_cli_kube_destination.context -> (t, error) result

val same : t -> t -> bool
val diagnostic : error -> string
