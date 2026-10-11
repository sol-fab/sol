type target =
  { name : string
  ; env : string
  ; provider : Sol_cli_provider.t
  ; region : string
  ; registry : string option
  ; base_domain : string option
  ; cluster_issuer : string option
  ; letsencrypt_email : string option
  ; cluster_name : string option
  ; kube_context : string option
  ; kubeconfig : string option
  ; terraform_var_file : string option
  ; observability_backend : string option
  ; destroy_retention : string option
  ; alert_receiver_type : string option
  ; alert_receiver_url : string option
  ; alert_owner : string option
  ; alert_runbook_url : string option
  ; state_bucket : string option
  ; cluster_endpoint_cidr : string option
  ; dns_zone_ownership : string option
  ; node_failure_headroom_nodes : int option
  ; profile : Sol_cli_profile.t option
  ; provider_fields : (string * (string * string) list) list
  ; secret_authorities : (string * (string * secret_authority) list) list
  }

and secret_authority =
  | Sol_managed
  | External of
      { store : string
      ; key : string
      }

type unit_secret_resolution =
  { resolved : (string * secret_authority) list
  ; missing : string list
  ; additional : string list
  }

type index =
  { index_name : string
  ; partition_key : string option
  ; sort_key : string option
  }

(* How a resource is managed, and — when externally managed — where its
   credential comes from. The selection is atomic: see [merge_resource]. *)
type resource_ownership =
  | Ownership_sol
  | Ownership_external

