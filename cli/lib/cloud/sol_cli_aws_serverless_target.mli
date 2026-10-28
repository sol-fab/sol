val deploy
  :  target:Sol_cli_config.target
  -> config:Sol_cli_config.t
  -> project:string
  -> service:Sol_cli_manifest.service
  -> image:string
  -> record:string
  -> (Sol_cli_aws_lambda.release, string) result
