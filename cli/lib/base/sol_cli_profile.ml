type t = Production_single_region

type platform_shape =
  | Local
  | Durable

let platform_shape_to_string = function
  | Local -> "local"
  | Durable -> "durable"
;;

let version Production_single_region = 1
let selection_name Production_single_region = "production-single-region"
let to_string t = Printf.sprintf "%s/v%d" (selection_name t) (version t)
let all = [ Production_single_region ]

let known_selections () =
  all |> List.map selection_name |> List.map (Printf.sprintf "%S") |> String.concat ", "
;;

let of_selection s =
  match List.find_opt (fun t -> selection_name t = s) all with
  | Some t -> Ok t
  | None ->
    Error
      (Printf.sprintf "unknown profile %S (known profiles: %s)" s (known_selections ()))
;;

let of_string s =
  match List.find_opt (fun t -> to_string t = s) all with
  | Some t -> Ok t
  | None -> Error (Printf.sprintf "unknown profile identity %S" s)
;;

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

let capability_to_string = function
  | Qualified_substrate -> "qualified_substrate"
  | Qualified_versions -> "qualified_versions"
  | Direct_apply_authority -> "direct_apply_authority"
  | Remote_state -> "remote_state"
  | Scoped_operator_identities -> "scoped_operator_identities"
  | Alert_delivery -> "alert_delivery"
  | Immutable_artifacts -> "immutable_artifacts"
  | Credential_posture -> "credential_posture"
  | Workload_availability -> "workload_availability"
  | Postgres_durability -> "postgres_durability"
  | Kafka_durability -> "kafka_durability"
;;

let capability_description = function
  | Qualified_substrate -> "qualified provider/substrate"
  | Qualified_versions -> "qualified version set"
  | Direct_apply_authority -> "direct apply reconciliation authority"
  | Remote_state -> "recoverable remote infrastructure state"
  | Scoped_operator_identities -> "scoped operator identity"
  | Alert_delivery -> "alert delivery to an owner"
  | Immutable_artifacts -> "immutable artifact identity"
  | Credential_posture -> "workload credential posture"
  | Workload_availability -> "workload availability"
  | Postgres_durability -> "Postgres durability"
  | Kafka_durability -> "Kafka durability"
;;

type workload_capability =
  | Long_running
  | Postgres
  | Kafka

let guarantee_of_use = function
  | Long_running -> Workload_availability
  | Postgres -> Postgres_durability
  | Kafka -> Kafka_durability
;;

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

(* The node-shape sizing contract for Sol's own platform components. The budget
   is derived from chart defaults Sol does not declare (notably the loki chunks
   cache), so this is a declared assumption, not an observed property of a
   target environment: `internal/ci/check_node_shape_fits_platform.py` holds the
   provider driver defaults against it (FND-0066), and the preflight does not
   claim it for a target. *)
let platform_capacity_envelope =
  { largest_pod_vcpu = 2
  ; min_vcpu_per_node = 4
  ; min_memory_gib_per_node = 8
  ; platform_vcpu = 10
  ; platform_memory_gib = 20
  }
;;

let recommended_node_shape =
  { instance_type = "m6i.xlarge"; vcpu_per_node = 4; memory_gib_per_node = 16; nodes = 4 }
;;

let capacity_shortfall ~envelope ~shape ~headroom_nodes =
  let headroom_nodes = max 0 headroom_nodes in
  let schedulable_nodes = shape.nodes - headroom_nodes in
  let per_node =
    if
      shape.vcpu_per_node >= envelope.min_vcpu_per_node
      && shape.memory_gib_per_node >= envelope.min_memory_gib_per_node
    then []
    else
      [ Printf.sprintf
          "each node must offer at least %d vCPU / %d GiB so the platform's largest pod \
           (%d vCPU) still fits on one node after system reservations, but this shape \
           offers %d vCPU / %d GiB"
          envelope.min_vcpu_per_node
          envelope.min_memory_gib_per_node
          envelope.largest_pod_vcpu
          shape.vcpu_per_node
          shape.memory_gib_per_node
      ]
  in
  let cluster =
    if schedulable_nodes < 1
    then
      [ Printf.sprintf
          "%d node(s) with %d reserved for node-failure headroom leaves no schedulable \
           capacity at all"
          shape.nodes
          headroom_nodes
      ]
    else (
      let vcpu = schedulable_nodes * shape.vcpu_per_node in
      let memory = schedulable_nodes * shape.memory_gib_per_node in
      let check value needed unit =
        if value < needed
        then
          [ Printf.sprintf
              "%d %s left after node-failure headroom but the platform needs %d"
              value
              unit
              needed
          ]
        else []
      in
      check vcpu envelope.platform_vcpu "vCPU"
      @ check memory envelope.platform_memory_gib "GiB")
  in
  per_node @ cluster
;;

let satisfies_capacity ~envelope ~shape ~headroom_nodes =
  match capacity_shortfall ~envelope ~shape ~headroom_nodes with
  | [] -> Ok ()
  | shortfalls ->
    Error
      (Printf.sprintf
         "%d x %s (%d vCPU / %d GiB each) cannot host the production platform: %s"
         shape.nodes
         shape.instance_type
         shape.vcpu_per_node
         shape.memory_gib_per_node
         (String.concat "; " shortfalls))
;;

let node_shape_vars shape =
  [ "node_instance_types", Printf.sprintf "[%S]" shape.instance_type
  ; "node_desired_size", string_of_int shape.nodes
  ; "node_min_size", string_of_int (max 1 (shape.nodes - 1))
  ; "node_max_size", "10"
  ]
;;

let requirements Production_single_region uses =
  [ Qualified_substrate
  ; Qualified_versions
  ; Direct_apply_authority
  ; Remote_state
  ; Scoped_operator_identities
  ; Alert_delivery
  ; Immutable_artifacts
  ; Credential_posture
  ]
  @ List.map guarantee_of_use (List.sort_uniq compare uses)
;;
