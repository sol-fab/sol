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
    (* v1 supports one provisioned database per target, and the limit is on the effective
       graph — the resources that survive `omit` — not on what a unit consumes. The
       provisioner makes exactly one database and `has_postgres` carries no identity to
       select between them, so a second provisioned database cannot be satisfied. *)
    let provisioned =
      List.filter
        (fun b ->
           String.equal b.typ "postgres" && b.ownership = Sol_cli_config.Ownership_sol)
        bindings
    in
    (match provisioned with
     | _ :: _ :: _ ->
       Error
         (Printf.sprintf
            "this target's effective resource graph provisions %d PostgreSQL resources \
             (%s). v1 supports one provisioned database per target: omit the ones this \
             target does not provision, or bind them externally"
            (List.length provisioned)
            (String.concat ", " (List.map (fun b -> b.resource) provisioned)))
     | _ -> Ok bindings)
;;

let provisions bindings ~typ =
  List.exists
    (fun b -> String.equal b.typ typ && b.ownership = Sol_cli_config.Ownership_sol)
    bindings
;;

let of_type bindings ~typ = List.filter (fun b -> String.equal b.typ typ) bindings

let provisioned_database bindings =
  List.find_opt
    (fun b -> String.equal b.typ "postgres" && b.ownership = Sol_cli_config.Ownership_sol)
    bindings
;;

(* The one home for "which postgres resource is the target's": a provisioned database is
   authoritative when Sol owns one; otherwise the single external postgres is the target's.
   Two external postgres resources have no single target, so a consumer's `POSTGRES_URL`
   stays unit-scoped. *)
let target_database bindings =
  match provisioned_database bindings with
  | Some database -> Some database
  | None ->
    (match of_type bindings ~typ:"postgres" with
     | [ database ] -> Some database
     | _ -> None)
;;
