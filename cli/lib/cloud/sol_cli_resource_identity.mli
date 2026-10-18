type ownership =
  | Direct
  | Direct_not_recoverable of string
  | In_cluster of string
  | Synthetic of string
  | External_by_contract of string

type entry =
  { address : string
  ; resource_class : string
  ; observed_as : string
  ; ownership : ownership
  ; identity : string
  ; import_identity : string
  }

type type_rule =
  { terraform_type : string
  ; ownership : ownership
  }

val gcp : cluster_name:string -> project_id:string option -> entry list
val aws : cluster_name:string -> entry list
val type_rules : type_rule list
val ownership_kind : ownership -> string
val ownership_reason : ownership -> string
val is_direct : entry -> bool
val recoverable : entry -> bool
