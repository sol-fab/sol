type output =
  { stdout : string
  ; stderr : string
  }

val run : string list -> (output, string) result
val http : url:string -> token:string option -> (int * string, string) result
