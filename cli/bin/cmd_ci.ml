open Cmdliner

let next_steps =
  {|
Next steps:

  1. Set the repository variables the workflow reads (Settings -> Secrets and
     variables -> Actions -> Variables):
       SOL_VERSION                      the Sol release that generated this workspace
       SOL_TARGET                       <env>/<provider>/<region>, declared in sol/environments.yml
       SOL_REGISTRY                     image registry prefix
       SOL_DEPLOY_ROLE_ARN              AWS: the target's deploy identity (OIDC-assumed)
       SOL_DEPLOY_SERVICE_ACCOUNT       GCP: the deploy service account (Workload Identity)
       SOL_AUTHORIZATION_ROLE_ARN       AWS: the target's fenced authorization reconciler
       SOL_AUTHORIZATION_SERVICE_ACCOUNT GCP: the target's reconciler service account
  2. Bootstrap the target once if it is cold: a target needs a declared
     `kube_context` and its registry repositories before this workflow can reach
     it. Run `sol deploy <target>` once from a machine with the provisioning
     identity, add the printed `kube_context`, then enable CI.
  3. Configure the provider-side OIDC trust for those identities (docs/deployment/ci.md).
     No long-lived cloud credentials are stored in the repository.
  4. Protect the `sol-authorization` environment with required reviewers
     (Settings -> Environments). The `authorize` job runs under it, so adopting a
     workload cloud grant is a reviewed action separate from the deploy.

  The workflow installs the release named by SOL_VERSION — it never builds Sol
  from the workspace — then builds and pushes images, applies migrations and
  runs the same `sol deploy <target>` lifecycle as local execution. It never
  infers a target. Secret values are seeded out of band with
  `sol secret set <TARGET> <domain>/<unit>/<KEY>`. Resource credentials are delivered
  through the target's resource bindings.
|}
;;

let init platform ~force =
  let platform = String.lowercase_ascii platform in
  if not (String.equal platform "github")
  then
    Error
      (Printf.sprintf
         "unsupported CI provider %S; only \"github\" is supported today"
         platform)
  else (
    match Sol_cli_ci.init_github ~force ~cwd:(Sys.getcwd ()) with
    | Error message -> Error message
    | Ok outcome ->
      if outcome.written
      then Sol_cli_report.app "Wrote %s\n" Sol_cli_ci.target_rel
      else Sol_cli_report.app "%s is already up to date\n" Sol_cli_ci.target_rel;
      Sol_cli_report.app_block next_steps;
      Ok ())
;;

let run init platform force =
  Sol_cli_exit.exit_on (init platform ~force |> Sol_cli_exit.of_msg)
;;

let platform_arg =
  Arg.(
    required
    & pos 0 (some Sol_cli_args.text) None
    & info [] ~docv:"PROVIDER" ~doc:"CI provider to initialise. Supported: $(b,github).")
;;

let force_arg =
  Arg.(
    value
    & flag
    & info
        [ "force" ]
        ~doc:
          "Overwrite an existing workflow that differs from the supported one. Without \
           it, a differing file is left untouched and the command refuses. A file that \
           exists but cannot be read refuses either way — fix its permissions or remove \
           it, then re-run.")
;;

let init_cmd =
  Cmd.v
    (Cmd.info "init" ~doc:"Write the supported CI workflow into the current workspace")
    Term.(const (run init) $ platform_arg $ force_arg)
;;

let cmd = Cmd.group (Cmd.info "ci" ~doc:"Continuous-integration setup") [ init_cmd ]
