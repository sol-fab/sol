type t =
  { resource : string
  ; typ : string
  ; ownership : Sol_cli_config.resource_ownership
  ; store : string option
  ; keys : (string * string) list
  ; connection : (string * string) list
  ; (* Class name -> remote path, for a contract with credential classes. Empty otherwise. *)
    credentials : (string * string) list
  }

let of_resource (r : Sol_cli_config.resource) =
  match r.typ with
  | None ->
    Error
      (Printf.sprintf
         "resource %S declares no type, so its connection contract cannot be resolved"
         r.name)
  | Some typ ->
    (match r.binding with
     | None ->
       Ok
         { resource = r.name
         ; typ
         ; ownership = Sol_cli_config.Ownership_sol
         ; store = None
         ; keys = []
         ; connection = []
         ; credentials = []
         }
     | Some b ->
       Ok
         { resource = r.name
         ; typ
         ; ownership = b.Sol_cli_config.ownership
         ; store = b.store
         ; keys = b.keys
         ; connection = b.connection
         ; credentials = b.credentials
         })
;;

let postgres_binding bindings =
  let databases = List.filter (fun b -> String.equal b.typ "postgres") bindings in
  match databases with
  | _ :: _ :: _ ->
    Error
      (Printf.sprintf
         "this target's effective resource graph declares %d PostgreSQL resources (%s). \
          v1 supports one database per target: the delivered credential Secrets are \
          named for the target, so two databases cannot be told apart by their \
          consumers. Omit the ones this target does not use"
         (List.length databases)
         (String.concat ", " (List.map (fun b -> b.resource) databases)))
  | [ database ] -> Ok (Some database)
  | [] -> Ok None
;;

let resolve_resources resources =
  let open Result.Syntax in
  let* bindings = Sol_cli_result.map_list of_resource resources in
  (* Generic graph validation and PostgreSQL selection share this cardinality rule. *)
  Result.map (fun _ -> bindings) (postgres_binding bindings)
;;

let resolve (cfg : Sol_cli_config.t) = resolve_resources (Sol_cli_config.resources cfg)

let provisions bindings ~typ =
  List.exists
    (fun b -> String.equal b.typ typ && b.ownership = Sol_cli_config.Ownership_sol)
    bindings
;;

let of_type bindings ~typ = List.filter (fun b -> String.equal b.typ typ) bindings

(** PostgreSQL selection after binding validation. External credentials are complete
    by construction. Local development publishes class credentials without the
    managed setup Job or its CA. *)
type postgres_credentials =
  { ddl : string
  ; dml : string
  }

type external_postgres =
  { resource : string
  ; store : string
  ; credentials : postgres_credentials
  }

type postgres =
  | No_postgres
  | Managed_postgres of string
  | External_postgres of external_postgres
  | Local_postgres of string

type postgres_trust =
  | Published_ca
  | Connection_trust

type postgres_use =
  | No_postgres_use
  | Postgres_use of
      { target : string
      ; trust : postgres_trust
      }

let ddl_class = "ddl"
let dml_class = "dml"

let postgres bindings =
  let open Result.Syntax in
  let* binding = postgres_binding bindings in
  match binding with
  | None -> Ok No_postgres
  | Some binding when binding.ownership = Sol_cli_config.Ownership_sol ->
    Ok (Managed_postgres binding.resource)
  | Some binding ->
    let* store =
      match binding.store with
      | Some store when String.trim store <> "" -> Ok store
      | _ ->
        Error
          (Printf.sprintf
             "the externally bound database %S names no store"
             binding.resource)
    in
    let credential name =
      match List.assoc_opt name binding.credentials with
      | Some path when String.trim path <> "" -> Ok path
      | _ ->
        Error
          (Printf.sprintf
             "the externally bound database %S names no remote path for the %S \
              credential class (binding.credentials.%s)"
             binding.resource
             name
             name)
    in
    let* ddl = credential ddl_class in
    let* dml = credential dml_class in
    (* PostgreSQL currently delivers complete URL credentials by class. Refuse
       additional connection/trust sources rather than dropping declared inputs. *)
    let unsupported =
      List.map (fun (key, _) -> "connection." ^ key) binding.connection
      @ List.map (fun (key, _) -> "keys." ^ key) binding.keys
      @ (binding.credentials
         |> List.filter_map (fun (name, _) ->
           if name = ddl_class || name = dml_class
           then None
           else Some ("credentials." ^ name)))
    in
    let* () =
      match unsupported with
      | [] -> Ok ()
      | keys ->
        Error
          (Printf.sprintf
             "the externally bound database %S declares unsupported PostgreSQL inputs \
              (%s). This delivery supports only complete DDL/DML URL credentials; \
              separate connection or private CA material cannot be delivered"
             binding.resource
             (String.concat ", " keys))
    in
    Ok
      (External_postgres
         { resource = binding.resource; store; credentials = { ddl; dml } })
