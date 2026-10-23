type candidate =
  { address : string
  ; resource_class : string
  ; found : string
  ; import_identity : string
  }

type disposition =
  | Recover of candidate
  | Already_owned of
      { address : string
      ; found : string
      }
  | By_contract of
      { resource_class : string
      ; found : string
      }
  | Cannot_recover of
      { resource_class : string
      ; found : string
      ; reason : string
      }
  | Unmapped of
      { resource_class : string
      ; found : string
      }
  | Unresolved of
      { resource_class : string
      ; reason : string
      }

val dispositions
  :  entries:Sol_cli_resource_identity.entry list
  -> state_addresses:string list
  -> Sol_cli_absence.observation list
  -> disposition list

val candidate : disposition -> candidate option
val unreconciled : disposition list -> disposition list
val outcome : ?dry_run:bool -> disposition list -> string
val report : disposition list -> string
val summary : disposition list -> string

val to_json
  :  target:string
  -> dry_run:bool
  -> restored:candidate list
  -> disposition list
  -> Yojson.Safe.t
