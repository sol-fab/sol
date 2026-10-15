type t = Production_single_region

type platform_shape =
  | Local
  | Durable

val platform_shape_to_string : platform_shape -> string
val version : t -> int
val to_string : t -> string
val of_string : string -> (t, string) result
val of_selection : string -> (t, string) result

type capability =
  | Qualified_substrate
  | Qualified_versions
  | Direct_apply_authority
  | Remote_state
  | Scoped_operator_identities
  | Alert_delivery
  | Immutable_artifacts
  | Credential_posture
  | Workload_availability
  | Postgres_durability
  | Kafka_durability

val capability_to_string : capability -> string
val capability_description : capability -> string

type workload_capability =
  | Long_running
  | Postgres
  | Kafka

val requirements : t -> workload_capability list -> capability list

type capacity_envelope =
  { largest_pod_vcpu : int
  ; min_vcpu_per_node : int
  ; min_memory_gib_per_node : int
  ; platform_vcpu : int
  ; platform_memory_gib : int
  }

type node_shape =
  { instance_type : string
  ; vcpu_per_node : int
  ; memory_gib_per_node : int
  ; nodes : int
  }

val platform_capacity_envelope : capacity_envelope
val recommended_node_shape : node_shape

val capacity_shortfall
  :  envelope:capacity_envelope
  -> shape:node_shape
  -> headroom_nodes:int
  -> string list

val satisfies_capacity
  :  envelope:capacity_envelope
  -> shape:node_shape
  -> headroom_nodes:int
  -> (unit, string) result

val node_shape_vars : node_shape -> (string * string) list