;;

let resolve_postgres config = Result.bind (resolve config) postgres

let postgres_resource = function
  | No_postgres -> None
  | Managed_postgres resource | Local_postgres resource -> Some resource
  | External_postgres binding -> Some binding.resource
;;

let postgres_is_managed = function
  | Managed_postgres _ -> true
  | No_postgres | External_postgres _ | Local_postgres _ -> false
;;

let postgres_trust = function
  | Managed_postgres _ -> Published_ca
  | No_postgres | External_postgres _ | Local_postgres _ -> Connection_trust
;;

let postgres_use_target = function
  | No_postgres_use -> None
  | Postgres_use { target; _ } -> Some target
;;

let postgres_use_ca_target = function
  | Postgres_use { target; trust = Published_ca } -> Some target
  | No_postgres_use | Postgres_use { trust = Connection_trust; _ } -> None
;;

let resource_name_of_ref ref =
  match String.split_on_char '/' ref |> List.filter (( <> ) "") |> List.rev with
  | name :: _ -> Some name
  | [] -> None
;;

let validate_external_connection ~typ ~name (binding : Sol_cli_config.resource_binding) =
  let open Result.Syntax in
  let required key =
    match List.assoc_opt key binding.connection with
    | Some value when String.trim value <> "" -> Ok value
    | _ ->
      Error
        (Printf.sprintf
           "external %s resource %S has no %s in binding.connection"
           typ
           name
           key)
  in
  let require_prefix key prefix =
    let* value = required key in
    if
      String.length value >= String.length prefix
      && String.sub value 0 (String.length prefix) = prefix
    then Ok value
    else
      Error
        (Printf.sprintf
           "external %s resource %S has %s %S, which is not a %s ARN"
           typ
           name
           key
           value
           prefix)
  in
  match typ with
  | "queue" ->
    let* _ = require_prefix "QUEUE_ARN" "arn:aws:sqs:" in
    let* _ = required "QUEUE_URL" in
    Ok ()
  | "object_store" ->
    let* arn = require_prefix "OBJECT_ARN" "arn:aws:s3:::" in
    let* () =
      if String.length arn > 2 && String.sub arn (String.length arn - 2) 2 = "/*"
      then Ok ()
      else
        Error
          (Printf.sprintf
             "external object_store resource %S must bind OBJECT_ARN to an object \
              ARN               ending in /* (for example arn:aws:s3:::bucket/*)"
             name)
    in
    let* _ = required "OBJECT_BUCKET" in
    Ok ()
  | _ -> Ok ()
;;

let validate_external_bindings ~(declared : Sol_cli_config.declared) ~service_name =
  let open Result.Syntax in
  let* service =
    match
      declared.services
      |> List.find_opt (fun (service : Sol_cli_config.service) ->
        String.equal service.name service_name && not service.omit)
    with
    | Some service -> Ok service
    | None ->
      Ok
        { Sol_cli_config.name = service_name
        ; typ = None
        ; path = None
        ; uses = []
        ; scale_min = None
        ; scale_max = None
        ; language = None
        ; omit = false
        }
  in
  service.uses
  |> Sol_cli_result.map_list (fun ref ->
    match resource_name_of_ref ref with
    | None -> Ok ()
    | Some name ->
      (match
         declared.resources
         |> List.find_opt (fun (resource : Sol_cli_config.resource) ->
           String.equal resource.name name && not resource.omit)
       with
       | None -> Ok ()
       | Some resource ->
         (match resource.typ with
          | Some (("queue" | "object_store") as typ) ->
            let* binding =
              match resource.binding with
              | Some binding when binding.ownership = Sol_cli_config.Ownership_external ->
                Ok binding
              | Some _ ->
                Error
                  (Printf.sprintf
                     "resource %S is managed; external %s bindings are the only \
                      supported shape"
                     name
                     typ)
              | None -> Error (Printf.sprintf "external resource %S has no binding" name)
            in
            let* () =
              if binding.keys = [] && binding.credentials = []
              then Ok ()
              else
                Error
                  (Printf.sprintf
                     "external resource %S declares secret references, but \
                      secret-reference authentication is not implemented for external \
                      queue/object-store"
                     name)
            in
            let* () = validate_external_connection ~typ ~name binding in
            let identifier =
              match typ with
              | "queue" -> "QUEUE_ARN"
              | "object_store" -> "OBJECT_ARN"
              | _ -> assert false
            in
            (match List.assoc_opt identifier binding.connection with
             | Some value when String.trim value <> "" -> Ok ()
             | _ ->
               Error
                 (Printf.sprintf
                    "external %s resource %S has no %s in binding.connection, so \
                     its                      provider permissions cannot be scoped"
                    typ
                    name
                    identifier))
          | _ -> Ok ())))
  |> Result.map (fun _ -> ())
