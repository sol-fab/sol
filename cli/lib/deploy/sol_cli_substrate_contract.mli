type verdict = Sol_cli_installation.verdict =
  | Established
  | Unmet of string
  | Unknown of string

type input =
  | Cluster
  | Registry
  | Kafka
  | Postgres
  | Observability
  | Domain

val all : input list
val name : input -> string
val statement : input -> string

type cluster =
  [ `Reachable
  | `Unmet of string
  | `Unknown of string
  ]

type observations =
  { cluster : cluster
  ; registry : string option
  ; base_domain : string option
  }

val evaluate : observations -> (input * verdict) list
val lines : observations -> (string * string) list
val unmet_or_unknown : (input * verdict) list -> (input * verdict) list
