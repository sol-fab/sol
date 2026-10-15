val of_config
  :  workspace:string
  -> Sol_cli_config.t
  -> ((string * string) list, string) result

val var_file
  :  cwd:string
  -> workspace_root:string
  -> flag:string option
  -> target:string option
  -> string option

val of_target
  :  strict:bool
  -> workspace:string
  -> string
  -> ((string * string) list * Sol_cli_config.t, string) result

val resolved : string -> var_files:string list -> vars:string list -> string option
