type command =
  { argv : string list
  ; cwd : string
  }

type recipe =
  { label : string
  ; language : Sol_cli_compat.language
  ; build : command option
  ; launch : command
  ; artifact : string
  ; env : (string * string) list
  }

type plan =
  { builds : command list
  ; launches : recipe list
  ; redact : string list
  }

val plan
  :  ?secret_values:(string * (string * string) list) list
  -> root:string
  -> facts:Sol_cli_workspace_model.t
  -> Sol_cli_manifest.service list
  -> (plan, (string * string) list) result

val label : Sol_cli_manifest.service -> string
val build_line : command -> string
val launch_line : command -> string
val dev_registry_url : string
val dev_env : (string * string) list

type child =
  { child_label : string
  ; child_pid : int
  }

type child_failure =
  | Spawn_failed of
      { label : string
      ; message : string
      }
  | Exited of
      { label : string
      ; code : int
      }
  | Signaled of
      { label : string
      ; signal : int
      }
  | Interrupted of int

val child_failure_to_string : child_failure -> string
val interrupt_exit_code : int -> int
val launch : output:Unix.file_descr -> recipe -> (child, child_failure) result

val launch_all
  :  output:(recipe -> Unix.file_descr)
  -> recipe list
  -> (child list, child_failure) result

val invoke : event:string option -> recipe -> (int, child_failure) result
val terminate : child list -> unit

val supervise
  :  ?on_status:(child -> Unix.process_status -> unit)
  -> child list
  -> (unit, child_failure) result
