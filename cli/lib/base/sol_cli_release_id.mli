type workload =
  { domain : string
  ; name : string
  ; primitive : string
  ; image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; uses : string list
  ; external_secret_refs : (string * string * string) list
  ; schedule : string option
  ; scheduled_concurrency : string
  ; backoff_limit : int
  ; replicas : int
  ; availability : string
  ; consumes_kafka : bool
  ; cpu : string
  ; memory : string
  ; extra_labels : (string * string) list
  ; volumes : (string * string * string * string) list
  ; rollout : string
  ; ingress_host : string option
  ; ingress_path : string option
  ; cluster_issuer : string
  ; calls : (string * string * string * string) list
  }

type contract_fact =
  { subject : string
  ; topic : string
  ; partitions : int
  ; key : string option
  ; schema_digest : string
  }

type content =
  { workspace : string
  ; environment : string option
  ; workloads : workload list
  ; contract : contract_fact list
  }

type owned_object =
  { resource : string
  ; namespace : string
  ; name : string
  ; uid : string
  }

type recorded_workload =
  { spec : workload
  ; applied_by : string
  ; owned : owned_object list
  }

type t

val of_content : content -> t

val of_boundary
  :  workspace:string
  -> environment:string option
  -> contract:contract_fact list
  -> deployed:workload list
  -> inherited:(workload * string) list
  -> t

val of_recorded_boundary
  :  workspace:string
  -> environment:string option
  -> contract:contract_fact list
  -> recorded_workload list
  -> t

val to_string : t -> string
val of_string : string -> (t, string) result
val canonical_string : content -> string
val encoding_version : string
