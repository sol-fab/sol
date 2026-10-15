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

let resolve (cfg : Sol_cli_config.t) =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | r :: rest ->
      (match of_resource r with
       | Error _ as error -> error
       | Ok binding -> go (binding :: acc) rest)
  in
  match go [] (Sol_cli_config.resources cfg) with
  | Error _ as error -> error
  | Ok bindings ->
    (* v1 supports one database per target, and the limit is on the effective graph — the
       resources that survive `omit` — not on what a unit consumes. The delivered class
       Secrets are named for the target, so a consumer cannot tell two databases apart
       whatever their ownership: two Sol-provisioned databases, two external ones, and a
       Sol-provisioned plus an external one are the same ambiguity. Rejecting it here, where
       the effective graph is resolved, is what keeps it from surfacing later as a delivery
       failure or as an external dependency whose derived delivery was silently skipped. *)
    let databases = List.filter (fun b -> String.equal b.typ "postgres") bindings in
    (match databases with
     | _ :: _ :: _ ->
       Error
         (Printf.sprintf
            "this target's effective resource graph declares %d PostgreSQL resources \
             (%s). v1 supports one database per target: the delivered credential Secrets \
             are named for the target, so two databases cannot be told apart by their \
             consumers. Omit the ones this target does not use"
            (List.length databases)
            (String.concat ", " (List.map (fun b -> b.resource) databases)))
     | _ -> Ok bindings)
;;

let provisions bindings ~typ =
  List.exists
    (fun b -> String.equal b.typ typ && b.ownership = Sol_cli_config.Ownership_sol)
    bindings
;;

(** Whether Sol provisions a [typ] resource in the config's effective graph. The decision
    refuses when that graph cannot be resolved: reading the error as "not Sol-provisioned"
    would skip the CA mount and treat the database as someone else's, which is the fail-open
    shape this boundary removes (#1469). Callers that need the answer apply their own message;
    the resolution error is preserved. *)
let provisions_of_config (cfg : Sol_cli_config.t) ~typ =
  match resolve cfg with
  | Ok bindings -> Ok (provisions bindings ~typ)
  | Error _ as error -> error
;;

let of_type bindings ~typ = List.filter (fun b -> String.equal b.typ typ) bindings

let provisioned_database bindings =
  List.find_opt
    (fun b -> String.equal b.typ "postgres" && b.ownership = Sol_cli_config.Ownership_sol)
    bindings
;;

(* The one home for "which postgres resource is the target's": a provisioned database is
   authoritative when Sol owns one; otherwise the single external postgres is the target's.
   [resolve] has already refused a graph with more than one postgres resource, so [None]
   here means the target simply has no database. *)
let target_database bindings =
  match provisioned_database bindings with
  | Some database -> Some database
  | None ->
    (match of_type bindings ~typ:"postgres" with
     | [ database ] -> Some database
     | _ -> None)
;;
