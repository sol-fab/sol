type prerequisite =
  { version : int
  ; name : string
  }

type status_row =
  { version : int
  ; name : string
  ; applied : bool
  ; applied_at : string option
  ; recorded_checksum : string option
  ; content_checksum : string option
  }

type drift =
  { version : int
  ; name : string
  ; recorded_checksum : string
  ; content_checksum : string
  }

type applied_status =
  { applied : int list
  ; drifted : drift list
  }

val default_dir : string
val postgres_identifier_max_bytes : int
val table_name : workspace:string -> string
val table_length_error : table:string -> string option
val parse_version : string -> (int * string) option
val required : dir:string -> (prerequisite list, string) result
val required_if_present : dir:string -> (prerequisite list, string) result
val drift_of_row : status_row -> drift option
val parse_status_json : string -> (applied_status, string) result
val unsatisfied : required:prerequisite list -> applied:int list -> prerequisite list
val to_string : prerequisite -> string
val pending_files : applied:int list -> (string * string) list -> (string * string) list
val drift_message : drift -> string
val status_json : table:string -> status_row list -> string

val evidence_report
  :  waiting:(string * string option) option
  -> logs:string option
  -> string option

val applied_status_of_rows : status_row list -> applied_status
