val resolve
  :  command:string
  -> local:bool
  -> target:string option
  -> (Sol_cli_kube_destination.context, string) result

(** Resolve a remote command's cluster *and* read its target config once, for a caller that
    needs both (rollback derives its database bindings from that config). The refusal for a
    missing target is the same message [resolve] gives. *)
val resolve_with_config
  :  command:string
  -> target:string option
  -> (Sol_cli_kube_destination.context * Sol_cli_config.t, string) result
