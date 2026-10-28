type cmd =
  { argv : string list
  ; cwd : string option
  ; env : (string * string) list option
  ; inherit_env : bool
  ; timeout_s : float option
  ; redact : string list
  }

type failure =
  { exit_code : int
  ; stdout : string
  ; stderr : string
  }

type output =
  { stdout : string
  ; stderr : string
  }

type error =
  | Spawn_failed of string
  | Non_zero of failure
  | Timeout of float

val cmd
  :  ?cwd:string
  -> ?env:(string * string) list
  -> ?inherit_env:bool
  -> ?timeout_s:float
  -> ?redact:string list
  -> string list
  -> cmd

val run : ?echo:bool -> cmd -> (output, error) result

type background

val join : background -> unit
val spawn : ?output:Unix.file_descr -> cmd -> (background, error) result
val spawn_detached : ?output:Unix.file_descr -> cmd -> (background, error) result
val pid : background -> int
val stop : background -> unit
val run_shell : ?echo:bool -> string -> (output, error) result
val completed : exit_code:int -> stdout:string -> stderr:string -> (output, error) result
val resolve_program : string -> string
val apply_redactions : string list -> string -> string
val failure_message : failure -> string
val error_to_string : error -> string
val echo_cmd : string list -> string list -> unit
