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
