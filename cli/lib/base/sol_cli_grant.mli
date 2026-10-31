type capability =
  | Secret_access
  | Message_publish
  | Message_subscribe
  | Object_read
  | Object_write

val capability_to_string : capability -> string
val resource_capabilities : string -> capability list

type requirement =
  { capability : capability
  ; resource : string
  }

type serverless_unit =
  { unit : string
  ; requirements : requirement list
  }

val requirement : capability:capability -> resource:string -> requirement
val secret_requirement : string -> requirement
val requirement_to_json : requirement -> Yojson.Safe.t
val serverless_unit_to_json : serverless_unit -> Yojson.Safe.t
val secret_capability : string
val annotation_key : string
val tag : capability:string -> resource:string -> string
val tag_of_secret_key : string -> string
val capability_of_tag : string -> string
val resource_of_tag : string -> string
val encode_tags : string list -> string
val decode_tags : string -> (string list, string) result
