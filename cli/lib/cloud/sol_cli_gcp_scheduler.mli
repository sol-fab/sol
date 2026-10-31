type runner = { run : string list -> (Sol_cli_cloud_run.output, string) result }

type request =
  { project : string
  ; region : string
  ; unit : string
  ; job : string
  ; schedule : string
  ; timezone : string option
  ; service_account : string
  ; runner : runner
  }

type release =
  { name : string
  ; uri : string
  ; schedule : string
  ; timezone : string
  ; service_account : string
  }

val to_json : release -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (release, string) result
val deploy : request -> (release, string) result
val destroy : request -> release -> (unit, string) result