;;

let external_connection ~(config : Sol_cli_config.t) ~service_name =
  let open Result.Syntax in
  let* service =
    match
      config.services
      |> List.find_opt (fun (service : Sol_cli_config.service) ->
        String.equal service.name service_name && not service.omit)
    with
    | Some service -> Ok service
    | None ->
      Ok
        { Sol_cli_config.name = service_name
        ; typ = None
        ; path = None
        ; uses = []
        ; scale_min = None
        ; scale_max = None
        ; language = None
        ; omit = false
        }
  in
  let* pairs =
    service.uses
    |> Sol_cli_result.map_list (fun ref ->
      match resource_name_of_ref ref with
      | None -> Ok []
      | Some name ->
        (match
           config.resources
           |> List.find_opt (fun (resource : Sol_cli_config.resource) ->
             String.equal resource.name name && not resource.omit)
         with
         | Some { typ = Some ("queue" | "object_store"); binding = Some binding; _ }
           when binding.ownership = Sol_cli_config.Ownership_external ->
           Ok binding.connection
         | _ -> Ok []))
  in
  Ok (List.concat pairs)
;;

let external_requirements ~(config : Sol_cli_config.t) ~service_name =
  let open Result.Syntax in
  let* service =
    match
      config.services
      |> List.find_opt (fun (service : Sol_cli_config.service) ->
        String.equal service.name service_name && not service.omit)
    with
    | Some service -> Ok service
    | None ->
      Ok
        { Sol_cli_config.name = service_name
        ; typ = None
        ; path = None
        ; uses = []
        ; scale_min = None
        ; scale_max = None
        ; language = None
        ; omit = false
        }
  in
  service.uses
  |> Sol_cli_result.map_list (fun ref ->
    match resource_name_of_ref ref with
    | None -> Ok []
    | Some name ->
      (match
         config.resources
         |> List.find_opt (fun (resource : Sol_cli_config.resource) ->
           String.equal resource.name name && not resource.omit)
       with
       | None -> Ok []
       | Some resource ->
         (match resource.typ with
          | Some (("queue" | "object_store") as typ) ->
            let* binding =
              match resource.binding with
              | Some binding when binding.ownership = Sol_cli_config.Ownership_external ->
                Ok binding
              | Some _ ->
                Error
                  (Printf.sprintf
                     "resource %S is managed; external %s bindings are the only \
                      supported                       shape"
                     name
                     typ)
              | None -> Error (Printf.sprintf "external resource %S has no binding" name)
            in
            let* () =
              if binding.keys = [] && binding.credentials = []
              then Ok ()
              else
                Error
                  (Printf.sprintf
                     "external resource %S declares secret references, but AWS \
                      workload                       identity is the only supported \
                      external authentication model today"
                     name)
            in
            let* () = validate_external_connection ~typ ~name binding in
            let identifier =
              match typ with
              | "queue" -> "QUEUE_ARN"
              | "object_store" -> "OBJECT_ARN"
              | _ -> assert false
            in
            let* resource_id =
              match List.assoc_opt identifier binding.connection with
              | Some value when String.trim value <> "" -> Ok value
              | _ ->
                Error
                  (Printf.sprintf
                     "external %s resource %S has no %s in binding.connection, so \
                      its                       provider permissions cannot be scoped"
                     typ
                     name
                     identifier)
            in
            Ok
              (Sol_cli_grant.resource_capabilities typ
               |> List.map (fun capability ->
                 Sol_cli_grant.requirement ~capability ~resource:resource_id))
          | _ -> Ok [])))
  |> Result.map List.concat
