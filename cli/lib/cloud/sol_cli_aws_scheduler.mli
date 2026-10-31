type output = Sol_cli_aws_lambda_common.output

type request =
  { profile : string option
  ; region : string
  ; unit : string
  ; function_name : string
  ; schedule : string
  ; timezone : string option
  ; role_arn : string
  ; run : string list -> (output, string) result
  }

type release =
  { schedule_name : string
  ; expression : string
  ; timezone : string
  ; role_arn : string
  ; target_arn : string
  }

val to_json : release -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (release, string) result
val deploy : request -> (release, string) result
val destroy : request -> release -> (unit, string) result
