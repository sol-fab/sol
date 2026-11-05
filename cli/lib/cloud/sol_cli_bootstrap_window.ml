(* The provider-neutral bootstrap-window capability surface.

   Sol installs the privileged platform under a temporary cluster-admin
   elevation. On every provider the window is established by the same question
   -- can the installing identity escalate and bind ClusterRoles? -- and its
   removal is demonstrated by the successor question. The steady-state platform
   provisioner is deliberately read-only (#1870), so the successor surface is
   the read authority its diagnostics keep, never a restored mutation verb.
   Only how a provider obtains cluster access differs, so the capability
   surface and its interpretation live here rather than in each provider
   module. *)

let bootstrap_only =
  List.map
    (fun (verb, resource) -> { Sol_cli_capability.verb; resource })
    [ "escalate", "clusterroles"; "bind", "clusterroles" ]
;;

let successor =
  List.map
    (fun (verb, resource) -> { Sol_cli_capability.verb; resource })
    [ "get", "namespaces"; "get", "clusterroles"; "get", "storageclasses" ]
;;

let can_i ~run { Sol_cli_capability.verb; resource } =
  match run [ "kubectl"; "auth"; "can-i"; verb; resource ] with
  | Ok output ->
    Sol_cli_capability.capability_answer_of_can_i_output
      ~exit_code:0
      ~stdout:output.Sol_cli_process.stdout
      ~stderr:output.Sol_cli_process.stderr
  | Error (Sol_cli_process.Non_zero { exit_code; stdout; stderr }) ->
    Sol_cli_capability.capability_answer_of_can_i_output ~exit_code ~stdout ~stderr
  | Error error ->
    Sol_cli_capability.Indeterminate (Sol_cli_process.error_to_string error)
;;

let probe ~run capabilities =
  List.map (fun capability -> capability, can_i ~run capability) capabilities
;;

let permitted probes =
  List.exists (fun (_, answer) -> Sol_cli_capability.answer_is_permitted answer) probes
;;

let indeterminate probes = List.filter_map Sol_cli_capability.indeterminate_reason probes

let control_failure ~permitted indeterminate =
  let stop =
    "The run stops rather than proceeding to a verification that can only come back \
     undetermined."
  in
  if not permitted
  then
    Printf.sprintf
      "the bootstrap window never showed a capability permitted, so a later denial could \
       not be told apart from a credential that never worked. %s"
      stop
  else
    Printf.sprintf
      "the bootstrap window showed a capability permitted but also an indeterminate \
       probe (%s), which a later denial could not be told apart from. %s"
      (indeterminate
       |> List.map (fun (capability, why) -> capability ^ ": " ^ why)
       |> String.concat ", ")
      stop
;;