;;

let service_uses_resource_type declared service_name typ =
  match declared with
  | None -> false
  | Some cfg ->
    let resources = cfg.Sol_cli_config.resources in
    (match
       cfg.Sol_cli_config.services
       |> List.find_opt (fun (service : Sol_cli_config.service) ->
         service.name = service_name && not service.omit)
     with
     | None -> false
     | Some service ->
       service.uses
       |> List.exists (fun ref ->
         match resource_name_of_ref ref with
         | None -> false
         | Some name ->
           resources
           |> List.exists (fun (resource : Sol_cli_config.resource) ->
             resource.name = name && resource.typ = Some typ && not resource.omit)))
;;

let consumes_kafka declared service_name ~topics =
  topics <> [] || service_uses_resource_type declared service_name "kafka"
;;

(* Kafka is one connection/authority selection, rather than independent endpoint
   defaults and secret mappings. Names below are the existing application contract. *)
type external_kafka =
  { resource : string
  ; store : string
  ; brokers : string
  ; schema_registry_url : string
  ; admin_url : string
  ; username : string
  ; mechanism : string
  ; password : string
  ; ca : string
  }

type kafka =
  | No_kafka
  | Managed_kafka of string
  | External_kafka of external_kafka
  | Local_kafka of string

let kafka bindings =
  let open Result.Syntax in
  match of_type bindings ~typ:"kafka" with
  | [] -> Ok No_kafka
  | _ :: _ :: _ -> Error "this target supports one Kafka resource; omit unused resources"
  | [ binding ] ->
    if binding.ownership = Sol_cli_config.Ownership_sol
    then
      if
        binding.store <> None
        || binding.keys <> []
        || binding.connection <> []
        || binding.credentials <> []
      then
        Error
          (Printf.sprintf
             "managed Kafka %S cannot override its generated connection or authority"
             binding.resource)
      else Ok (Managed_kafka binding.resource)
    else (
      let required field values key =
        match List.assoc_opt key values with
        | Some value when String.trim value <> "" -> Ok value
        | _ ->
          Error
            (Printf.sprintf
               "external Kafka %S requires binding.%s.%s"
               binding.resource
               field
               key)
      in
      let* store =
        match binding.store with
        | Some store when String.trim store <> "" -> Ok store
        | _ ->
          Error (Printf.sprintf "external Kafka %S requires a store" binding.resource)
      in
      let* brokers = required "connection" binding.connection "KAFKA_BROKERS" in
      let* schema_registry_url =
        required "connection" binding.connection "SCHEMA_REGISTRY_URL"
      in
      let* admin_url = required "connection" binding.connection "REDPANDA_ADMIN_URL" in
      let* username = required "connection" binding.connection "KAFKA_SASL_USERNAME" in
      let* mechanism = required "connection" binding.connection "KAFKA_SASL_MECHANISM" in
      let* password = required "keys" binding.keys "KAFKA_SASL_PASSWORD" in
      let* ca = required "keys" binding.keys "KAFKA_SSL_CA_CERT" in
      let allowed_connection =
        [ "KAFKA_BROKERS"
        ; "SCHEMA_REGISTRY_URL"
        ; "REDPANDA_ADMIN_URL"
        ; "KAFKA_SASL_USERNAME"
        ; "KAFKA_SASL_MECHANISM"
        ]
      in
      let unsupported =
        List.filter_map
          (fun (key, _) ->
             if List.mem key allowed_connection then None else Some ("connection." ^ key))
          binding.connection
        @ List.filter_map
            (fun (key, _) ->
               if key = "KAFKA_SASL_PASSWORD" || key = "KAFKA_SSL_CA_CERT"
               then None
               else Some ("keys." ^ key))
            binding.keys
        @ List.map (fun (key, _) -> "credentials." ^ key) binding.credentials
      in
      let* () =
        match unsupported with
        | [] -> Ok ()
        | keys -> Error ("unsupported Kafka inputs: " ^ String.concat ", " keys)
      in
      let safe_endpoint ~scheme value =
        try
          let uri = Uri.of_string value in
          Uri.scheme uri = scheme
          && Option.is_some (Uri.host uri)
          && Uri.userinfo uri = None
          && Uri.query uri = []
          && Uri.fragment uri = None
          && (not (String.exists (fun c -> Char.code c <= 32 || Char.code c = 127) value))
          &&
          match Uri.port uri with
          | None -> scheme = Some "https"
          | Some port -> port > 0 && port < 65536
        with
        | Invalid_argument _ -> false
      in
      let* () =
        if not (List.mem mechanism [ "SCRAM-SHA-256"; "SCRAM-SHA-512"; "PLAIN" ])
        then Error "external Kafka requires a supported SASL mechanism"
        else if
          not
            (List.for_all
               (safe_endpoint ~scheme:(Some "https"))
               [ schema_registry_url; admin_url ])
        then
          Error
            "external Kafka registry/admin endpoints require HTTPS without embedded \
             credentials, query or fragment"
        else if
          not
            (String.split_on_char ',' brokers
             |> List.for_all (fun broker ->
               safe_endpoint ~scheme:None ("//" ^ broker)
               && not (String.contains broker '/')))
        then
          Error
            "external Kafka brokers must be host:port endpoints without credentials or \
             URL components"
        else Ok ()
      in
      Ok
        (External_kafka
           { resource = binding.resource
           ; store
           ; brokers
           ; schema_registry_url
           ; admin_url
           ; username
           ; mechanism
           ; password
           ; ca
           }))
