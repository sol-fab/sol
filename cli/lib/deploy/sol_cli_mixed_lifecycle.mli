type backends =
  { serverless : Sol_cli_manifest.service list
  ; kubernetes : Sol_cli_manifest.service list
  }

val split : Sol_cli_config.target -> Sol_cli_manifest.service list -> backends

val run
  :  target:Sol_cli_config.target
  -> services:Sol_cli_manifest.service list
  -> authorize:(unit -> (unit, string) result)
  -> serverless:(Sol_cli_manifest.service list -> (unit, string) result)
  -> kubernetes:(Sol_cli_manifest.service list -> (unit, string) result)
  -> (unit, string) result
