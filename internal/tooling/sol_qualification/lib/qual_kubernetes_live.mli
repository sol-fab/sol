(** Read-only transport for the existing observer. No provider provisioning,
    credential acquisition, policy owner or release verdict is introduced. *)
type t

val create
  :  ?operator_diagnostics:(Sol_cli_kube_identity.error -> unit)
  -> ctx:Sol_cli_kube_destination.context
  -> expected:Qual_domain.kube_target
  -> unit
  -> t

val read : t -> Qual_kubernetes.query -> Qual_kubernetes.reply

(** Independently establish the current Kubernetes authority for the expected
    target without a resource read. The returned context is what the caller
    persists as the submission's observation context; it never copies a
    product-reported identity or timestamp. *)
val establish : t -> (Qual_domain.read_context, string) result

(* Raw provider errors are available only through the explicit operator callback;
    that callback must never write ordinary qualification evidence. *)
