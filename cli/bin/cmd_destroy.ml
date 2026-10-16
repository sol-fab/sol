open Cmdliner
open Result.Syntax

(* The public target destroy command: `sol destroy <target>`.

   Destroy resolves the selected target once, through `Sol_cli_config.load_for_target`
   -- the same resolution `sol plan` and `sol deploy` consume -- and hands that typed
   intent to `Cmd_cloud_tf.cloud_destroy`. The provider and the Terraform variables come
   from that one resolved target instead of being re-derived from the target string.
   Every destruction safety policy in the executor is unchanged.

   `--plan` is the default and changes nothing; `--apply` is the destructive
   confirmation. Destroy deliberately does not borrow `sol deploy`'s apply-by-default
   posture: deploy is convergent and idempotent, destroy is destructive and not
   recoverable if mistaken, so the destructive confirmation stays explicit. *)
let run ~target ~var_file ~vars ~action ~accept_unreleased () =
  let* resolved_config =
    Sol_cli_config.load_for_target ~target
    |> Sol_cli_exit.of_error Sol_cli_config.error_to_string
  in
  Cmd_cloud_tf.cloud_destroy
    ~target
    ~resolved_config
    ~var_file
    ~vars
    ~action
    ~accept_unreleased
    ()
;;

let doc =
  "Reconcile a target toward empty: destroy its Sol-owned cloud infrastructure, its \
   platform and the workloads it released, then verify absence."
;;

let man =
  [ `S Manpage.s_description
  ; `P
      "Destroy is the whole target reconciled toward empty. It removes only resources \
       the selected target positively owns: Kubernetes objects are removed only when \
       their live UID matches the evidence recorded at apply, an object without that \
       evidence is retained rather than assumed owned, and unknown ownership fails \
       closed (docs/architecture/ownership.md). Durable installation resources -- the \
       state backend, its locking, the scoped identities and an installation-owned DNS \
       zone -- are outside target scope and are never touched; `sol uninstall` removes \
       those under its own confirmation contract."
  ; `P
      "`--plan` is the default and changes nothing. `--apply` is the destructive \
       confirmation and is required to mutate anything: unlike `sol deploy`, which is \
       convergent and idempotent, destroy is destructive and not recoverable if \
       mistaken, so it never mutates by default."
  ; `P
      "Destruction proceeds even when a best-effort preparation -- lowering a deletion \
       guard -- fails or its plan is refused: the failure is reported, the unsafe apply \
       is never executed, and what Terraform represents is still destroyed. Only a \
       failure that stands for a destruction-time guarantee the target itself declared \
       (such as `destroy_retention: final-snapshot`, which could not be prepared) blocks \
       destruction and leaves the target standing."
  ; `P
      "Before the substrate is destroyed, the workloads this target deployed are \
       released -- discovered in the target's declared namespaces, removed by name, and \
       waited on until their pods are gone -- so a provider is never asked to drop \
       durable application state while the workloads that own it may still be running. A \
       destroy that cannot establish that the workloads are gone stops before the \
       substrate: it destroys nothing, claims no absence, and exits 1 naming the \
       namespace, the kind and the operation that failed. The precondition does not \
       apply when there is no cluster to release from (the substrate is absent, or the \
       cluster cannot be reached), nor to a declared namespace that does not exist: a \
       workload cannot be running without its namespace, so a target whose workloads \
       were never deployed is destroyed without an override, while a namespace that \
       exists is still read and a namespace whose existence cannot be established is \
       still refused. `--accept-unreleased` destroys anyway, recording that the absence \
       check, not the release, decided the outcome."
  ; `P
      "A target whose Terraform state cannot be listed is refused, not destroyed: the \
       listing is what tells `terraform output` apart from a confirmed absence, so a \
       read that failed while the state was readable enough to publish outputs is the \
       shape of a transient or an authorization failure. Such a destroy exits 1 having \
       destroyed nothing, and says so; a state that lists nothing is a confirmed \
       absence, and keeps the documented degraded destroy."
  ; `S "EXIT STATUS"
  ; `P
      "0 -- destruction reached absence and it was verified. A best-effort preparation \
       that failed or was refused does not change this (REFAC-094): each one is reported \
       on stderr as a warning."
  ; `P
      "1 -- destruction did not reach its postcondition: it failed, it was blocked by a \
       declared guarantee, the application workloads could not be established as \
       released (nothing was destroyed, and nothing is claimed absent), the state could \
       not be listed (nothing was destroyed, and no absence is claimed), absence could \
       not be verified, or the elevated bootstrap access could not be removed. The \
       reason is named on stderr."
  ; `P "No other code is used by this command."
  ]
;;

let cmd =
  Cmd.v
    (Cmd.info "destroy" ~doc ~man)
    Term.(
      const (fun target var_file vars action accept_unreleased ->
        Sol_cli_exit.exit_on (run ~target ~var_file ~vars ~action ~accept_unreleased ()))
      $ Cmd_cloud_tf.target_arg
      $ Cmd_cloud_tf.var_file_arg
      $ Cmd_cloud_tf.var_arg
      $ Cmd_cloud_tf.action_term
      $ Cmd_cloud_tf.accept_unreleased_flag)
;;
