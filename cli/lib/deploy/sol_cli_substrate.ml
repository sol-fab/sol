let reserved_platform_namespaces =
  [ "cert-manager"
  ; "ingress-nginx"
  ; "argocd"
  ; "redpanda"
  ; Sol_cli_manifest.monitoring_namespace
  ; "postgresql"
  ]
;;

let namespaces (plan : Sol_cli_deployment_plan.t) : string list =
  plan.services
  |> List.map (fun (spec : Sol_cli_deployment_plan.service_spec) ->
    Sol_cli_deployment_plan.namespace_to_string spec.namespace)
  |> List.sort_uniq String.compare
;;

let docs_for_namespaces namespaces : Sol_cli_yaml.document list =
  List.map (fun ns -> Sol_cli_manifest.namespace_doc ~ns) namespaces
  @ List.map (fun ns -> Sol_cli_manifest.deploy_role_binding_doc ~ns) namespaces
  @ List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns) namespaces
;;

let create_idempotent = Sol_cli_manifest.create_idempotent

let with_doc_file doc f =
  Sol_cli_fs.with_temp_file
    ~prefix:"sol-substrate-"
    ~suffix:".yaml"
    (Sol_cli_yaml.render [ doc ])
    f
  |> Result.map_error (fun message -> Sol_cli_process.Spawn_failed message)
  |> Result.join
;;

let create_doc ~ctx doc = with_doc_file doc (fun file -> create_idempotent ~ctx ~file)

let create_failure e =
  "kubectl create (workspace substrate): " ^ Sol_cli_process.error_to_string e
;;

let apply_doc ~ctx doc =
  with_doc_file doc (fun file -> Sol_cli_kubectl.apply ~ctx ~file)
  |> Result.map_error (fun err ->
    Printf.sprintf
      "kubectl apply (workspace substrate): %s"
      (Sol_cli_process.error_to_string err))
;;

(* The cluster fact the platform publishes: which ranges reach this target's managed
   database, and on which port. It is a [result], not an [option], so a refused, unreachable
   or malformed read is not silently "no database" — that conflation is what let a target
   with a managed database deploy with no egress to it. An absent fact is still [Ok None];
   [ensure] decides whether that is acceptable from the target's ownership, which this
   function does not know. Returns [Ok None] when the fact carries no ranges (the platform's
   publication for a target with no managed database). *)
let platform_network_fact ~ctx =
  let what = "ConfigMap kube-system/sol-platform-network" in
  match
    Sol_cli_kubectl.get_if_present
      ~ctx
      ~args:
        [ "get"; "configmap"; "sol-platform-network"; "-n"; "kube-system"; "-o"; "json" ]
  with
  | Error error ->
    Error
      (Printf.sprintf
         "could not read the cluster's database-egress fact (%s): %s"
         what
         (Sol_cli_process.error_to_string error))
  | Ok None -> Ok None
  | Ok (Some body) ->
    (match Yojson.Safe.from_string body with
     | `Assoc fields ->
       let data =
         match List.assoc_opt "data" fields with
         | Some (`Assoc entries) -> entries
         | _ -> []
       in
       let cidrs =
         match List.assoc_opt "database-egress-cidrs" data with
         | Some (`String text) ->
           String.split_on_char ',' text
           |> List.map String.trim
           |> List.filter (fun cidr -> cidr <> "")
         | _ -> []
       in
       let port =
         match List.assoc_opt "database-port" data with
         | Some (`String text) ->
           Option.value (int_of_string_opt (String.trim text)) ~default:5432
         | _ -> 5432
       in
       if cidrs = [] then Ok None else Ok (Some (cidrs, port))
     | _ -> Error (Printf.sprintf "the database-egress fact (%s) is not an object" what)
     | exception Yojson.Json_error message ->
       Error
         (Printf.sprintf
            "the database-egress fact (%s) is not valid JSON: %s"
            what
            message))
;;

