(** Read-only resource inventory: recorded state, independent provider observation, and
    the ownership/recovery distinction. This module classifies; it never imports,
    deletes, unlocks, or adopts. *)

type layer =
  | Installation
  | Cloud
  | Platform
  | Authorization
  | Serverless
  | Workload

type root_role =
  | Installation_root
  | Cluster_root
  | Platform_root
  | Authorization_root

type status =
  | Owned
  | Recorded
  | Missing
  | Unrecorded
  | External
  | In_cluster
  | Synthetic
  | Uid_mismatch of string
  | Absent
  | Unknown of string

type recovery =
  | Not_applicable
  | Recoverable of
      { address : string
      ; import_identity : string
      }
  | Unrecoverable of string
  | Unmapped of string

type observation =
  | Observed
  | Unobserved
  | By_contract
  | Failed of string

type action =
  | No_action
  | Adopt
  | Investigate
  | Retain
  | Uninstall

type row =
  { layer : layer
  ; root : string
  ; address : string option
  ; resource_class : string
  ; name : string option
  ; identity : string option
  ; observed_as : string option
  ; ownership_kind : string option
  ; uid : string option
  ; uid_status : [ `Match | `Mismatch | `No_record | `Not_applicable ]
  ; import_identity : string option
  ; status : status
  ; recovery : recovery
  ; observation : observation
  ; action : action
  ; reason : string option
  ; checked_with : string option
  ; lifetime : [ `Installation | `Target | `Workload ]
  ; deletion_protection : bool option
  }

type root =
  { role : root_role
  ; layer : layer
  ; durable : bool
  ; state : Sol_cli_cloud_destroy.state_read
  ; last_operation : Sol_cli_supervised.status
  ; errored_state : bool
  }

type verdict =
  | Reconciled
  | Incomplete
  | Attention_required
  | Unknown_verdict
  | Unverified

type coverage =
  { inventory_complete : bool
  ; verification_complete : bool
  ; required_classes : string list
  ; observed_classes : string list
  ; by_contract_classes : string list
  ; unobserved_classes : string list
  ; failed_classes : string list
  ; recorded_unverified : string list
  }

type summary =
  { owned : int
  ; recorded : int
  ; missing : int
  ; unrecorded : int
  ; external_resources : int
  ; in_cluster : int
  ; synthetic : int
  ; uid_mismatch : int
  ; unknown : int
  }

type inventory =
  { target : Sol_cli_config.target
  ; roots : root list
  ; rows : row list
  ; coverage : coverage
  ; summary : summary
  ; verdict : verdict
  ; unknowns : string list
  }

let layer_to_string = function
  | Installation -> "installation"
  | Cloud -> "cloud"
  | Platform -> "platform"
  | Authorization -> "authorization"
  | Serverless -> "serverless"
  | Workload -> "workload"
;;

let root_role_to_string = function
  | Installation_root -> "bootstrap"
  | Cluster_root -> "cluster"
  | Platform_root -> "platform"
  | Authorization_root -> "authorization"
;;

let status_to_string = function
  | Owned -> "owned"
  | Recorded -> "recorded"
  | Missing -> "missing"
  | Unrecorded -> "unrecorded"
  | External -> "external"
  | In_cluster -> "in_cluster"
  | Synthetic -> "synthetic"
  | Uid_mismatch _ -> "uid_mismatch"
  | Absent -> "absent"
  | Unknown _ -> "unknown"
;;

let recovery_to_string = function
  | Not_applicable -> "not_applicable"
  | Recoverable _ -> "recoverable"
  | Unrecoverable _ -> "unrecoverable"
  | Unmapped _ -> "unmapped"
;;

let observation_to_string = function
  | Observed -> "observed"
  | Unobserved -> "unobserved"
  | By_contract -> "by_contract"
  | Failed _ -> "failed"
;;

let action_to_string = function
  | No_action -> "none"
  | Adopt -> "adopt"
  | Investigate -> "investigate"
  | Retain -> "retain"
  | Uninstall -> "uninstall"
;;

let verdict_to_string = function
  | Reconciled -> "reconciled"
  | Incomplete -> "incomplete"
  | Attention_required -> "attention_required"
  | Unknown_verdict -> "unknown"
  | Unverified -> "unverified"
;;

let state_to_string = function
  | Sol_cli_cloud_destroy.State_empty -> "empty"
  | Sol_cli_cloud_destroy.State_represented _ -> "represented"
  | Sol_cli_cloud_destroy.State_unreadable _ -> "unreadable"
;;

let supervised_status_to_json status =
  match status with
  | Sol_cli_supervised.No_previous -> `Assoc [ "status", `String "no_previous" ]
  | Running { pid; host; started_at; dir } ->
    `Assoc
      [ "status", `String "running"
      ; "pid", `Int pid
      ; "host", `String host
      ; "started_at", `String (Sol_cli_time.rfc3339 started_at)
      ; "record", `String dir
      ]
  | Resolved { outcome; dir } ->
    let outcome =
      match outcome with
      | Sol_cli_supervised.Exited code -> Printf.sprintf "exited %d" code
      | Sol_cli_supervised.Signaled signal -> Printf.sprintf "signaled %d" signal
    in
    `Assoc
      [ "status", `String "resolved"; "outcome", `String outcome; "record", `String dir ]
  | Unresolved { reason; dir } ->
    `Assoc
      [ "status", `String "unresolved"; "reason", `String reason; "record", `String dir ]
;;

let root_of_state
      ~role
      ~layer
      ~durable
      ~chdir
      ~backend_config
      (state : Sol_cli_cloud_destroy.state_read)
  =
  let last_operation = Sol_cli_terraform.previous_operation ~chdir ~backend_config in
  let errored_state = Sys.file_exists (Filename.concat chdir "errored.tfstate") in
  { role; layer; durable; state; last_operation; errored_state }
;;

let read_root ~role ~layer ~durable ~chdir ~backend_config =
  let state =
    match Sol_cli_terraform.show_json ~chdir () with
    | Ok result -> Sol_cli_cloud_destroy.inventory_of_show_json result.stdout
    | Error (Sol_cli_process.Non_zero result) ->
      Sol_cli_cloud_destroy.State_unreadable
        (Printf.sprintf "terraform show exited %d" result.exit_code)
    | Error error ->
      Sol_cli_cloud_destroy.State_unreadable
        ("terraform show could not be run: " ^ Sol_cli_process.error_to_string error)
  in
  root_of_state ~role ~layer ~durable ~chdir ~backend_config state
;;

let unreadable_root ~role ~layer ~durable ~chdir ~backend_config reason =
  root_of_state
    ~role
    ~layer
    ~durable
    ~chdir
    ~backend_config
    (Sol_cli_cloud_destroy.State_unreadable reason)
;;

let by_contract_ownership = function
  | Sol_cli_resource_identity.In_cluster _ -> true
  | Sol_cli_resource_identity.Synthetic _ -> true
  | Sol_cli_resource_identity.External_by_contract _ -> true
  | Sol_cli_resource_identity.Direct | Sol_cli_resource_identity.Direct_not_recoverable _
    -> false
;;

let by_contract_status = function
  | Sol_cli_resource_identity.In_cluster _ -> In_cluster
  | Sol_cli_resource_identity.Synthetic _ -> Synthetic
  | Sol_cli_resource_identity.External_by_contract _ -> External
  | Sol_cli_resource_identity.Direct | Sol_cli_resource_identity.Direct_not_recoverable _
    -> Recorded
;;

let substrate_class_of_kind = function
  | "aws_eks_cluster" -> Some "EKS cluster"
  | "aws_eks_node_group" -> Some "EKS node group"
  | "google_container_cluster" -> Some "GKE cluster"
  | "google_container_node_pool" -> Some "GKE node pool"
  | _ -> None
;;

let synthetic_kind kind =
  String.starts_with ~prefix:"terraform_data" kind
  || String.starts_with ~prefix:"random_" kind
  || String.starts_with ~prefix:"null_resource" kind
;;

let in_cluster_kind kind =
  String.starts_with ~prefix:"kubernetes_" kind || String.starts_with ~prefix:"helm_" kind
;;

type class_state =
  | Class_observed of string list
  | Class_absent
  | Class_external
  | Class_failed of string

let class_map observations =
  let table = Hashtbl.create 32 in
  let merge class_name next =
    match Hashtbl.find_opt table class_name with
    | None -> Hashtbl.replace table class_name next
    | Some (Class_failed _) -> ()
    | Some (Class_observed _ as current) ->
      (match next with
       | Class_observed found ->
         let current =
           match current with
           | Class_observed existing -> Class_observed (existing @ found)
           | _ -> current
         in
         Hashtbl.replace table class_name current
       | Class_absent | Class_external | Class_failed _ -> ())
    | Some Class_absent ->
      (match next with
       | Class_observed _ | Class_failed _ | Class_external ->
         Hashtbl.replace table class_name next
       | Class_absent -> ())
    | Some Class_external -> ()
  in
  List.iter
    (function
      | Sol_cli_absence.Present { resource_class; found; _ } ->
        merge resource_class (Class_observed found)
      | Sol_cli_absence.Absent { resource_class; _ } -> merge resource_class Class_absent
      | Sol_cli_absence.External { resource_class; _ } ->
        merge resource_class Class_external
      | Sol_cli_absence.Unobservable { resource_class; reason; _ }
      | Sol_cli_absence.Not_attributable { resource_class; reason } ->
        merge resource_class (Class_failed reason))
    observations;
  table
;;

let trim_values values = List.map String.trim values |> List.filter (fun v -> v <> "")

let membership observed_as found =
  let observed_as = String.trim observed_as in
  let found = trim_values found in
  if observed_as = ""
  then false
  else if Sol_cli_string.contains ~needle:"*" observed_as
  then false
  else List.exists (String.equal observed_as) found
;;

let wildcard observed_as = Sol_cli_string.contains ~needle:"*" observed_as

let find_entry entries address =
  List.find_opt
    (fun (entry : Sol_cli_resource_identity.entry) -> String.equal entry.address address)
    entries
;;

let class_for_resource ~provider ~entries (resource : Sol_cli_cloud_destroy.resource) =
  match find_entry entries resource.address with
  | Some entry ->
    let class_name =
      if not (Sol_cli_string.is_blank entry.resource_class)
      then entry.resource_class
      else Option.value (substrate_class_of_kind resource.kind) ~default:resource.kind
    in
    let observed_as =
      if not (Sol_cli_string.is_blank entry.observed_as)
      then Some entry.observed_as
      else Sol_cli_cloud_destroy.resource_name resource
    in
    ( class_name
    , observed_as
    , Some entry.ownership
    , if Sol_cli_string.is_blank entry.import_identity
      then None
      else Some entry.import_identity )
  | None ->
    (match Sol_cli_provider_registry.inventory_auth_class provider resource with
     | Some (class_name, name) -> class_name, name, None, None
     | None ->
       (match substrate_class_of_kind resource.kind with
        | Some class_name ->
          class_name, Sol_cli_cloud_destroy.resource_name resource, None, None
        | None ->
          let class_name, ownership =
            if in_cluster_kind resource.kind
            then
              ( resource.kind
              , Some
                  (Sol_cli_resource_identity.In_cluster
                     "recorded in the cluster; no separate provider identity") )
            else if synthetic_kind resource.kind
            then
              ( resource.kind
              , Some
                  (Sol_cli_resource_identity.Synthetic
                     "Terraform-internal bookkeeping; no provider object") )
            else resource.kind, None
          in
          class_name, Sol_cli_cloud_destroy.resource_name resource, ownership, None))
;;

let row
      ~layer
      ~root
      ~address
      ~resource_class
      ~name
      ~identity
      ~observed_as
      ~ownership_kind
      ~import_identity
      ~status
      ~recovery
      ~observation
      ~action
      ~reason
      ~checked_with
      ~lifetime
      ~deletion_protection
  =
  { layer
  ; root
  ; address
  ; resource_class
  ; name
  ; identity
  ; observed_as
  ; ownership_kind
  ; uid = None
  ; uid_status = `Not_applicable
  ; import_identity
  ; status
  ; recovery
  ; observation
  ; action
  ; reason
  ; checked_with
  ; lifetime
  ; deletion_protection
  }
;;

let observed_row ~provider ~entries ~classes ~root_record ~layer ~resource =
  let class_name, observed_as, ownership, import_identity =
    class_for_resource ~provider ~entries resource
  in
  let ownership_kind = Option.map Sol_cli_resource_identity.ownership_kind ownership in
  let name = Sol_cli_cloud_destroy.resource_name resource in
  let make ?reason ?checked_with status recovery observation action =
    row
      ~layer
      ~root:(root_role_to_string root_record.role)
      ~address:(Some resource.address)
      ~resource_class:class_name
      ~name
      ~identity:observed_as
      ~observed_as
      ~ownership_kind
      ~import_identity
      ~status
      ~recovery
      ~observation
      ~action
      ~reason
      ~checked_with
      ~lifetime:
        (match layer with
         | Installation -> `Installation
         | Workload -> `Workload
         | Cloud | Platform | Authorization | Serverless -> `Target)
      ~deletion_protection:resource.deletion_protection
  in
  let by_contract =
    match ownership with
    | Some (Sol_cli_resource_identity.Direct_not_recoverable _)
      when Sol_cli_string.is_blank class_name -> true
    | Some ownership -> by_contract_ownership ownership
    | None -> false
  in
  if by_contract
  then (
    let status =
      match ownership with
      | Some (Sol_cli_resource_identity.Direct_not_recoverable _)
        when Sol_cli_string.is_blank class_name -> Recorded
      | Some ownership -> by_contract_status ownership
      | None -> Recorded
    in
    make
      status
      Not_applicable
      By_contract
      (match layer with
       | Installation -> Retain
       | _ -> No_action))
  else (
    match Hashtbl.find_opt classes class_name with
    | Some (Class_failed reason) ->
      make ~reason (Unknown reason) Not_applicable (Failed reason) Investigate
    | Some Class_external -> make External Not_applicable By_contract Retain
    | Some Class_absent ->
      (match observed_as with
       | None ->
         make
           ~reason:"the state records no provider identity for this address"
           Recorded
           Not_applicable
           Unobserved
           Investigate
       | Some identity when wildcard identity ->
         make
           ~reason:"the class probe cannot name this exact identity"
           Recorded
           Not_applicable
           Unobserved
           Investigate
       | Some _ ->
         make
           ~reason:"the provider reports this class absent"
           Missing
           Not_applicable
           Observed
           Investigate)
    | Some (Class_observed found) ->
      (match observed_as with
       | Some identity when membership identity found ->
         make Owned Not_applicable Observed No_action
       | Some identity when wildcard identity ->
         make
           ~reason:
             "the identity registry records a wildcard, so this address cannot be \
              verified by exact name"
           Recorded
           Not_applicable
           Unobserved
           Investigate
       | Some _ ->
         make
           ~reason:"the provider class was observed but did not name this identity"
           Missing
           Not_applicable
           Observed
           Investigate
       | None ->
         make
           ~reason:"the state records no provider identity for this address"
           Recorded
           Not_applicable
           Unobserved
           Investigate)
    | None ->
      make
        ~reason:(Printf.sprintf "no executable probe covers class %S" class_name)
        Recorded
        Not_applicable
        Unobserved
        Investigate)
;;

let state_row ~provider ~entries ~classes ~root ~layer ~resource =
  match root.role with
  | Installation_root ->
    let class_name, observed_as, _, _ = class_for_resource ~provider ~entries resource in
    row
      ~layer
      ~root:(root_role_to_string root.role)
      ~address:(Some resource.address)
      ~resource_class:class_name
      ~name:(Sol_cli_cloud_destroy.resource_name resource)
      ~identity:observed_as
      ~observed_as
      ~ownership_kind:(Some "External_by_contract")
      ~import_identity:None
      ~status:External
      ~recovery:Not_applicable
      ~observation:By_contract
      ~action:Retain
      ~reason:
        (Some "installation resource; durable by contract and removed by sol uninstall")
      ~checked_with:None
      ~lifetime:`Installation
      ~deletion_protection:resource.deletion_protection
  | Cluster_root | Platform_root | Authorization_root ->
    observed_row ~provider ~entries ~classes ~root_record:root ~layer ~resource
;;

let provider_row ~root ~layer ~resource_class ~found ~disposition =
  let base ?address ?import_identity ?reason status recovery observation action =
    row
      ~layer
      ~root:(root_role_to_string root.role)
      ~address
      ~resource_class
      ~name:(Some found)
      ~identity:(Some found)
      ~observed_as:(Some found)
      ~ownership_kind:None
      ~import_identity
      ~status
      ~recovery
      ~observation
      ~action
      ~reason
      ~checked_with:None
      ~lifetime:`Target
      ~deletion_protection:None
  in
  match disposition with
  | Sol_cli_ownership_reconciliation.Recover candidate ->
    Some
      (base
         ~address:candidate.address
         ~import_identity:candidate.import_identity
         ~reason:
           "observed provider object is attributable to this target and not recorded in \
            state"
         Unrecorded
         (Recoverable
            { address = candidate.address; import_identity = candidate.import_identity })
         Observed
         Adopt)
  | Sol_cli_ownership_reconciliation.Cannot_recover { reason; _ } ->
    Some (base ~reason Unrecorded (Unrecoverable reason) Observed Investigate)
  | Sol_cli_ownership_reconciliation.Unmapped _ ->
    Some
      (base
         ~reason:"no Terraform address Sol can attribute this observed object to"
         Unrecorded
         (Unmapped "no registry entry")
         Observed
         Investigate)
  | Sol_cli_ownership_reconciliation.Unresolved { reason; _ } ->
    Some (base ~reason (Unknown reason) Not_applicable (Failed reason) Investigate)
  | Sol_cli_ownership_reconciliation.By_contract _ ->
    Some (base External Not_applicable By_contract Retain)
  | Sol_cli_ownership_reconciliation.Already_owned { address; _ } ->
    ignore address;
    None
;;

let dedupe rows =
  let seen = Hashtbl.create 32 in
  List.filter
    (fun row ->
       let key =
         ( row.root
         , row.resource_class
         , Option.value row.identity ~default:(Option.value row.address ~default:"") )
       in
       if Hashtbl.mem seen key
       then false
       else (
         Hashtbl.replace seen key ();
         true))
    rows
;;

let sort_rows rows =
  let layer_order = function
    | Installation -> 0
    | Cloud -> 1
    | Platform -> 2
    | Authorization -> 3
    | Serverless -> 4
    | Workload -> 5
  in
  List.sort
    (fun (a : row) (b : row) ->
       let c = Int.compare (layer_order a.layer) (layer_order b.layer) in
       if c <> 0
       then c
       else (
         let c = String.compare a.resource_class b.resource_class in
         if c <> 0
         then c
         else
           String.compare
             (Option.value a.address ~default:"")
             (Option.value b.address ~default:"")))
    rows
;;

let summary_of_rows rows =
  let count predicate = List.length (List.filter predicate rows) in
  { owned = count (fun r -> r.status = Owned)
  ; recorded = count (fun r -> r.status = Recorded)
  ; missing = count (fun r -> r.status = Missing)
  ; unrecorded = count (fun r -> r.status = Unrecorded)
  ; external_resources = count (fun r -> r.status = External)
  ; in_cluster = count (fun r -> r.status = In_cluster)
  ; synthetic = count (fun r -> r.status = Synthetic)
  ; uid_mismatch =
      count (fun r ->
        match r.status with
        | Uid_mismatch _ -> true
        | _ -> false)
  ; unknown =
      count (fun r ->
        match r.status with
        | Unknown _ -> true
        | _ -> false)
  }
;;

let class_set_of_observations observations =
  let observed = ref [] in
  let failed = ref [] in
  let by_contract = ref [] in
  List.iter
    (fun observation ->
       match observation with
       | Sol_cli_absence.Present { resource_class; _ }
       | Sol_cli_absence.Absent { resource_class; _ } ->
         observed := resource_class :: !observed
       | Sol_cli_absence.External { resource_class; _ } ->
         by_contract := resource_class :: !by_contract
       | Sol_cli_absence.Unobservable { resource_class; reason; _ }
       | Sol_cli_absence.Not_attributable { resource_class; reason } ->
         failed := (resource_class, reason) :: !failed)
    observations;
  ( List.sort_uniq String.compare !observed
  , List.sort_uniq String.compare !by_contract
  , List.sort_uniq (fun (a, _) (b, _) -> String.compare a b) !failed )
;;

let verdict_of ~inventory_complete ~failed ~discrepancy ~unverified ~state_only =
  if (not inventory_complete) || failed
  then Unknown_verdict
  else if state_only
  then Unverified
  else if discrepancy
  then Attention_required
  else if unverified
  then Incomplete
  else Reconciled
;;

let collect
      (target : Sol_cli_config.target)
      ~roots
      ~(cloud : Sol_cli_cloud_wiring.cloud_collection option)
      ~state_only
  =
  let provider = target.provider in
  let entries =
    match target.cluster_name with
    | Some cluster_name ->
      Sol_cli_provider_registry.resource_identity
        provider
        ~cluster_name
        ~project_id:(Sol_cli_config.provider_field target "project_id")
    | None -> []
  in
  let observations =
    match cloud with
    | Some collection -> collection.observations
    | None -> []
  in
  let authorization_unreadable =
    List.exists
      (fun root ->
         root.role = Authorization_root
         &&
         match root.state with
         | Sol_cli_cloud_destroy.State_unreadable _ -> true
         | Sol_cli_cloud_destroy.State_empty | Sol_cli_cloud_destroy.State_represented _
           -> false)
      roots
  in
  let observations =
    if not authorization_unreadable
    then observations
    else
      List.filter
        (fun observation ->
           let resource_class =
             match observation with
             | Sol_cli_absence.Present { resource_class; _ }
             | Sol_cli_absence.Absent { resource_class; _ }
             | Sol_cli_absence.External { resource_class; _ }
             | Sol_cli_absence.Unobservable { resource_class; _ }
             | Sol_cli_absence.Not_attributable { resource_class; _ } -> resource_class
           in
           not (String.starts_with ~prefix:"authorization " resource_class))
        observations
  in
  let classes = class_map observations in
  let state_rows =
    roots
    |> List.concat_map (fun root ->
      Sol_cli_cloud_destroy.resources root.state
      |> List.map (fun resource ->
        state_row ~provider ~entries ~classes ~root ~layer:root.layer ~resource))
  in
  let provider_rows =
    match cloud, List.find_opt (fun root -> root.role = Cluster_root) roots with
    | Some collection, Some cloud_root ->
      let authorization_root =
        List.find_opt (fun root -> root.role = Authorization_root) roots
      in
      let target resource_class =
        match authorization_root with
        | Some root when String.starts_with ~prefix:"authorization " resource_class ->
          root, Authorization
        | Some _ | None -> cloud_root, Cloud
      in
      collection.dispositions
      |> List.filter_map (fun disposition ->
        match disposition with
        | Sol_cli_ownership_reconciliation.Already_owned _ -> None
        | Sol_cli_ownership_reconciliation.Recover candidate ->
          let root, layer = target candidate.resource_class in
          provider_row
            ~root
            ~layer
            ~resource_class:candidate.resource_class
            ~found:candidate.found
            ~disposition
        | Sol_cli_ownership_reconciliation.Cannot_recover { resource_class; found; _ }
        | Sol_cli_ownership_reconciliation.Unmapped { resource_class; found }
        | Sol_cli_ownership_reconciliation.By_contract { resource_class; found } ->
          let root, layer = target resource_class in
          provider_row ~root ~layer ~resource_class ~found ~disposition
        | Sol_cli_ownership_reconciliation.Unresolved { resource_class; _ } ->
          let root, layer = target resource_class in
          provider_row ~root ~layer ~resource_class ~found:"" ~disposition)
    | Some _, None | None, _ -> []
  in
  let rows = sort_rows (dedupe (state_rows @ provider_rows)) in
  let inventory_complete =
    List.for_all
      (fun root ->
         match root.state with
         | Sol_cli_cloud_destroy.State_empty | Sol_cli_cloud_destroy.State_represented _
           -> true
         | Sol_cli_cloud_destroy.State_unreadable _ -> false)
      roots
  in
  let observed_classes, observed_by_contract_classes, failed =
    class_set_of_observations observations
  in
  let failed_classes = List.map fst failed in
  let state_by_contract_classes =
    state_rows
    |> List.filter_map (fun row ->
      if row.observation = By_contract then Some row.resource_class else None)
  in
  let by_contract_classes =
    List.sort_uniq
      String.compare
      (observed_by_contract_classes @ state_by_contract_classes)
  in
  let required =
    let set = ref [] in
    let add class_name =
      if not (Sol_cli_string.is_blank class_name) then set := class_name :: !set
    in
    List.iter add (Sol_cli_provider_registry.observed_classes provider);
    List.iter
      (fun (entry : Sol_cli_resource_identity.entry) -> add entry.resource_class)
      entries;
    let provider_observed = Sol_cli_provider_registry.observed_classes provider in
    List.iter
      (fun class_name -> if List.mem class_name provider_observed then add class_name)
      (Sol_cli_cloud_destroy.required_identity_classes ());
    List.iter (fun row -> add row.resource_class) state_rows;
    List.sort_uniq String.compare !set
  in
  let recorded_unverified =
    rows
    |> List.filter_map (fun row ->
      if row.status = Recorded && row.observation <> By_contract
      then Some (Option.value row.address ~default:row.resource_class)
      else None)
  in
  let unobserved_classes =
    required
    |> List.filter (fun class_name ->
      (not (List.mem class_name observed_classes))
      && (not (List.mem class_name by_contract_classes))
      && not (List.mem class_name failed_classes))
    |> List.sort_uniq String.compare
  in
  let verification_complete =
    (not state_only)
    && unobserved_classes = []
    && failed_classes = []
    && recorded_unverified = []
  in
  let discrepancy =
    List.exists
      (fun row ->
         match row.status with
         | Unrecorded | Missing | Uid_mismatch _ -> true
         | Owned | Recorded | External | In_cluster | Synthetic | Absent | Unknown _ ->
           false)
      rows
  in
  let verdict =
    verdict_of
      ~inventory_complete
      ~failed:(failed_classes <> [])
      ~discrepancy
      ~unverified:(not verification_complete)
      ~state_only
  in
  let unknowns =
    roots
    |> List.filter_map (fun root ->
      match root.state with
      | Sol_cli_cloud_destroy.State_unreadable reason ->
        Some (root_role_to_string root.role ^ ": " ^ reason)
      | Sol_cli_cloud_destroy.State_empty | Sol_cli_cloud_destroy.State_represented _ ->
        None)
    |> fun root_unknowns ->
    root_unknowns
    @ List.map (fun (class_name, reason) -> class_name ^ ": " ^ reason) failed
  in
  let coverage =
    { inventory_complete
    ; verification_complete
    ; required_classes = required
    ; observed_classes
    ; by_contract_classes
    ; unobserved_classes
    ; failed_classes
    ; recorded_unverified
    }
  in
  { target; roots; rows; coverage; summary = summary_of_rows rows; verdict; unknowns }
;;

let status_is_material row =
  match row.status with
  | In_cluster | Synthetic | Absent -> false
  | Owned | Recorded | Missing | Unrecorded | External | Uid_mismatch _ | Unknown _ ->
    true
;;

let filter_rows ~all ~classes ~statuses rows =
  let wanted_status status =
    statuses = []
    || List.mem (status_to_string status) statuses
    ||
    match status with
    | Unknown _ -> List.mem "unknown" statuses
    | Uid_mismatch _ -> List.mem "uid_mismatch" statuses
    | _ -> false
  in
  rows
  |> List.filter (fun (row : row) ->
    (all || status_is_material row)
    && (classes = [] || List.mem row.resource_class classes)
    && wanted_status row.status)
;;

let filter_inventory ~all ~classes ~statuses inventory =
  let rows = filter_rows ~all ~classes ~statuses inventory.rows in
  { inventory with rows; summary = summary_of_rows rows }
;;

let next_action inventory =
  match inventory.verdict with
  | Reconciled -> None
  | Attention_required ->
    if
      List.exists
        (fun row ->
           match row.recovery with
           | Recoverable _ -> true
           | _ -> false)
        inventory.rows
    then
      Some
        (Printf.sprintf
           "sol target reconcile %s --dry-run --explain"
           inventory.target.name)
    else Some "sol target reconcile --dry-run --explain, or investigate the named rows"
  | Incomplete ->
    Some
      "verification is incomplete; inspect coverage.unobserved_classes, then add or run \
       the missing observation"
  | Unknown_verdict ->
    Some
      "inventory is incomplete; inspect unknowns and restore the unreadable state or \
       observation"
  | Unverified -> Some "run without --state-only to establish presence or absence"
;;

let render ?(all = false) ?(classes = []) ?(statuses = []) ~explain inventory =
  let buffer = Buffer.create 4096 in
  let line format = Printf.ksprintf (Buffer.add_string buffer) format in
  line "Target    %s\n" inventory.target.name;
  line "Verdict   %s\n" (verdict_to_string inventory.verdict);
  line
    "Coverage  inventory: %s; verification: %s (%d required, %d observed, %d \
     by-contract, %d unobserved, %d failed)\n"
    (if inventory.coverage.inventory_complete then "complete" else "incomplete")
    (if inventory.coverage.verification_complete then "complete" else "incomplete")
    (List.length inventory.coverage.required_classes)
    (List.length inventory.coverage.observed_classes)
    (List.length inventory.coverage.by_contract_classes)
    (List.length inventory.coverage.unobserved_classes)
    (List.length inventory.coverage.failed_classes);
  List.iter
    (fun root ->
       let state = state_to_string root.state in
       let count = List.length (Sol_cli_cloud_destroy.resources root.state) in
       line
         "Root      %-14s %-12s %d resource(s)%s\n"
         (root_role_to_string root.role)
         state
         count
         (if root.errored_state then " (errored.tfstate present)" else "");
       line
         "          last operation: %s\n"
         (Sol_cli_supervised.status_to_string root.last_operation))
    inventory.roots;
  let rows = filter_rows ~all ~classes ~statuses inventory.rows in
  line "\n%-14s %-12s %-26s %-24s %s\n" "LAYER" "STATUS" "CLASS" "NAME" "ACTION";
  List.iter
    (fun (row : row) ->
       line
         "%-14s %-12s %-26s %-24s %s\n"
         (layer_to_string row.layer)
         (status_to_string row.status)
         row.resource_class
         (Option.value row.name ~default:"—")
         (action_to_string row.action);
       if explain
       then (
         (match row.address with
          | Some address -> line "          address: %s\n" address
          | None -> ());
         (match row.identity with
          | Some identity -> line "          identity: %s\n" identity
          | None -> ());
         (match row.import_identity with
          | Some identity -> line "          import: %s\n" identity
          | None -> ());
         line
           "          observation: %s; recovery: %s\n"
           (observation_to_string row.observation)
           (recovery_to_string row.recovery);
         (match row.reason with
          | Some reason -> line "          reason: %s\n" reason
          | None -> ());
         match row.checked_with with
         | Some checked -> line "          checked with: %s\n" checked
         | None -> ()))
    rows;
  line
    "\nSummary   %d owned · %d recorded · %d missing · %d unrecorded · %d unknown\n"
    inventory.summary.owned
    inventory.summary.recorded
    inventory.summary.missing
    inventory.summary.unrecorded
    inventory.summary.unknown;
  (match next_action inventory with
   | Some action -> line "Next      %s\n" action
   | None -> ());
  Buffer.contents buffer
;;

let row_to_json row =
  let recovery =
    match row.recovery with
    | Not_applicable -> `Assoc [ "disposition", `String "not_applicable" ]
    | Recoverable { address; import_identity } ->
      `Assoc
        [ "disposition", `String "recoverable"
        ; "address", `String address
        ; "import_identity", `String import_identity
        ]
    | Unrecoverable reason ->
      `Assoc [ "disposition", `String "unrecoverable"; "reason", `String reason ]
    | Unmapped reason ->
      `Assoc [ "disposition", `String "unmapped"; "reason", `String reason ]
  in
  let status = `String (status_to_string row.status) in
  let status_reason =
    match row.status with
    | Uid_mismatch reason | Unknown reason -> `String reason
    | Owned | Recorded | Missing | Unrecorded | External | In_cluster | Synthetic | Absent
      -> `Null
  in
  let provider =
    match row.observation with
    | Observed ->
      (match row.status with
       | Missing -> "absent"
       | _ -> "present")
    | Unobserved -> "not_checked"
    | By_contract -> "not_checked"
    | Failed _ -> "unobservable"
  in
  let record =
    match row.status with
    | Unrecorded | Absent -> "not_recorded"
    | Recorded | External | In_cluster | Synthetic -> "present"
    | Owned | Missing | Unknown _ | Uid_mismatch _ ->
      if Option.is_some row.address then "present" else "not_recorded"
  in
  `Assoc
    [ "layer", `String (layer_to_string row.layer)
    ; "root", `String row.root
    ; ( "address"
      , match row.address with
        | Some value -> `String value
        | None -> `Null )
    ; "resource_class", `String row.resource_class
    ; ( "name"
      , match row.name with
        | Some value -> `String value
        | None -> `Null )
    ; ( "identity"
      , match row.identity with
        | Some value -> `String value
        | None -> `Null )
    ; ( "observed_as"
      , match row.observed_as with
        | Some value -> `String value
        | None -> `Null )
    ; ( "ownership_kind"
      , match row.ownership_kind with
        | Some value -> `String value
        | None -> `Null )
    ; ( "import_identity"
      , match row.import_identity with
        | Some value -> `String value
        | None -> `Null )
    ; "status", status
    ; "status_reason", status_reason
    ; "recovery", recovery
    ; "observation", `String (observation_to_string row.observation)
    ; "record", `String record
    ; "provider", `String provider
    ; "action", `String (action_to_string row.action)
    ; ( "reason"
      , match row.reason with
        | Some value -> `String value
        | None -> `Null )
    ; ( "checked_with"
      , match row.checked_with with
        | Some value -> `String value
        | None -> `Null )
    ; ( "lifetime"
      , `String
          (match row.lifetime with
           | `Installation -> "installation"
           | `Target -> "target"
           | `Workload -> "workload") )
    ; ( "deletion_protection"
      , match row.deletion_protection with
        | Some value -> `Bool value
        | None -> `Null )
    ]
;;

let to_json inventory =
  let roots =
    inventory.roots
    |> List.map (fun root ->
      `Assoc
        [ "layer", `String (layer_to_string root.layer)
        ; "root", `String (root_role_to_string root.role)
        ; "durable", `Bool root.durable
        ; "state", `String (state_to_string root.state)
        ; "recorded", `Int (List.length (Sol_cli_cloud_destroy.resources root.state))
        ; "last_operation", supervised_status_to_json root.last_operation
        ; "errored_state", `Bool root.errored_state
        ])
  in
  let coverage =
    `Assoc
      [ ( "inventory"
        , `Assoc
            [ "complete", `Bool inventory.coverage.inventory_complete
            ; ( "roots"
              , `List
                  (List.map
                     (fun root -> `String (root_role_to_string root.role))
                     inventory.roots) )
            ] )
      ; ( "verification"
        , `Assoc
            [ "complete", `Bool inventory.coverage.verification_complete
            ; ( "required_classes"
              , `List
                  (List.map
                     (fun value -> `String value)
                     inventory.coverage.required_classes) )
            ; ( "observed_classes"
              , `List
                  (List.map
                     (fun value -> `String value)
                     inventory.coverage.observed_classes) )
            ; ( "by_contract_classes"
              , `List
                  (List.map
                     (fun value -> `String value)
                     inventory.coverage.by_contract_classes) )
            ; ( "unobserved_classes"
              , `List
                  (List.map
                     (fun value -> `String value)
                     inventory.coverage.unobserved_classes) )
            ; ( "failed_classes"
              , `List
                  (List.map
                     (fun value -> `String value)
                     inventory.coverage.failed_classes) )
            ; ( "recorded_unverified"
              , `List
                  (List.map
                     (fun value -> `String value)
                     inventory.coverage.recorded_unverified) )
            ] )
      ]
  in
  let summary =
    `Assoc
      [ "owned", `Int inventory.summary.owned
      ; "recorded", `Int inventory.summary.recorded
      ; "missing", `Int inventory.summary.missing
      ; "unrecorded", `Int inventory.summary.unrecorded
      ; "external", `Int inventory.summary.external_resources
      ; "in_cluster", `Int inventory.summary.in_cluster
      ; "synthetic", `Int inventory.summary.synthetic
      ; "uid_mismatch", `Int inventory.summary.uid_mismatch
      ; "unknown", `Int inventory.summary.unknown
      ]
  in
  `Assoc
    [ "schema", `Int 1
    ; "target", `String inventory.target.name
    ; "verdict", `String (verdict_to_string inventory.verdict)
    ; "coverage", coverage
    ; "roots", `List roots
    ; "resources", `List (List.map row_to_json inventory.rows)
    ; "summary", summary
    ; "unknowns", `List (List.map (fun value -> `String value) inventory.unknowns)
    ]
;;
