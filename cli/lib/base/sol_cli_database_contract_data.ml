open Result.Syntax

let string s = `String s
let fields xs = `Assoc xs

(* Product-owned declaration wire format. Shared by the producer and independent readers.
   Closed JSON grammar: no floats, duplicate keys, or serializer-dependent extensions. *)
let rec canonical = function
  | `Assoc values ->
    let keys = List.map fst values in
    if List.length keys <> List.length (List.sort_uniq compare keys)
    then Error "duplicate JSON field"
    else
      let* values =
        Sol_cli_result.map_list
          (fun (k, v) ->
             let* v = canonical v in
             Ok (k, v))
          values
      in
      Ok (`Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) values))
  | `List values ->
    let* values = Sol_cli_result.map_list canonical values in
    Ok (`List values)
  | (`String _ | `Int _ | `Bool _ | `Null) as value -> Ok value
  | _ -> Error "unsupported canonical JSON value"
;;

let hash value = Digestif.SHA256.(to_hex (digest_string (Yojson.Safe.to_string value)))

let seal payload =
  let* payload = canonical payload in
  Ok (fields [ "digest", string (hash payload); "declaration", payload ])
;;

(* These are wire types, not qualification policy or renderer observations. Unknown
   schema members are refused until their meaning has been reviewed by the reader. *)
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

let exact names = function
  | `Assoc pairs when List.sort compare (List.map fst pairs) = List.sort compare names ->
    Ok ()
  | _ -> Error "unsupported declaration field set"
;;

let get name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> Ok value
     | None -> Error ("missing declaration field: " ^ name))
  | _ -> Error "expected declaration object"
;;

let text name json =
  let* value =
    Sol_cli_json.require ~what:"database contract" [ name ] Sol_cli_json.string json
  in
  if String.trim value = "" then Error ("empty declaration field: " ^ name) else Ok value
;;

let list decode = function
  | `List xs -> Sol_cli_result.map_list decode xs
  | _ -> Error "expected declaration list"
;;

let nullable decode = function
  | `Null -> Ok None
  | v ->
    let* v = decode v in
    Ok (Some v)
;;

let texts json =
  list
    (function
      | `String s when String.trim s <> "" -> Ok s
      | _ -> Error "invalid declaration string")
    json
;;

let hex n s =
  String.length s = n
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s
;;

let envelope json =
  let* json = canonical json in
  let* () = exact [ "digest"; "declaration" ] json in
  let* digest = text "digest" json in
  let* value = get "declaration" json in
  let* schema = get "schema" value in
  if schema <> `Int 1
  then Error "unsupported database contract schema"
  else if (not (hex 64 digest)) || hash value <> digest
  then Error "database declaration digest mismatch"
  else Ok (digest, value)
;;

let address json =
  let* () = exact [ "namespace"; "name" ] json in
  let* namespace = text "namespace" json in
  let* name = text "name" json in
  Ok { namespace; name }
;;

let ca json =
  let* () = exact [ "configmap"; "key"; "file" ] json in
  let* configmap = get "configmap" json in
  let* configmap = address configmap in
  let* key = text "key" json in
  let* file = text "file" json in
  Ok { configmap; key; file }
;;

let read_definition json =
  let* digest, value = envelope json in
  let* () =
    exact [ "schema"; "product_revision"; "ca"; "credentials"; "rendering" ] value
  in
  let* revision = text "product_revision" value in
  let* ca = get "ca" value in
  let* () = exact [ "key"; "file" ] ca in
  let* ca_key = text "key" ca in
  let* ca_file = text "file" ca in
  let* credentials = get "credentials" value in
  let* () = exact [ "key"; "dml_class"; "ddl_class" ] credentials in
  let* credential_key = text "key" credentials in
  let* dml_class = text "dml_class" credentials in
  let* ddl_class = text "ddl_class" credentials in
  let* rendering = get "rendering" value in
  let* () =
    exact [ "ca_volume_name"; "volume_identity"; "migration_container" ] rendering
  in
  let* ca_volume_name = text "ca_volume_name" rendering in
  let* volume_identity = text "volume_identity" rendering in
  let* migration_container = text "migration_container" rendering in
  if not (hex 40 revision)
  then Error "invalid product revision"
  else
    Ok
      { revision
      ; digest
      ; ca_key
      ; ca_file
      ; credential_key
      ; dml_class
      ; ddl_class
      ; ca_volume_name
      ; volume_identity
      ; migration_container
      }
;;

let migration json =
  let* () =
    exact
      [ "context"
      ; "namespace"
      ; "resource"
      ; "container"
      ; "job_identity"
      ; "credential"
      ; "ca"
      ]
      json
  in
  let* context = text "context" json in
  let* namespace = text "namespace" json in
  let* resource = text "resource" json in
  let* container = text "container" json in
  let* job_identity = text "job_identity" json in
  let* credential = get "credential" json in
  let* credential = address credential in
  let* ca_value = get "ca" json in
  let* ca = nullable ca ca_value in
  Ok { context; namespace; resource; container; job_identity; credential; ca }
;;

let database json =
  let* () =
    exact
      [ "resource"
      ; "ownership"
      ; "credential_authority"
      ; "administrative_references"
      ; "migration"
      ]
      json
  in
  let* resource = text "resource" json in
  let* ownership = text "ownership" json in
  let* authority = get "credential_authority" json in
  let* credential_authority = nullable address authority in
  let* refs = get "administrative_references" json in
  let* administrative_references = list address refs in
  let* m = get "migration" json in
  let* migration = migration m in
  Ok { resource; ownership; credential_authority; administrative_references; migration }
;;

let workload json =
  let* () =
    exact
      [ "subject"
      ; "resource"
      ; "namespace"
      ; "name"
      ; "declared_uses"
      ; "database"
      ; "consuming_containers"
      ; "credential"
      ; "ca"
      ]
      json
  in
  let* subject = text "subject" json in
  let* resource = text "resource" json in
  let* namespace = text "namespace" json in
  let* name = text "name" json in
  let* v = get "declared_uses" json in
  let* declared_uses = texts v in
  let* v = get "database" json in
  let* database =
    nullable
      (function
        | `String s when s <> "" -> Ok s
        | _ -> Error "invalid database binding")
      v
  in
  let* v = get "consuming_containers" json in
  let* consuming_containers = texts v in
  let* () =
    if List.mem resource [ "deployment"; "rollout"; "cronjob" ]
    then Ok ()
    else Error "unsupported workload resource"
  in
  let* v = get "credential" json in
  let* credential = nullable address v in
  let* v = get "ca" json in
  let* ca = nullable ca v in
  Ok
    { subject
    ; resource
    ; namespace
    ; name
    ; declared_uses
    ; database
    ; consuming_containers
    ; credential
    ; ca
    }
;;

let read_specimen json =
  let* digest, value = envelope json in
  let* () =
    exact
      [ "schema"
      ; "product_revision"
      ; "definition_digest"
      ; "workspace"
      ; "target"
      ; "requested_target"
      ; "database"
      ; "workloads"
      ]
      value
  in
  let* revision = text "product_revision" value in
  let* definition_digest = text "definition_digest" value in
  let* workspace = text "workspace" value in
  let* target = text "target" value in
  let* requested_target = text "requested_target" value in
  let* v = get "database" value in
  let* database = nullable database v in
  let* v = get "workloads" value in
  let* workloads = list workload v in
  if not (hex 40 revision && hex 64 definition_digest)
  then Error "invalid declaration identity"
  else
    Ok
      { revision
      ; digest
      ; definition_digest
      ; workspace
      ; target
      ; requested_target
      ; database
      ; workloads
      }
;;
