(** Durable MECHANISM evidence only. No production candidate or release path. *)
type t

type reference = private
  { digest : string
  ; size : int
  ; kind : string
  }

type error =
  { stage : string
  ; diagnostic : string
  }

type boundary =
  | Temp_written
  | File_synced
  | Published
  | Directory_synced

type summary = private
  { assessment : string
  ; passed : bool
  ; manifest : reference
  }

type captured = private
  { run : Qual_domain.run
  ; subject : string
  ; payload : Yojson.Safe.t
  ; reference : reference
  }

val read_capture
  :  directory:string
  -> run:Qual_domain.run
  -> reference
  -> (captured, error) result

(** Known secret inputs must be registered before any capture. Sensitive structured
    fields are also removed. No registered secret bytes are written, including temporaries.
    Unknown-secret detection is not provided; callers must choose safe projections.
    [fault] is an explicit offline fault-injection hook, never a production option. *)
val open_store
  :  ?fault:(boundary -> unit)
  -> directory:string
  -> run:Qual_domain.run
  -> secrets:string list
  -> unit
  -> (t, error) result

val close : t -> unit
val assessments : t -> (reference list, error) result

val start_assessment
  :  t
  -> reason:string
  -> previous:reference list
  -> required_captures:(string * string) list
  -> (reference, error) result

val capture : t -> subject:string -> payload:Yojson.Safe.t -> (reference, error) result

(** A separately required capture slot must be declared before any observations.
    The pair is (capture ID, subject); missing slots block seal after restart. *)
val capture_required
  :  t
  -> id:string
  -> subject:string
  -> payload:Yojson.Safe.t
  -> (reference, error) result

val diagnostic : t -> string -> (reference, error) result

val record_verdict
  :  t
  -> Qual_domain.verdict
  -> observations:reference list
  -> (reference, error) result

val seal
  :  t
  -> obligations:Qual_domain.obligations
  -> requests:Qual_domain.request list
  -> verdicts:reference list
  -> captures:reference list
  -> (reference, error) result

val verify_manifest
  :  directory:string
  -> run:Qual_domain.run
  -> obligations:Qual_domain.obligations
  -> required_captures:(string * string) list
  -> reference
  -> (summary, error) result

val digest : reference -> string
val reference_json : reference -> Yojson.Safe.t
val reference_of_json : Yojson.Safe.t -> (reference, error) result
