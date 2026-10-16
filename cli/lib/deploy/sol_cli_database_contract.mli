(** Product-owned declaration, not qualification policy. No claims/verdicts or provider reads. *)
type definition

type projection

val definition : revision:string -> (definition, string) result
val definition_json : definition -> Yojson.Safe.t

(** Producer self-consistency: the installed producer accepts only its own compiled
    definition. Independent readers use [Sol_cli_database_contract_data.read_definition]
    for schema decoding, preserving the verified candidate's values. *)
val read_definition : Yojson.Safe.t -> (definition, string) result

val revision : definition -> string
val digest : definition -> string

(** Builds the entire target plan through the existing selection/planning owners.
    No arbitrary workload list can be supplied. Images are unused declaration placeholders;
    this operation does not inspect a cluster, execute Terraform or render observations. *)
val project
  :  definition:definition
  -> requested_target:string
  -> config:Sol_cli_config.t
  -> facts:Sol_cli_workspace_model.t
  -> (projection, string) result

val projection_json : projection -> Yojson.Safe.t
