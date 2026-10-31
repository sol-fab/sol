type capability =
  | Secret_access
  | Message_publish
  | Message_subscribe
  | Object_read
  | Object_write
  | Function_invoke

let capability_to_string = function
  | Secret_access -> "secret"
  | Message_publish -> "message.publish"
  | Message_subscribe -> "message.subscribe"
  | Object_read -> "object.read"
  | Object_write -> "object.write"
  | Function_invoke -> "function.invoke"
;;

let resource_capabilities = function
  | "queue" -> [ Message_publish; Message_subscribe ]
  | "object_store" -> [ Object_read; Object_write ]
  | _ -> []
;;

type requirement =
  { capability : capability
  ; resource : string
  }

type target_grant =
  { unit : string
  ; capability : string
  ; resource : string
  ; namespace : string
  }

type serverless_unit =
  { unit : string
  ; requirements : requirement list
  }

type scheduler_unit =
  { unit : string
  ; function_name : string
  }

let target_grant_to_json (grant : target_grant) =
  `Assoc
    [ "unit", `String grant.unit
    ; "capability", `String grant.capability
    ; "resource", `String grant.resource
    ; "namespace", `String grant.namespace
    ]
;;

let requirement ~capability ~resource = { capability; resource }
let invoke_requirement resource = { capability = Function_invoke; resource }
let secret_capability = "secret"
let secret_requirement resource = { capability = Secret_access; resource }

let requirement_to_json (requirement : requirement) =
  `Assoc
    [ "capability", `String (capability_to_string requirement.capability)
    ; "resource", `String requirement.resource
    ]
;;

let serverless_unit_to_json (unit : serverless_unit) =
  `Assoc
    [ "unit", `String unit.unit
    ; "requirements", `List (List.map requirement_to_json unit.requirements)
    ]
;;

let scheduler_unit_to_json (unit : scheduler_unit) =
  `Assoc [ "unit", `String unit.unit; "function_name", `String unit.function_name ]
;;

let annotation_key = "sol.dev/grants"
let tag ~capability ~resource = capability ^ "/" ^ resource
let tag_of_secret_key key = tag ~capability:secret_capability ~resource:key

let split_tag tag =
  match String.index_opt tag '/' with
  | None -> "", tag
  | Some i -> String.sub tag 0 i, String.sub tag (i + 1) (String.length tag - i - 1)
;;

let capability_of_tag value = fst (split_tag value)
let resource_of_tag value = snd (split_tag value)

let encode_tags tags =
  `List (List.map (fun tag -> `String tag) tags) |> Yojson.Safe.to_string
;;

let decode_tags value =
  match Yojson.Safe.from_string value with
  | `List items ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | `String tag :: rest -> collect (tag :: acc) rest
      | _ :: _ -> Error "grant annotation must be a JSON array of strings"
    in
    collect [] items
  | _ -> Error "grant annotation must be a JSON array of strings"
  | exception Yojson.Json_error message ->
    Error ("grant annotation is not JSON: " ^ message)
;;