let ensure ~workloads ~ctx ~namespaces ~manages_database : (unit, string) result =
  let open Result.Syntax in
  match List.find_opt (fun ns -> List.mem ns reserved_platform_namespaces) namespaces with
  | Some ns ->
    Error
      (Printf.sprintf
         "%s is a reserved platform namespace; no workspace may deploy into it"
         ns)
  | None ->
    let rec create_all = function
      | [] -> Ok ()
      | doc :: rest ->
        let* () = create_doc ~ctx doc |> Result.map_error create_failure in
        create_all rest
    in
    let rec apply_all = function
      | [] -> Ok ()
      | doc :: rest ->
        let* () = apply_doc ~ctx doc in
        apply_all rest
    in
    let* () = create_all (docs_for_namespaces namespaces) in
    let* () =
      match workloads with
      | [] -> Ok ()
      | _ :: _ ->
        let* fact = platform_network_fact ~ctx in
        (match fact with
         | Some (cidrs, port) ->
           apply_all
             (List.map
                (fun (ns, name) ->
                   Sol_cli_manifest.managed_database_egress_doc ~cidrs ~port ~ns ~name)
                workloads)
         | None when not manages_database -> Ok ()
         | None ->
           Error
             "the target provisions a Sol-managed database, but the cluster has \
              published no database-egress ranges (ConfigMap \
              kube-system/sol-platform-network is absent, unreadable or empty), so the \
              workloads would have no route to it. Reconcile the environment for this \
              target so the platform install publishes the range, then retry.")
    in
    namespaces
    |> List.find_map (fun ns ->
      match Sol_cli_secret.verify_runtime_secret ~ctx ~namespace:ns with
      | Ok () -> None
      | Error message -> Some message)
    |> (function
     | None -> Ok ()
     | Some message -> Error message)
;;

let established ~ctx ~namespaces : (unit, string) result =
  let open Result.Syntax in
  let check_ns ns =
    match
      Sol_cli_kubectl.get ~ctx ~resource:"namespace" ~name:ns ~namespace:"" ~output:"name"
    with
    | Ok _ -> Ok ()
    | Error _ ->
      Error
        (Printf.sprintf
           "namespace %s does not exist, so the deploy identity holds no scoped \
            authority in it; Sol establishes a namespace and its scoped RBAC together, \
            and neither is present here"
           ns)
  in
  let check_binding ns name =
    match
      Sol_cli_kubectl.get ~ctx ~resource:"rolebinding" ~name ~namespace:ns ~output:"name"
    with
    | Ok _ -> Ok ()
    | Error _ ->
      Error
        (Printf.sprintf
           "namespace %s exists but has no %s RoleBinding, so any manifest operation \
            there would be refused before it began; deploy into %s with a live run, \
            which establishes the namespace and its scoped RBAC before it touches a \
            manifest"
           ns
           name
           ns)
  in
  let rec check = function
    | [] -> Ok ()
    | ns :: rest ->
      let* () = check_ns ns in
      let* () =
        List.fold_left
          (fun acc name -> Result.bind acc (fun () -> check_binding ns name))
          (Ok ())
          [ "sol-deploy"; "sol-operator" ]
      in
      check rest
  in
  check namespaces
;;

let namespaces_of_services ~workspace (services : Sol_cli_manifest.service list) =
  services
  |> List.filter_map (fun s ->
    match
      Sol_cli_deployment_plan.namespace_result
        ~workspace
        ~domain:s.Sol_cli_manifest.domain
    with
    | Ok ns -> Some (Sol_cli_deployment_plan.namespace_to_string ns)
    | Error _ -> None)
  |> List.sort_uniq String.compare
;;

let operator_binding_docs ~workspace (services : Sol_cli_manifest.service list)
  : Sol_cli_yaml.document list
  =
  namespaces_of_services ~workspace services
  |> List.map (fun ns -> Sol_cli_manifest.operator_role_binding_doc ~ns)
;;

let reconcile_operator_bindings ~ctx ~workspace ~services : (unit, string) result =
  let namespaces = namespaces_of_services ~workspace services in
  let failures =
    namespaces
    |> List.filter_map (fun ns ->
      match create_doc ~ctx (Sol_cli_manifest.operator_role_binding_doc ~ns) with
      | Ok () -> None
      | Error e when Sol_cli_kubectl.classify e = Not_found -> None
      | Error e -> Some (Printf.sprintf "%s: %s" ns (create_failure e)))
  in
  match failures with
  | [] -> Ok ()
  | failures -> Error (String.concat "; " failures)
;;
