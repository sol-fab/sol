(** Product-owned schema-1 wire codec. No planning, rendering or qualification policy.
    The producer and qualification reader share this codec, not execution paths. *)
val canonical : Yojson.Safe.t -> (Yojson.Safe.t, string) result

val seal : Yojson.Safe.t -> (Yojson.Safe.t, string) result

type address =
  { namespace : string
  ; name : string
  }

type ca =
  { configmap : address
  ; key : string
  ; file : string
  }

type definition =
  { revision : string
  ; digest : string
  ; ca_key : string
  ; ca_file : string
  ; credential_key : string
  ; dml_class : string
  ; ddl_class : string
  ; ca_volume_name : string
  ; volume_identity : string
  ; migration_container : string
  }

type migration =
  { context : string
  ; namespace : string
  ; resource : string
  ; container : string
  ; job_identity : string
  ; credential : address
  ; ca : ca option
  }

type database =
  { resource : string
  ; ownership : string
  ; credential_authority : address option
  ; administrative_references : address list
  ; migration : migration
  }

type workload =
  { subject : string
  ; resource : string
  ; namespace : string
  ; name : string
  ; declared_uses : string list
  ; database : string option
  ; consuming_containers : string list
  ; credential : address option
  ; ca : ca option
  }

type specimen =
  { revision : string
  ; digest : string
  ; definition_digest : string
  ; workspace : string
  ; target : string
  ; requested_target : string
  ; database : database option
  ; workloads : workload list
  }

val read_definition : Yojson.Safe.t -> (definition, string) result
val read_specimen : Yojson.Safe.t -> (specimen, string) result