type resource_binding =
  { ownership : resource_ownership
  ; store : string option
  ; keys : (string * string) list
  ; connection : (string * string) list
  ; (* Where an externally bound resource's *credential-class* values come from: class
       name -> remote path. The class is the outer dimension — one output Secret per class —
       because a contract that has classes resolves the *same* contract key to a different
       remote path per class (a database's `POSTGRES_URL` is the migrator's in `ddl` and the
       application's in `dml`). [keys] stays for contracts with no classes, where one key has
       one remote path. *)
    credentials : (string * string) list
  }

type resource =
  { name : string
  ; typ : string option
  ; partition_key : string option
  ; sort_key : string option
  ; indexes : index list
  ; size : string option
  ; omit : bool
  ; binding : resource_binding option
  }

type service =
  { name : string
  ; typ : string option
  ; path : string option
  ; uses : string list
  ; scale_min : int option
  ; scale_max : int option
  ; language : Sol_cli_compat.language option
  ; omit : bool
  }

type layer =
  { project : string option
  ; target : target option
  ; resources : resource list
  ; services : service list
  }

let target_empty =
  { name = ""
  ; env = ""
  ; provider = Sol_cli_provider.Aws
  ; region = ""
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = None
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = None
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; provider_fields = []
  ; secret_authorities = []
  }
;;

let empty = { project = None; target = None; resources = []; services = [] }

type error =
  { path : string
  ; line : int
  ; message : string
  }

let error_to_string e =
  if e.line > 0
  then Printf.sprintf "%s:%d: %s" e.path e.line e.message
  else Printf.sprintf "%s: %s" e.path e.message
;;

open Result.Syntax

let trim = String.trim

let parse_int s =
  match int_of_string_opt (trim s) with
  | Some i -> Ok (Some i)
  | None -> Error "expected integer"
;;

let parse_bool s =
  match trim s with
  | "true" -> Ok true
  | "false" -> Ok false
  | _ -> Error "expected true or false"
;;

let index_empty index_name = { index_name; partition_key = None; sort_key = None }

let upsert_by_name name key update xs =
  let rec loop acc = function
    | [] -> List.rev (update None :: acc)
    | x :: rest when name x = key -> List.rev_append acc (update (Some x) :: rest)
    | x :: rest -> loop (x :: acc) rest
  in
  loop [] xs
;;

let resource_empty name =
  { name
  ; typ = None
  ; partition_key = None
  ; sort_key = None
  ; indexes = []
  ; size = None
  ; omit = false
  ; binding = None
  }
;;

let service_empty name =
  { name
  ; typ = None
  ; path = None
  ; uses = []
  ; scale_min = None
  ; scale_max = None
  ; language = None
  ; omit = false
  }
;;

type target_field =
  | Target_registry
  | Target_base_domain
  | Target_cluster_issuer
  | Target_letsencrypt_email
  | Target_cluster_name
  | Target_kube_context
  | Target_kubeconfig
  | Target_terraform_var_file
  | Target_observability_backend
  | Target_destroy_retention
  | Target_alert_receiver_type
  | Target_alert_receiver_url
  | Target_alert_owner
  | Target_alert_runbook_url
  | Target_state_bucket
  | Target_cluster_endpoint_cidr
  | Target_node_failure_headroom_nodes
  | Target_profile
  | Target_dns_zone_ownership
  | Target_secrets

type target_key =
  | Target_field of target_field
  | Target_provider_box of Sol_cli_provider.t
  | Target_provider_owned of string * Sol_cli_provider.t
  | Target_unknown of string

let target_key_of_string s =
  match s with
  | "registry" -> Target_field Target_registry
  | "base_domain" -> Target_field Target_base_domain
  | "cluster_issuer" -> Target_field Target_cluster_issuer
  | "letsencrypt_email" -> Target_field Target_letsencrypt_email
  | "cluster_name" -> Target_field Target_cluster_name
  | "kube_context" -> Target_field Target_kube_context
  | "kubeconfig" -> Target_field Target_kubeconfig
  | "terraform_var_file" -> Target_field Target_terraform_var_file
  | "observability_backend" -> Target_field Target_observability_backend
  | "destroy_retention" -> Target_field Target_destroy_retention
  | "alert_receiver_type" -> Target_field Target_alert_receiver_type
  | "alert_receiver_url" -> Target_field Target_alert_receiver_url
  | "alert_owner" -> Target_field Target_alert_owner
  | "alert_runbook_url" -> Target_field Target_alert_runbook_url
  | "state_bucket" -> Target_field Target_state_bucket
  | "cluster_endpoint_cidr" -> Target_field Target_cluster_endpoint_cidr
  | "node_failure_headroom_nodes" -> Target_field Target_node_failure_headroom_nodes
  | "profile" -> Target_field Target_profile
  | "dns_zone_ownership" -> Target_field Target_dns_zone_ownership
  | "secrets" -> Target_field Target_secrets
  | _ ->
    (match Sol_cli_provider.owned_legacy_key s with
     | Some provider -> Target_provider_owned (s, provider)
     | None ->
       (match Sol_cli_provider.of_string s with
        | Some provider -> Target_provider_box provider
        | None -> Target_unknown s))
;;

let target_field_name = function
  | Target_registry -> "registry"
  | Target_base_domain -> "base_domain"
  | Target_cluster_issuer -> "cluster_issuer"
  | Target_letsencrypt_email -> "letsencrypt_email"
  | Target_cluster_name -> "cluster_name"
  | Target_kube_context -> "kube_context"
  | Target_kubeconfig -> "kubeconfig"
  | Target_terraform_var_file -> "terraform_var_file"
  | Target_observability_backend -> "observability_backend"
  | Target_destroy_retention -> "destroy_retention"
  | Target_alert_receiver_type -> "alert_receiver_type"
  | Target_alert_receiver_url -> "alert_receiver_url"
  | Target_alert_owner -> "alert_owner"
  | Target_alert_runbook_url -> "alert_runbook_url"
  | Target_state_bucket -> "state_bucket"
  | Target_cluster_endpoint_cidr -> "cluster_endpoint_cidr"
  | Target_node_failure_headroom_nodes -> "node_failure_headroom_nodes"
  | Target_profile -> "profile"
  | Target_dns_zone_ownership -> "dns_zone_ownership"
  | Target_secrets -> "secrets"
;;

let error_at ~path message = { path; line = 0; message }

let syntax_error_line text =
  match Yaml.Stream.parser text with
  | Error _ -> 0
  | Ok parser ->
    let rec go last =
      match Yaml.Stream.do_parse parser with
      | Error _ -> last
      | Ok (Yaml.Stream.Event.Stream_end, _) -> last
      | Ok (_, (pos : Yaml.Stream.Event.pos)) -> go (pos.end_mark.line + 1)
    in
    go 1
;;

let yaml_problem message =
  let m =
    Sol_cli_string.strip_prefix_opt ~prefix:"error calling parser: " message
    |> Option.value ~default:message
  in
  match String.index_opt m '\n' with
  | Some i -> String.sub m 0 i
  | None -> Sol_cli_string.before_opt ~needle:" character " m |> Option.value ~default:m
;;

let parse_yaml ~path text =
  match Yaml.yaml_of_string text with
  | Ok doc -> Ok doc
  | Error (`Msg message) ->
    Error
      { path
      ; line = syntax_error_line text
      ; message = "invalid YAML: " ^ yaml_problem message
      }
;;

let scalar_text : Yaml.yaml -> string option = function
  | `Scalar { Yaml.value; style; _ } ->
    let quoted =
      match style with
      | `Single_quoted | `Double_quoted -> true
      | _ -> false
    in
    (match String.trim value with
     | "" -> None
     | ("~" | "null") when not quoted -> None
     | text -> Some text)
  | _ -> None
;;

let is_null : Yaml.yaml -> bool = function
  | `Scalar _ as y -> scalar_text y = None
  | _ -> false
;;

let members
      ~path
      ~where
      ?(duplicate = fun k -> Printf.sprintf "duplicate key %S%s" k where)
  = function
  | `O { Yaml.m_members; _ } ->
    let refuse message = Error (error_at ~path message) in
    let key_of = function
      | `Scalar { Yaml.value; _ } -> Ok value
      | _ -> refuse (Printf.sprintf "expected text keys%s" where)
    in
    let no_alias k = function
      | `Alias _ ->
        refuse (Printf.sprintf "YAML aliases are not supported (%S%s)" k where)
      | _ -> Ok ()
    in
    let add seen (key, v) =
      let* seen = seen in
      let* k = key_of key in
      let* () = no_alias k v in
      if List.mem_assoc k seen then refuse (duplicate k) else Ok ((k, v) :: seen)
    in
    List.fold_left add (Ok []) m_members |> Result.map List.rev
  | y when is_null y -> Ok []
  | _ -> Error (error_at ~path (Printf.sprintf "expected a mapping%s" where))
;;

let decode_layer ~path ~context ~top_level (fields : (string * Yaml.yaml) list) =
  let error message =
    error_at ~path (if context = "" then message else context ^ ": " ^ message)
  in
  let refuse message = Error (error message) in
  let value name v =
    match v with
    | `Scalar _ ->
      scalar_text v
      |> Option.to_result ~none:(error (Printf.sprintf "missing value for %s" name))
    | _ -> refuse (Printf.sprintf "expected a single value for %s" name)
  in
  let int_value name v =
    let* s = value name v in
    parse_int s |> Result.map_error (fun msg -> error (msg ^ " for " ^ name))
  in
  let bool_value name v =
    let* s = value name v in
    parse_bool s |> Result.map_error (fun msg -> error (msg ^ " for " ^ name))
  in
  let rec fold f acc = function
    | [] -> Ok acc
    | x :: rest ->
      let* acc = f acc x in
      fold f acc rest
  in
  let decode_provider provider v =
    let where = Printf.sprintf " in the %s target block" provider in
    let* fields =
      members
        ~path
        ~where
        ~duplicate:(Printf.sprintf "duplicate %s target field %S" provider)
        v
    in
    fields
    |> Sol_cli_result.map_list (fun (k, v) ->
      match v with
      | `Scalar _ -> Ok (Option.map (fun t -> k, t) (scalar_text v))
      | _ ->
        refuse
          (Printf.sprintf "%s.%s must be a single value, not a nested block" provider k))
    |> Result.map (List.filter_map Fun.id)
  in
  let valid_identifier value =
    let valid_char = function
      | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
      | _ -> false
    in
    let len = String.length value in
    len > 0
    && len <= 63
    && value.[0] >= 'a'
    && value.[0] <= 'z'
    && String.for_all valid_char value
  in
  let valid_secret_key value =
    let valid_char = function
      | 'A' .. 'Z' | '0' .. '9' | '_' -> true
      | _ -> false
    in
    let len = String.length value in
    len > 0
    && len <= 253
    && value.[0] >= 'A'
    && value.[0] <= 'Z'
    && String.for_all valid_char value
  in
  let read_scalar ~where name value =
    match scalar_text value with
    | Some text -> Ok text
    | None -> refuse (Printf.sprintf "%s.%s must be a non-empty string" where name)
  in
  let decode_secret_authority key value =
    let where = "secrets." ^ key in
    match value with
    | `Scalar _ -> refuse (where ^ " must be an authority mapping with an authority field")
    | `O _ ->
      let* fields = members ~path ~where:(" in " ^ where) value in
      let* authority =
        match List.assoc_opt "authority" fields with
        | None -> refuse (where ^ ".authority is required")
        | Some value -> read_scalar ~where "authority" value
      in
      (match authority with
       | "sol" ->
         if List.length fields = 1
         then Ok Sol_managed
         else refuse (where ^ " with authority sol must not include store or key")
       | "external" ->
         let unknown =
           List.find_opt
             (fun (field, _) -> not (List.mem field [ "authority"; "store"; "key" ]))
             fields
         in
         let* () =
           match unknown with
           | None -> Ok ()
           | Some (field, _) -> refuse (where ^ " has unknown field " ^ field)
         in
         let* store =
           match List.assoc_opt "store" fields with
           | None -> refuse (where ^ ".store is required for an external secret")
           | Some value -> read_scalar ~where "store" value
         in
         let* external_key =
           match List.assoc_opt "key" fields with
           | None -> refuse (where ^ ".key is required for an external secret")
           | Some value -> read_scalar ~where "key" value
         in
         if not (valid_identifier store)
         then refuse (where ^ ".store must be a lowercase Kubernetes name")
         else Ok (External { store; key = external_key })
       | _ -> refuse (where ^ ".authority must be sol or external"))
    | _ -> refuse (where ^ " must be sol or an authority mapping")
  in
  let decode_secret_authorities value =
    let* units =
      members
        ~path
        ~where:" in target secrets"
        ~duplicate:(Printf.sprintf "duplicate secret unit %S")
        value
    in
    Sol_cli_result.map_list
      (fun (unit_address, value) ->
         let domain, unit_name =
           match String.split_on_char '/' unit_address with
           | [ domain; unit_name ] -> domain, unit_name
           | _ -> "", ""
         in
         if not (valid_identifier domain && valid_identifier unit_name)
         then refuse ("secret unit must be a domain/unit address, got " ^ unit_address)
         else
           let* keys =
             members
               ~path
               ~where:(" in target secrets." ^ unit_address)
               ~duplicate:(Printf.sprintf "duplicate secret key %S")
               value
           in
           Sol_cli_result.map_list
             (fun (secret_key, value) ->
                if not (valid_secret_key secret_key)
                then refuse ("invalid secret key " ^ secret_key)
                else
                  decode_secret_authority secret_key value
                  |> Result.map (fun authority -> secret_key, authority))
             keys
           |> Result.map (fun authorities -> unit_address, authorities))
      units
  in
  let set_field (current : target) field s =
    match field with
    | Target_registry -> Ok { current with registry = Some s }
    | Target_base_domain -> Ok { current with base_domain = Some s }
    | Target_cluster_issuer -> Ok { current with cluster_issuer = Some s }
    | Target_letsencrypt_email -> Ok { current with letsencrypt_email = Some s }
    | Target_cluster_name -> Ok { current with cluster_name = Some s }
    | Target_kube_context -> Ok { current with kube_context = Some s }
    | Target_kubeconfig -> Ok { current with kubeconfig = Some s }
    | Target_terraform_var_file -> Ok { current with terraform_var_file = Some s }
    | Target_observability_backend -> Ok { current with observability_backend = Some s }
    | Target_destroy_retention -> Ok { current with destroy_retention = Some s }
    | Target_alert_receiver_type -> Ok { current with alert_receiver_type = Some s }
    | Target_alert_receiver_url -> Ok { current with alert_receiver_url = Some s }
    | Target_alert_owner -> Ok { current with alert_owner = Some s }
    | Target_alert_runbook_url -> Ok { current with alert_runbook_url = Some s }
    | Target_state_bucket -> Ok { current with state_bucket = Some s }
    | Target_cluster_endpoint_cidr -> Ok { current with cluster_endpoint_cidr = Some s }
    | Target_dns_zone_ownership -> Ok { current with dns_zone_ownership = Some s }
    | Target_node_failure_headroom_nodes ->
      parse_int s
      |> Result.map (fun n -> { current with node_failure_headroom_nodes = n })
      |> Result.map_error (fun _ ->
        error "expected integer for node_failure_headroom_nodes")
    | Target_profile ->
      Sol_cli_profile.of_selection s
      |> Result.map (fun profile -> { current with profile = Some profile })
      |> Result.map_error error
    | Target_secrets -> assert false
  in
  let decode_target_fields fields =
    fold
      (fun (current : target) (k, v) ->
         match target_key_of_string k with
         | Target_provider_box provider ->
           let provider = Sol_cli_provider.to_string provider in
           let* fields = decode_provider provider v in
           Ok
             { current with
               provider_fields = current.provider_fields @ [ provider, fields ]
             }
         | Target_unknown k ->
           (match v with
            | `O _ -> refuse (Printf.sprintf "unsupported provider %S" k)
            | _ when is_null v -> refuse (Printf.sprintf "unsupported provider %S" k)
            | _ -> refuse (Printf.sprintf "unknown target key %S" k))
         | Target_provider_owned (k, provider) ->
           let provider = Sol_cli_provider.to_string provider in
           refuse
             (Printf.sprintf
                "target key %S belongs to the %s provider: declare it as `%s.%s` inside \
                 the target block (REFAC-098)"
                k
                provider
                provider
                k)
         | Target_field Target_secrets ->
           let* secret_authorities = decode_secret_authorities v in
           Ok { current with secret_authorities }
         | Target_field field ->
           let* s = value (target_field_name field) v in
           set_field current field s)
      target_empty
      fields
  in
  let decode_target v =
    let* fields =
      members
        ~path
        ~where:" in target"
        ~duplicate:(fun k ->
          match Sol_cli_provider.of_string k with
          | Some _ -> Printf.sprintf "duplicate target provider box %S" k
          | None -> Printf.sprintf "duplicate target key %S" k)
        v
    in
    decode_target_fields fields
  in
  let decode_index (name, v) =
    let where = Printf.sprintf " in index %S" name in
    let* fields = members ~path ~where v in
    fold
      (fun (i : index) (k, v) ->
         match k with
         | "partition_key" ->
           let* s = value k v in
           Ok { i with partition_key = Some s }
         | "sort_key" ->
           let* s = value k v in
           Ok { i with sort_key = Some s }
         | _ -> refuse (Printf.sprintf "unknown key %S" k))
      (index_empty name)
      fields
  in
  let string_map ~what v =
    let* named =
      members
        ~path
        ~where:(" in " ^ what)
        ~duplicate:(fun k -> Printf.sprintf "duplicate key %S in %s" k what)
        v
    in
    fold
      (fun acc (k, v) ->
         let* s = value k v in
         Ok (acc @ [ k, s ]))
      []
      named
  in
  (* The binding selection. Absent means Sol provisions the resource; the block
     exists only to override it to an externally managed one, so `ownership: sol`
     is refused rather than accepted as a redundant second declaration. *)
  let decode_binding resource_name v =
    let what = Printf.sprintf "resource %S binding" resource_name in
    let* fields = members ~path ~where:(" in " ^ what) v in
    let* () =
      match
        List.filter
          (fun (k, _) ->
             not
               (List.mem k [ "ownership"; "store"; "keys"; "connection"; "credentials" ]))
          fields
      with
      | (k, _) :: _ -> refuse (Printf.sprintf "%s: unknown key %S" what k)
      | [] -> Ok ()
    in
    let* ownership =
      match List.assoc_opt "ownership" fields with
      | None -> refuse (Printf.sprintf "%s: ownership is required" what)
      | Some v ->
        let* s = value "ownership" v in
        (match s with
         | "external" -> Ok Ownership_external
         | "sol" ->
           refuse
             (Printf.sprintf
                "%s: ownership \"sol\" is not accepted — the effective resource graph \
                 already declares a Sol-provisioned resource, so a binding exists only \
                 to override it to \"external\""
                what)
         | _ -> refuse (Printf.sprintf "%s: ownership must be \"external\"" what))
    in
    let* store =
      match List.assoc_opt "store" fields with
      | None -> Ok None
      | Some v ->
        let* s = value "store" v in
        if Sol_cli_string.is_blank s
        then refuse (Printf.sprintf "%s: store must be a non-blank store name" what)
        else Ok (Some s)
    in
    let* keys =
      match List.assoc_opt "keys" fields with
      | None -> Ok []
      | Some v -> string_map ~what:(what ^ " keys") v
    in
    let* connection =
      match List.assoc_opt "connection" fields with
      | None -> Ok []
      | Some v -> string_map ~what:(what ^ " connection") v
    in
    let* credentials =
      match List.assoc_opt "credentials" fields with
      | None -> Ok []
      | Some v -> string_map ~what:(what ^ " credentials") v
    in
    let* () =
      match store, keys, credentials with
      | None, _, _ ->
        refuse (Printf.sprintf "%s: an external binding requires store" what)
      | Some _, [], [] ->
        refuse
          (Printf.sprintf
             "%s: an external binding requires keys or credentials — a remote path per \
              sensitive contract key, or per credential class for a contract that has \
              classes"
             what)
      | Some _, _, _ -> Ok ()
    in
    Ok { ownership; store; keys; connection; credentials }
  in
  let decode_resource (name, v) =
    let* fields = members ~path ~where:(Printf.sprintf " in resource %S" name) v in
    fold
      (fun (r : resource) (k, v) ->
         match k with
         | "type" ->
           let* s = value k v in
           Ok { r with typ = Some s }
         | "partition_key" ->
           let* s = value k v in
           Ok { r with partition_key = Some s }
         | "sort_key" ->
           let* s = value k v in
           Ok { r with sort_key = Some s }
         | "size" ->
           let* s = value k v in
           Ok { r with size = Some s }
         | "omit" ->
           let* omit = bool_value k v in
           Ok { r with omit }
         | "indexes" ->
           let* indexes =
             members
               ~path
               ~where:(Printf.sprintf " in resource %S" name)
               ~duplicate:(Printf.sprintf "duplicate index %S")
               v
           in
           let* indexes =
             fold
               (fun acc i ->
                  let* i = decode_index i in
                  Ok (acc @ [ i ]))
               []
               indexes
           in
           Ok { r with indexes }
         | "binding" ->
           let* binding = decode_binding name v in
           Ok { r with binding = Some binding }
         | _ -> refuse (Printf.sprintf "unknown resource key %S" k))
      (resource_empty name)
      fields
  in
  let decode_uses v =
    match v with
    | `A { Yaml.s_members; _ } ->
      fold
        (fun acc item ->
           match scalar_text item with
           | Some s -> Ok (acc @ [ s ])
           | None -> refuse "expected a list of names for uses")
        []
        s_members
    | _ when is_null v -> Ok []
    | `Scalar _ -> Ok (Option.to_list (scalar_text v))
    | _ -> refuse "expected a list of names for uses"
  in
  let decode_service (name, v) =
    let* fields = members ~path ~where:(Printf.sprintf " in service %S" name) v in
    fold
      (fun (sv : service) (k, v) ->
         match k with
         | "type" ->
           let* s = value k v in
           Ok { sv with typ = Some s }
         | "path" ->
           let* s = value k v in
           Ok { sv with path = Some s }
         | "uses" ->
           let* uses = decode_uses v in
           Ok { sv with uses }
         | "language" ->
           let* s = value k v in
           (match Sol_cli_compat.of_string s with
            | Ok language -> Ok { sv with language = Some language }
            | Error msg -> refuse (msg ^ " for language"))
         | "omit" ->
           let* omit = bool_value k v in
           Ok { sv with omit }
         | "scale" ->
           let* scale =
             members ~path ~where:(Printf.sprintf " in service %S scale" name) v
           in
           fold
             (fun (sv : service) (k, v) ->
                match k with
                | "min" ->
                  let* n = int_value k v in
                  Ok { sv with scale_min = n }
                | "max" ->
                  let* n = int_value k v in
                  Ok { sv with scale_max = n }
                | _ -> refuse (Printf.sprintf "unknown scale key %S" k))
             sv
             scale
         | _ -> refuse (Printf.sprintf "unknown service key %S" k))
      (service_empty name)
      fields
  in
  let section cfg (k, v) =
    match k with
    | "project" when not top_level ->
      refuse "project belongs in sol.yml, not in an environment or target"
    | "target" when not top_level ->
      refuse "put target keys directly here, not in a target: block"
    | "project" ->
      let* p = value "project" v in
      Ok { cfg with project = Some p }
    | "target" ->
      let* t = decode_target v in
      Ok { cfg with target = Some t }
    | "resources" ->
      let* named =
        members
          ~path
          ~where:" in resources"
          ~duplicate:(Printf.sprintf "duplicate resource %S")
          v
      in
      let* resources =
        fold
          (fun acc r ->
             let* r = decode_resource r in
             Ok (acc @ [ r ]))
          []
          named
      in
      Ok { cfg with resources }
    | "services" ->
      let* named =
        members
          ~path
          ~where:" in services"
          ~duplicate:(Printf.sprintf "duplicate service %S")
          v
      in
      let* services =
        fold
          (fun acc x ->
             let* x = decode_service x in
             Ok (acc @ [ x ]))
          []
          named
      in
      Ok { cfg with services }
    | _ -> refuse (Printf.sprintf "unknown top-level key %S" k)
  in
  if top_level
  then fold section empty fields
  else (
    let is_section (k, _) = List.mem k [ "project"; "target"; "resources"; "services" ] in
    let sections, target_keys = List.partition is_section fields in
    let* cfg = fold section empty sections in
    if target_keys = []
    then Ok cfg
    else
      let* t = decode_target_fields target_keys in
      Ok { cfg with target = Some t })
;;

let load_string ~path text =
  let* doc = parse_yaml ~path text in
  let* top =
    members
      ~path
      ~where:""
      ~duplicate:(Printf.sprintf "duplicate top-level section %S")
      doc
  in
  decode_layer ~path ~context:"" ~top_level:true top
;;

let load path =
  if not (Sys.file_exists path)
  then Ok empty
  else (
    match In_channel.with_open_bin path In_channel.input_all with
    | text -> load_string ~path text
    | exception Sys_error message ->
      let prefix = path ^ ": " in
      let message =
        if String.starts_with ~prefix message
        then
          String.sub
            message
            (String.length prefix)
            (String.length message - String.length prefix)
        else message
      in
      Error { path; line = 0; message })
;;

let sol_yml_services_of_string ~path text =
  let* layer = load_string ~path text in
  Ok layer.services
;;

let sol_yml_services ~root =
  let* layer = load (Filename.concat root "sol.yml") in
  Ok layer.services
;;

let prefer a b =
  match b with
  | Some _ -> b
  | None -> a
;;

let prefer_list a b = if b = [] then a else b

let merge_fields a b =
  List.fold_left
    (fun acc (k, v) ->
       upsert_by_name
         fst
         k
         (function
           | None -> k, v
           | Some _ -> k, v)
         acc)
    a
    b
;;

let merge_provider_fields a b =
  List.fold_left
    (fun acc (provider, fields) ->
       upsert_by_name
         fst
         provider
         (function
           | None -> provider, fields
           | Some (_, old_fields) -> provider, merge_fields old_fields fields)
         acc)
    a
    b
;;

let merge_secret_authorities a b =
  List.fold_left
    (fun acc (unit_address, authorities) ->
       let merged =
         match List.assoc_opt unit_address acc with
         | None -> authorities
         | Some previous -> merge_fields previous authorities
       in
       upsert_by_name
         fst
         unit_address
         (function
           | None -> unit_address, merged
           | Some _ -> unit_address, merged)
         acc)
    a
    b
;;

let provider_field (target : target) key =
  List.assoc_opt (Sol_cli_provider.to_string target.provider) target.provider_fields
  |> Option.value ~default:[]
  |> List.assoc_opt key
;;

let secret_authority (target : target) ~unit_address ~key =
  match List.assoc_opt unit_address target.secret_authorities with
  | None -> None
  | Some authorities -> List.assoc_opt key authorities
;;

let secret_authorities_for_unit (target : target) unit_address =
  List.assoc_opt unit_address target.secret_authorities |> Option.value ~default:[]
;;

let resolve_secret_authorities (target : target) ~unit_address ~required_keys =
  let authorities = secret_authorities_for_unit target unit_address in
  { resolved = List.filter (fun (key, _) -> List.mem key required_keys) authorities
  ; missing = List.filter (fun key -> not (List.mem_assoc key authorities)) required_keys
  ; additional =
      List.filter_map
        (fun (key, _) -> if List.mem key required_keys then None else Some key)
        authorities
  }
;;

let merge_target a b =
  { a with
    registry = prefer a.registry b.registry
  ; base_domain = prefer a.base_domain b.base_domain
  ; dns_zone_ownership = prefer a.dns_zone_ownership b.dns_zone_ownership
  ; cluster_issuer = prefer a.cluster_issuer b.cluster_issuer
  ; letsencrypt_email = prefer a.letsencrypt_email b.letsencrypt_email
  ; cluster_name = prefer a.cluster_name b.cluster_name
  ; kube_context = prefer a.kube_context b.kube_context
  ; kubeconfig = prefer a.kubeconfig b.kubeconfig
  ; terraform_var_file = prefer a.terraform_var_file b.terraform_var_file
  ; observability_backend = prefer a.observability_backend b.observability_backend
  ; destroy_retention = prefer a.destroy_retention b.destroy_retention
  ; alert_receiver_type = prefer a.alert_receiver_type b.alert_receiver_type
  ; alert_receiver_url = prefer a.alert_receiver_url b.alert_receiver_url
  ; alert_owner = prefer a.alert_owner b.alert_owner
  ; alert_runbook_url = prefer a.alert_runbook_url b.alert_runbook_url
  ; state_bucket = prefer a.state_bucket b.state_bucket
  ; cluster_endpoint_cidr = prefer a.cluster_endpoint_cidr b.cluster_endpoint_cidr
  ; node_failure_headroom_nodes =
      prefer a.node_failure_headroom_nodes b.node_failure_headroom_nodes
  ; profile = prefer a.profile b.profile
  ; provider_fields = merge_provider_fields a.provider_fields b.provider_fields
  ; secret_authorities =
      merge_secret_authorities a.secret_authorities b.secret_authorities
  }
;;

(* Unrelated resource attributes merge field by field, as they always have. The
   binding is different: it is one atomic selection, so an override replaces it
   whole. Merging it field by field could pair an inherited source with a new
   connection, which is exactly what the design forbids. *)
let merge_resource (a : resource) (b : resource) =
  { name = a.name
  ; typ = prefer a.typ b.typ
  ; partition_key = prefer a.partition_key b.partition_key
  ; sort_key = prefer a.sort_key b.sort_key
  ; indexes = prefer_list a.indexes b.indexes
  ; size = prefer a.size b.size
  ; omit = b.omit || a.omit
  ; binding = prefer a.binding b.binding
  }
;;

let merge_service (a : service) (b : service) =
  { name = a.name
  ; typ = prefer a.typ b.typ
  ; path = prefer a.path b.path
  ; uses = prefer_list a.uses b.uses
  ; scale_min = prefer a.scale_min b.scale_min
  ; scale_max = prefer a.scale_max b.scale_max
  ; language = prefer a.language b.language
  ; omit = b.omit || a.omit
  }
;;

let merge_by name merge xs ys =
  List.fold_left
    (fun acc y ->
       upsert_by_name
         name
         (name y)
         (function
           | None -> y
           | Some x -> merge x y)
         acc)
    xs
    ys
;;

let merge base overlay =
  { project = prefer base.project overlay.project
  ; target =
      (match base.target, overlay.target with
       | None, t | t, None -> t
       | Some a, Some b -> Some (merge_target a b))
  ; resources =
      merge_by
        (fun (r : resource) -> r.name)
        merge_resource
        base.resources
        overlay.resources
  ; services =
      merge_by (fun (s : service) -> s.name) merge_service base.services overlay.services
  }
;;

let reserved_env_name = "local"

let target_of_path s =
  match String.split_on_char '/' s with
  | [ env; provider; region ]
    when env <> ""
         && provider <> ""
         && region <> ""
         && env <> ".."
         && provider <> ".."
         && region <> ".." ->
    if env = reserved_env_name
    then
      Error
        { path = s
        ; line = 0
        ; message =
            Printf.sprintf
              "%S is reserved: it names Sol's own ephemeral cluster — the substrate `sol \
               local deploy` brings up — not an environment. Name this target for the \
               cluster it points at (`dev`, `staging`, …), even when that cluster is \
               small and yours."
              env
        }
    else (
      match Sol_cli_provider.of_string provider with
      | Some provider ->
        Ok
          { name = s
          ; env
          ; provider
          ; region
          ; registry = None
          ; base_domain = None
          ; cluster_issuer = None
          ; letsencrypt_email = None
          ; cluster_name = None
          ; kube_context = None
          ; kubeconfig = None
          ; terraform_var_file = None
          ; observability_backend = None
          ; destroy_retention = None
          ; alert_receiver_type = None
          ; alert_receiver_url = None
          ; alert_owner = None
          ; alert_runbook_url = None
          ; state_bucket = None
          ; cluster_endpoint_cidr = None
          ; dns_zone_ownership = None
          ; node_failure_headroom_nodes = None
          ; profile = None
          ; provider_fields = []
          ; secret_authorities = []
          }
      | None ->
        Error
          { path = s
          ; line = 0
          ; message = Printf.sprintf "unsupported provider %S" provider
          })
  | parts when List.exists (( = ) "..") parts ->
    Error { path = s; line = 0; message = "target path must not contain '..'" }
  | _ ->
    Error
      { path = s; line = 0; message = "target must look like <env>/<provider>/<region>" }
;;

let workspace_root () =
  match Sol_cli_workspace.find_root ~dir:(Sys.getcwd ()) with
  | Some root -> root
  | None -> "."
;;

let rooted path = Filename.concat (workspace_root ()) path
let environments_file = "sol/environments.yml"
let environments_local_file = "sol/environments.local.yml"

type environment =
  { env_name : string
  ; layer : layer
  ; targets : (string * layer) list
  }

let rec fold_result f acc = function
  | [] -> Ok acc
  | x :: rest ->
    let* acc = f acc x in
    fold_result f acc rest
;;

let target_key_ok key =
  match String.split_on_char '/' key with
  | [ provider; region ] when provider <> "" && region <> "" && region <> ".." ->
    (match Sol_cli_provider.of_string provider with
     | Some _ -> Ok ()
     | None -> Error (Printf.sprintf "unsupported provider %S" provider))
  | _ -> Error "a target must look like <provider>/<region>"
;;

let target_only_keys (t : target) =
  List.filter_map
    (fun (name, set) -> if set then Some name else None)
    [ "cluster_name", t.cluster_name <> None
    ; "kube_context", t.kube_context <> None
    ; "kubeconfig", t.kubeconfig <> None
    ; "cluster_endpoint_cidr", t.cluster_endpoint_cidr <> None
    ; "registry", t.registry <> None
    ]
;;

let app_shape_keys (l : layer) =
  List.concat_map
    (fun (r : resource) ->
       List.filter_map
         (fun (name, set) ->
            if set then Some (Printf.sprintf "resources.%s.%s" r.name name) else None)
         [ "type", r.typ <> None
         ; "partition_key", r.partition_key <> None
         ; "sort_key", r.sort_key <> None
         ; "indexes", r.indexes <> []
         ])
    l.resources
  @ (l.services
     |> List.concat_map (fun (sv : service) ->
       List.filter_map
         (fun (name, set) ->
            if set then Some (Printf.sprintf "services.%s.%s" sv.name name) else None)
         [ "type", sv.typ <> None
         ; "path", sv.path <> None
         ; "language", sv.language <> None
         ; "uses", sv.uses <> []
         ]))
;;

let check_placement ~path (e : environment) =
  let refuse context message =
    Error { path; line = 0; message = context ^ ": " ^ message }
  in
  let app_shape context layer =
    match app_shape_keys layer with
    | [] -> Ok ()
    | key :: _ ->
      refuse
        context
        (Printf.sprintf
           "%s belongs in sol.yml: an environment or target may only adjust size, scale, \
            omit, and a resource's binding selection (DEC-047)"
           key)
  in
  let* () =
    match Option.map target_only_keys e.layer.target with
    | Some (key :: _) ->
      refuse
        e.env_name
        (Printf.sprintf
           "%s is target-only: set it under %s.targets.<provider>/<region> (DEC-047)"
           key
           e.env_name)
    | _ -> Ok ()
  in
  let* () = app_shape e.env_name e.layer in
  fold_result
    (fun () (key, layer) -> app_shape (e.env_name ^ ".targets." ^ key) layer)
    ()
    e.targets
;;

let decode_environments ~path doc =
  let* envs =
    members ~path ~where:"" ~duplicate:(Printf.sprintf "duplicate environment %S") doc
  in
  fold_result
    (fun acc (env_name, v) ->
       let* fields =
         members ~path ~where:(Printf.sprintf " in environment %S" env_name) v
       in
       let targets_field, body = List.partition (fun (k, _) -> k = "targets") fields in
       let* layer = decode_layer ~path ~context:env_name ~top_level:false body in
       let* targets =
         match targets_field with
         | [] -> Ok []
         | (_, tv) :: _ ->
           let* named =
             members
               ~path
               ~where:(Printf.sprintf " in %s.targets" env_name)
               ~duplicate:(Printf.sprintf "duplicate target %S")
               tv
           in
           fold_result
             (fun acc (key, bv) ->
                let context = env_name ^ ".targets." ^ key in
                let* () =
                  match target_key_ok key with
                  | Ok () -> Ok ()
                  | Error m -> Error { path; line = 0; message = context ^ ": " ^ m }
                in
                let* fields = members ~path ~where:(" in " ^ context) bv in
                let* body = decode_layer ~path ~context ~top_level:false fields in
                Ok (acc @ [ key, body ]))
             []
             named
       in
       let e = { env_name; layer; targets } in
       let* () = check_placement ~path e in
       Ok (acc @ [ e ]))
    []
    envs
;;

let load_environments_file path =
  if not (Sys.file_exists path)
  then Ok []
  else (
    let text = In_channel.with_open_bin path In_channel.input_all in
    let* doc = parse_yaml ~path text in
    decode_environments ~path doc)
;;

let layer_keys (l : layer) =
  let opt name o = if o = None then [] else [ name ] in
  let target_keys =
    match l.target with
    | None -> []
    | Some t ->
      List.concat
        [ opt "registry" t.registry
        ; opt "base_domain" t.base_domain
        ; opt "cluster_issuer" t.cluster_issuer
        ; opt "letsencrypt_email" t.letsencrypt_email
        ; opt "cluster_name" t.cluster_name
        ; opt "kube_context" t.kube_context
        ; opt "kubeconfig" t.kubeconfig
        ; opt "terraform_var_file" t.terraform_var_file
        ; opt "observability_backend" t.observability_backend
        ; opt "destroy_retention" t.destroy_retention
        ; opt "alert_receiver_type" t.alert_receiver_type
        ; opt "alert_receiver_url" t.alert_receiver_url
        ; opt "alert_owner" t.alert_owner
        ; opt "alert_runbook_url" t.alert_runbook_url
        ; opt "state_bucket" t.state_bucket
        ; opt "cluster_endpoint_cidr" t.cluster_endpoint_cidr
        ; opt "dns_zone_ownership" t.dns_zone_ownership
        ; opt "node_failure_headroom_nodes" t.node_failure_headroom_nodes
        ; opt "profile" t.profile
        ; t.secret_authorities
          |> List.concat_map (fun (unit_address, authorities) ->
            List.map (fun (key, _) -> "secrets." ^ unit_address ^ "." ^ key) authorities)
        ]
      @ (t.provider_fields
         |> List.concat_map (fun (provider, fields) ->
           List.map (fun (k, _) -> provider ^ "." ^ k) fields))
  in
  target_keys
  @ List.concat_map
      (fun (r : resource) ->
         let p = "resources." ^ r.name ^ "." in
         opt (p ^ "size") r.size @ if r.omit then [ p ^ "omit" ] else [])
      l.resources
  @ (l.services
     |> List.concat_map (fun (sv : service) ->
       let p = "services." ^ sv.name ^ "." in
       opt (p ^ "scale.min") sv.scale_min
       @ opt (p ^ "scale.max") sv.scale_max
       @ if sv.omit then [ p ^ "omit" ] else []))
;;

let disjoint ~path ~context tracked local =
  match List.filter (fun k -> List.mem k (layer_keys tracked)) (layer_keys local) with
  | [] -> Ok ()
  | key :: _ ->
    Error
      { path
      ; line = 0
      ; message =
          Printf.sprintf
            "%s: %s is already set in %s; the local file may only add keys the tracked \
             file leaves unset (DEC-047)"
            context
            key
            environments_file
      }
;;

let union_environments ~local_path ~tracked ~local =
  fold_result
    (fun acc (l : environment) ->
       match List.find_opt (fun e -> e.env_name = l.env_name) acc with
       | None -> Ok (acc @ [ l ])
       | Some e ->
         let* () = disjoint ~path:local_path ~context:l.env_name e.layer l.layer in
         let* targets =
           fold_result
             (fun targets (key, lt) ->
                match List.assoc_opt key targets with
                | None -> Ok (targets @ [ key, lt ])
                | Some tt ->
                  let context = l.env_name ^ ".targets." ^ key in
                  let* () = disjoint ~path:local_path ~context tt lt in
                  Ok
                    (targets
                     |> List.map (fun (k, v) -> if k = key then k, merge tt lt else k, v)
                    ))
             e.targets
             l.targets
         in
         let merged = { e with layer = merge e.layer l.layer; targets } in
         Ok (List.map (fun x -> if x.env_name = l.env_name then merged else x) acc))
    tracked
    local
;;

let refuse_per_target_files ~root =
  let sol_dir = Filename.concat root "sol" in
  let names select path =
    match select path with
    | Ok names -> names
    | Error _ -> []
  in
  let old =
    names Sol_cli_fs_walk.dirs sol_dir
    |> List.concat_map (fun env ->
      names Sol_cli_fs_walk.dirs (Filename.concat sol_dir env)
      |> List.concat_map (fun provider ->
        names
          Sol_cli_fs_walk.files
          (Filename.concat (Filename.concat sol_dir env) provider)
        |> List.filter_map (fun file ->
          if Filename.check_suffix file ".yml"
          then Some (env, provider, Filename.chop_suffix file ".yml")
          else None)))
  in
  match old with
  | [] -> Ok ()
  | (env, provider, region) :: _ ->
    Error
      { path = Printf.sprintf "sol/%s/%s/%s.yml" env provider region
      ; line = 0
      ; message =
          Printf.sprintf
            "per-target files are no longer read (FEAT-100): move this file into %s as \
             %s.targets.%s/%s, with its target: keys directly under it"
            environments_file
            env
            provider
            region
      }
;;

let load_environments ~root =
  let* () = refuse_per_target_files ~root in
  let local_path = Filename.concat root environments_local_file in
  let* tracked = load_environments_file (Filename.concat root environments_file) in
  let* local = load_environments_file local_path in
  union_environments ~local_path ~tracked ~local
;;

let active_resources cfg = List.filter (fun (r : resource) -> not r.omit) cfg.resources
let active_services cfg = List.filter (fun (s : service) -> not s.omit) cfg.services

let target_address (target : target) =
  Sol_cli_provider.to_string target.provider ^ "/" ^ target.region
;;

let find_target envs (target : target) =
  match List.find_opt (fun e -> e.env_name = target.env) envs with
  | None -> None, None
  | Some e -> Some e.layer, List.assoc_opt (target_address target) e.targets
;;

let target_declared (target : target) =
  match load_environments ~root:(workspace_root ()) with
  | Error _ -> false
  | Ok envs -> snd (find_target envs target) <> None
;;

let target_source (target : target) =
  Printf.sprintf
    "%s (%s.targets.%s)"
    (rooted environments_file)
    target.env
    (target_address target)
;;

let discover_targets envs =
  List.concat_map
    (fun e -> List.map (fun (key, _) -> e.env_name ^ "/" ^ key) e.targets)
    envs
  |> List.sort String.compare
;;

let discover_target_paths ?root () =
  let root = Option.value root ~default:(workspace_root ()) in
  let* envs = load_environments ~root in
  Ok (discover_targets envs)
;;

let known_provider = Sol_cli_provider.is_known

let format_use_ref ref =
  if ref <> "" && ref.[0] = '/' then ref ^ " (cross-region)" else ref
;;

let validate_use_ref ~(target : target) ~resources service_name ref =
  if ref = ""
  then Error { path = target.name; line = 0; message = "empty uses ref" }
  else if ref.[0] <> '/'
  then
    if List.mem ref resources
    then Ok ()
    else
      Error
        { path = target.name
        ; line = 0
        ; message =
            Printf.sprintf "service %S uses undeclared resource %S" service_name ref
        }
  else (
    match String.split_on_char '/' ref with
    | [ ""; seg1; seg2 ] when seg1 <> "" && seg2 <> "" ->
      if known_provider seg1
      then
        Error
          { path = target.name
          ; line = 0
          ; message = "cross-provider uses refs are not supported in v1"
          }
      else Ok ()
    | [ ""; seg1; seg2; seg3 ] when seg1 <> "" && seg2 <> "" && seg3 <> "" ->
      if known_provider seg1
      then
        Error
          { path = target.name
          ; line = 0
          ; message = "cross-provider uses refs are not supported in v1"
          }
      else
        Error
          { path = target.name
          ; line = 0
          ; message = "cross-env uses refs are not supported in v1"
          }
    | "" :: (_ :: _ :: _ :: _ :: _ as segs) when List.for_all (( <> ) "") segs ->
      Error
        { path = target.name
        ; line = 0
        ; message = "cross-env uses refs are not supported in v1"
        }
    | _ ->
      Error
        { path = target.name
        ; line = 0
        ; message = "absolute uses ref must look like /<region>/<resource>"
        })
;;

let validate_uses cfg =
  match cfg.target with
  | None -> Ok cfg
  | Some target ->
    let resource_names =
      active_resources cfg |> List.map (fun (r : resource) -> r.name)
    in
    let rec validate_services = function
      | [] -> Ok cfg
      | service :: rest ->
        let rec validate_refs = function
          | [] -> validate_services rest
          | ref :: refs ->
            let* () =
              validate_use_ref ~target ~resources:resource_names service.name ref
            in
            validate_refs refs
        in
        validate_refs service.uses
    in
    validate_services (active_services cfg)
;;

let reject_shared_profile ~path (base : layer) =
  match base.target with
  | Some { profile = Some _; _ } ->
    Error
      { path
      ; line = 0
      ; message =
          "profile must be selected in an environment or target (sol/environments.yml), \
           not in sol.yml, whose target section every target inherits"
      }
  | _ -> Ok ()
;;

let resolve ~base ~envs (target : target) =
  let base_target =
    match base.target with
    | None -> target
    | Some t ->
      { t with
        name = target.name
      ; env = target.env
      ; provider = target.provider
      ; region = target.region
      }
  in
  let env_layer, target_layer = find_target envs target in
  let undeclared context (layer : layer) =
    let unknown_resource =
      layer.resources
      |> List.find_opt (fun (r : resource) ->
        not (List.exists (fun (b : resource) -> b.name = r.name) base.resources))
    in
    let unknown_service =
      layer.services
      |> List.find_opt (fun sv ->
        not (List.exists (fun b -> b.name = sv.name) base.services))
    in
    let refuse kind name =
      Error
        { path = environments_file
        ; line = 0
        ; message =
            Printf.sprintf
              "%s: %s %S is not declared in sol.yml; an environment or target may only \
               adjust what sol.yml declares (DEC-047)"
              context
              kind
              name
        }
    in
    match unknown_resource, unknown_service with
    | Some r, _ -> refuse "resource" r.name
    | None, Some sv -> refuse "service" sv.name
    | None, None -> Ok ()
  in
  let apply context cfg = function
    | None -> Ok cfg
    | Some layer ->
      let* () = undeclared context layer in
      Ok (merge cfg layer)
  in
  let* cfg = apply target.env { base with target = Some base_target } env_layer in
  apply (target.env ^ ".targets." ^ target_address target) cfg target_layer
;;

let resolved_target ~base ~envs target_path =
  let* target = target_of_path target_path in
  let* cfg = resolve ~base ~envs target in
  Ok (Option.value cfg.target ~default:target)
;;

let destination_of_target (target : target) =
  let* destination =
    Sol_cli_kube_destination.of_context
      ?kubeconfig:target.kubeconfig
      (Option.value target.kube_context ~default:"")
  in
  let reserved = Sol_cli_kube_destination.local in
  if destination = reserved
  then
    Error
      (Printf.sprintf
         "this target resolves to %s, Sol's own cluster, which is a reserved execution \
          mode rather than a target: use `sol local <command>` for it, and point this \
          target at a cluster you own"
         (Sol_cli_kube_destination.to_string reserved))
  else Ok destination
;;

let destination_identity target =
  match destination_of_target target with
  | Error _ -> None
  | Ok destination -> Some (destination.kubeconfig, destination.context)
;;

let validate_no_same_cluster ~base ~envs (selected : target) =
  let paths = discover_targets envs in
  let rec loop = function
    | [] -> Ok ()
    | path :: rest ->
      if path = selected.name
      then loop rest
      else
        let* other = resolved_target ~base ~envs path in
        (match destination_identity selected, destination_identity other with
         | Some (kubeconfig, context), Some other_destination
           when selected.env <> other.env && (kubeconfig, context) = other_destination ->
           Error
             { path = selected.name
             ; line = 0
             ; message =
                 Printf.sprintf
                   "environments %S and %S both deploy to Kubernetes context %S, so they \
                    would share namespaces, service names and injected URLs — which are \
                    deliberately identical in every environment (DEC-016). Point one of \
                    them at a different target."
                   selected.env
                   other.env
                   context
             }
         | _ -> loop rest)
  in
  loop paths
;;

type t =
  { project : string option
  ; target : target
  ; resources : resource list
  ; services : service list
  }

type declared =
  { services : service list
  ; resources : resource list
  ; profile : Sol_cli_profile.t option
  }

let declared_of_config (cfg : t) =
  { services = cfg.services; resources = cfg.resources; profile = cfg.target.profile }
;;

let load_declared ~root =
  let* layer = load (Filename.concat root "sol.yml") in
  Ok { services = layer.services; resources = layer.resources; profile = None }
;;

let load_for_target ~target =
  let* target = target_of_path target in
  let* root =
    match Sol_cli_workspace.resolve_validated ~dir:(Sys.getcwd ()) with
    | Ok root -> Ok root
    | Error e ->
      Error
        { path = "sol.yml"
        ; line = 0
        ; message = Sol_cli_workspace.workspace_error_to_string e
        }
  in
  let sol_yml = Filename.concat root "sol.yml" in
  let* base = load sol_yml in
  let* () = reject_shared_profile ~path:sol_yml base in
  let* envs = load_environments ~root in
  let* cfg = resolve ~base ~envs target in
  let* cfg = validate_uses cfg in
  let target = Option.value cfg.target ~default:target in
  let* () = validate_no_same_cluster ~base ~envs target in
  Ok { project = cfg.project; target; resources = cfg.resources; services = cfg.services }
;;

let resources (cfg : t) = List.filter (fun (r : resource) -> not r.omit) cfg.resources
let services (cfg : t) = List.filter (fun s -> not s.omit) cfg.services

let is_omitted_service (cfg : t) ~name =
  List.exists (fun s -> s.omit && String.equal s.name name) cfg.services
;;

let vars_with_profile_precedence ~has_profile ~cli_vars ~config_vars =
  if has_profile then cli_vars @ config_vars else config_vars @ cli_vars
;;

let local_infra ~root =
  let* cfg = load (Filename.concat root "sol.yml") in
  let declares typ =
    List.exists (fun (r : resource) -> r.typ = Some typ) (active_resources cfg)
  in
  Ok
    { Sol_cli_workspace.kafka = declares "kafka"
    ; postgres = declares "postgres"
    ; loki = true
    ; prometheus = true
    ; tempo = true
    }
;;

let parse_target = target_of_path