;;

(* Kafka-only selection from a declared resource graph. Unlike [resolve_resources],
   this does not re-run the PostgreSQL cardinality decision: a caller that already
   holds a database selection must not have it re-derived here. *)
let kafka_of_resources resources =
  let open Result.Syntax in
  let* bindings = Sol_cli_result.map_list of_resource resources in
  kafka bindings
;;

let resolve_kafka config = Result.bind (resolve config) kafka

let kafka_resource = function
  | No_kafka -> None
  | Managed_kafka resource | Local_kafka resource -> Some resource
  | External_kafka binding -> Some binding.resource
;;

let kafka_is_managed = function
  | Managed_kafka _ -> true
  | _ -> false
;;

let kafka_for_shape ~shape = function
  | Managed_kafka resource when shape = Sol_cli_profile.Local -> Local_kafka resource
  | kafka -> kafka
;;

let kafka_config = function
  | No_kafka -> []
  | Managed_kafka _ -> Sol_cli_manifest.production_kafka_config
  | Local_kafka _ -> Sol_cli_manifest.kafka_connection_env Sol_cli_manifest.Plaintext
  | External_kafka binding ->
    let overrides =
      [ "KAFKA_BROKERS", binding.brokers
      ; "SCHEMA_REGISTRY_URL", binding.schema_registry_url
      ; "REDPANDA_ADMIN_URL", binding.admin_url
      ; "KAFKA_SASL_USERNAME", binding.username
      ; "KAFKA_SASL_MECHANISM", binding.mechanism
      ]
    in
    overrides
    @ List.filter
        (fun (key, _) -> not (List.mem_assoc key overrides))
        Sol_cli_manifest.production_kafka_config
;;

(* Both fresh deployment and rollback project this same resolved credential source.
   The target is a delivery identity, not a second credential authority. *)
let kafka_secret_sources ~target = function
  | Managed_kafka _ ->
    let secret = Sol_cli_manifest.kafka_creds_name ~target in
    List.map
      (fun key -> key, Sol_cli_secret_source.Target_kafka { secret })
      (Sol_cli_manifest.kafka_required_secret_keys Sol_cli_manifest.Sasl_ssl)
  | External_kafka binding ->
    [ ( Sol_cli_manifest.kafka_sasl_password_key
      , Sol_cli_secret_source.External { store = binding.store; key = binding.password } )
    ; ( Sol_cli_manifest.kafka_ca_secret_key
      , Sol_cli_secret_source.External { store = binding.store; key = binding.ca } )
    ]
  | No_kafka | Local_kafka _ -> []
;;

let kafka_authority_name ~cluster_name = "sol-kafka-" ^ cluster_name

let kafka_native_connection ~cluster_name = function
  | Managed_kafka resource ->
    Some
      (`Assoc
          [ "secret_name", `String (kafka_authority_name ~cluster_name)
          ; "resource", `String resource
          ; "username", `String Sol_cli_manifest_cluster_env.kafka_sasl_username
          ; "mechanism", `String Sol_cli_manifest_cluster_env.kafka_sasl_mechanism
          ])
  | No_kafka | Local_kafka _ | External_kafka _ -> None
;;
