val deploy
  :  target:Sol_cli_config.target
  -> config:Sol_cli_config.t
  -> project:string
  -> service:Sol_cli_manifest.service
  -> image:string
  -> record:string
  -> (Sol_cli_aws_lambda.release, string) result

val rollback
  :  target:Sol_cli_config.target
  -> project:string
  -> service:Sol_cli_manifest.service
  -> record:string
  -> version:string
  -> token:string
  -> (Sol_cli_aws_lambda.observed, string) result
