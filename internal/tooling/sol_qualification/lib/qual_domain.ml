type scenario =
  | Aws
  | Gcp
  | Local

type kind =
  | Ca
  | Dml
  | No_master
  | Tls
  | Migration
  | Migration_ca

type owner =
  | Legacy_matrix of string
  | Typed_family of string

let sha256 text = Digestif.SHA256.(to_hex (digest_string text))

open Result.Syntax

let error text = Error text
let nonempty s = String.trim s <> ""
let unique xs = List.length xs = List.length (List.sort_uniq String.compare xs)

(* One canonical wire grammar, shared with the product declaration owner. *)
let normalize = Sol_cli_database_contract_data.canonical

let canonical_json json =
  let* json = normalize json in
  Ok (Yojson.Safe.to_string json)
;;

let field k = function
  | `Assoc xs -> List.assoc_opt k xs
  | _ -> None
;;

let str k json =
  match field k json with
  | Some (`String s) when nonempty s -> Ok s
  | _ -> error ("missing string: " ^ k)
;;

let strings = function
  | `List xs ->
    let rec loop = function
      | [] -> Ok []
      | `String s :: xs when nonempty s ->
        let* xs = loop xs in
        Ok (s :: xs)
      | _ -> error "expected nonempty string list"
    in
    loop xs
  | _ -> error "expected string list"
;;

let hex n s =
  String.length s = n
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s
;;

type kube_target =
  { principal : string
  ; cluster : string
  ; endpoint : string
  }

type read_context =
  { target : kube_target
  ; verified_at : int
  ; started_at : int
  ; finished_at : int
  ; expires_at : int option
  }

type 'a state =
  | Present of 'a
  | Absent
  | Unreadable of string

type 'a kube_read =
  { requirement : string
  ; subject : string
  ; context : read_context
  ; state : 'a state
  }

type ca_volume =
  { volume_name : string
  ; source_configmap : string option
  ; items : (string * string) list option
  }

type ca_mount =
  { volume_name : string
  ; path : string
  ; sub_path : string option
  ; sub_path_expr : string option
  }

type ca_container =
  { container_name : string
  ; mounts : ca_mount list
  }

type pod_template =
  { namespace : string
  ; name : string
  ; uid : string
  ; resource_version : string
  ; volumes : ca_volume list
  ; containers : ca_container list
  }

type ca_configmap =
  { namespace : string
  ; name : string
  ; uid : string
  ; resource_version : string
  ; entries : (string * bool) list
  }

type ca_facts =
  { deployment : pod_template kube_read
  ; configmap : ca_configmap kube_read
  }

type job_identity =
  { namespace : string
  ; name : string
  ; uid : string
  }

type migration_ca_facts =
  { execution : job_identity kube_read
  ; job : pod_template kube_read
  ; configmap : ca_configmap kube_read
  }

type run =
  { attempt : string
  ; assessment : string
  ; candidate : string
  ; specimen : string
  ; scenario : scenario
  ; contract_digest : string
  ; ca_key : string
  ; ca_path : string
  ; credential_key : string
  ; dml_class : string
  ; capabilities : string list
  ; kubernetes : kube_target
  ; candidate_binding : Yojson.Safe.t option
  }

type secret_address =
  { namespace : string
  ; name : string
  }

type migration_context =
  { namespace : string
  ; container : string
  ; configmap : string
  }

type database =
  { id : string
  ; ca_configmap : string
  ; administrative_secret : secret_address
  ; migration : migration_context
  }

type workload =
  { resource : string
  ; id : string
  ; namespace : string
  ; name : string
  ; database : string option
  ; consuming_containers : string list
  }

type intent =
  { databases : database list
  ; workloads : workload list
  ; intent_digest : string
  }

type selection =
  { run : run
  ; intent : intent
  ; selected : workload list
  ; excluded : (string * string) list
  }

type instance =
  { run : run
  ; kind : kind
  ; subject : string
  ; workload : workload option
  ; database : database
  ; key : string
  }

type obligations =
  { run : run
  ; required : instance list
  ; excluded : (string * string) list
  ; selection_digest : string
  }

let kube_target_json (t : kube_target) =
  `Assoc
    [ "principal", `String t.principal
    ; "cluster", `String t.cluster
    ; "endpoint", `String t.endpoint
    ]
;;

let run_json (r : run) =
  `Assoc
    [ "origin", `String "MECHANISM"
    ; "policy", `String "fixture-database/v2"
    ; ( "candidate_binding"
      , match r.candidate_binding with
        | None -> `Null
        | Some b -> b )
    ; "attempt", `String r.attempt
    ; "assessment", `String r.assessment
    ; "candidate", `String r.candidate
    ; "specimen", `String r.specimen
    ; "contract", `String r.contract_digest
    ; "kubernetes", kube_target_json r.kubernetes
    ; ( "provider"
      , `String
          (match r.scenario with
           | Aws -> "aws"
           | Gcp -> "gcp"
           | Local -> "local") )
    ]
;;

let read_context_json (c : read_context) =
  `Assoc
    [ "target", kube_target_json c.target
    ; "verified_at", `Int c.verified_at
    ; "started_at", `Int c.started_at
    ; "finished_at", `Int c.finished_at
    ; ( "expires_at"
      , match c.expires_at with
        | None -> `Null
        | Some n -> `Int n )
    ]
;;

let read_context_of_json json =
  let integer key json =
    match field key json with
    | Some (`Int n) -> Ok n
    | _ -> error ("missing integer: " ^ key)
  in
  let* target =
    match field "target" json with
    | Some t -> Ok t
    | None -> error "missing target"
  in
  let* principal = str "principal" target in
  let* cluster = str "cluster" target in
  let* endpoint = str "endpoint" target in
  let* verified_at = integer "verified_at" json in
  let* started_at = integer "started_at" json in
  let* finished_at = integer "finished_at" json in
  let* expires_at =
    match field "expires_at" json with
    | None | Some `Null -> Ok None
    | Some (`Int n) -> Ok (Some n)
    | _ -> error "invalid expiry"
  in
  Ok
    { target = { principal; cluster; endpoint }
    ; verified_at
    ; started_at
    ; finished_at
    ; expires_at
    }
;;

let same_run a b = a = b
let consumers (s : selection) = List.map (fun (w : workload) -> w.id) s.selected
let exclusions (s : selection) = s.excluded

let select run intent =
  let* () =
    match run.candidate_binding with
    | Some _ when run.specimen <> intent.intent_digest ->
      error "intent belongs to another candidate specimen"
    | _ -> Ok ()
  in
  let selected, excluded =
    List.partition (fun (w : workload) -> w.database <> None) intent.workloads
  in
  if selected = []
  then error "database scenario has no consumers"
  else
    Ok
      { run
      ; intent
      ; selected
      ; excluded =
          List.map
            (fun (w : workload) -> w.id, "no declared database dependency")
            excluded
      }
;;

let kind_name = function
  | Ca -> "ca"
  | Dml -> "dml"
  | No_master -> "no-master"
  | Tls -> "tls"
  | Migration -> "migration"
  | Migration_ca -> "migration-ca"
;;

let scenario_name = function
  | Aws -> "aws"
  | Gcp -> "gcp"
  | Local -> "local"
;;

(* This is the sole experimental policy catalog. Capabilities never determine
   applicability. Local plaintext is an explicit scenario-policy exclusion. *)
let per_consumer = [ Ca; Dml; No_master; Tls ]

let bind_obligations run scenario (selection : selection) =
  if (not (same_run run selection.run)) || run.scenario <> scenario
  then error "selection/provider belongs to another run"
  else (
    let prefix = scenario_name scenario ^ "/" ^ run.assessment ^ "/database/" in
    let make kind subject workload database =
      { run
      ; kind
      ; subject
      ; workload
      ; database
      ; key = prefix ^ kind_name kind ^ "/" ^ subject
      }
    in
    let required =
      List.concat_map
        (fun (w : workload) ->
           match w.database with
           | None -> [] (* partitioned out by select *)
           | Some id ->
             let database =
               List.find (fun (d : database) -> d.id = id) selection.intent.databases
             in
             List.filter_map
               (fun kind ->
                  if scenario = Local && kind = Tls
                  then None
                  else Some (make kind w.id (Some w) database))
               per_consumer)
        selection.selected
    in
    let databases =
      List.filter
        (fun (d : database) ->
           List.exists (fun (w : workload) -> w.database = Some d.id) selection.selected)
        selection.intent.databases
    in
    let required =
      required
      @ List.concat_map
          (fun (d : database) ->
             [ make Migration d.id None d; make Migration_ca d.id None d ])
          databases
    in
    let excluded =
      selection.excluded
      @
      if scenario = Local
      then
        List.map
          (fun (w : workload) ->
             ( prefix ^ "tls/" ^ w.id
             , "local scenario deliberately uses plaintext; no cloud TLS claim" ))
          selection.selected
      else []
    in
    Ok { run; required; excluded; selection_digest = selection.intent.intent_digest })
;;

let instances o = o.required
let applicability (o : obligations) = o.excluded
let instance_key i = i.key
let instance_run (i : instance) = i.run
let instance_kind i = i.kind

(* Fixed-shape projection of typed fields: no arbitrary JSON or naming inference.
   Persist this identity so durable coverage cannot collapse back to key equality. *)
let instance_identity (i : instance) =
  let address (a : secret_address) =
    `Assoc [ "namespace", `String a.namespace; "name", `String a.name ]
  in
  sha256
    (Yojson.Safe.to_string
       (`Assoc
           [ "run", run_json i.run
           ; "kind", `String (kind_name i.kind)
           ; "subject", `String i.subject
           ; "key", `String i.key
           ; ( "database"
             , `Assoc
                 [ "id", `String i.database.id
                 ; "ca_configmap", `String i.database.ca_configmap
                 ; "administrative_secret", address i.database.administrative_secret
                 ; ( "migration"
                   , `Assoc
                       [ "namespace", `String i.database.migration.namespace
                       ; "container", `String i.database.migration.container
                       ; "configmap", `String i.database.migration.configmap
                       ] )
                 ] )
           ; ( "workload"
             , match i.workload with
               | None -> `Null
               | Some w ->
                 `Assoc
                   [ "id", `String w.id
                   ; "resource", `String w.resource
                   ; "namespace", `String w.namespace
                   ; "name", `String w.name
                   ; ( "consuming_containers"
                     , `List (List.map (fun s -> `String s) w.consuming_containers) )
                   ; ( "database"
                     , match w.database with
                       | None -> `Null
                       | Some id -> `String id )
                   ] )
           ]))
;;

let obligations_json o =
  `Assoc
    [ "run", run_json o.run
    ; "selection", `String o.selection_digest
    ; "required", `List (List.map (fun i -> `String i.key) o.required)
    ; "requirements", `List (List.map (fun i -> `String (instance_identity i)) o.required)
    ; ( "excluded"
      , `List
          (List.map
             (fun (k, reason) ->
                `Assoc [ "subject", `String k; "reason", `String reason ])
             o.excluded) )
    ]
;;

type ca_requirement = Ca_requirement of instance
type dml_requirement = Dml_requirement of instance
type no_master_requirement = No_master_requirement of instance
type tls_requirement = Tls_requirement of instance
type migration_requirement = Migration_requirement of instance
type migration_ca_requirement = Migration_ca_requirement of instance

type request =
  | Ca_delivery of ca_requirement
  | Dml_delivery of dml_requirement
  | No_master_copy of no_master_requirement
  | Tls_connectivity of tls_requirement
  | Migration_input of migration_requirement
  | Migration_ca_delivery of migration_ca_requirement

type ca_binding =
  { instance : instance
  ; run : run
  ; subject : string
  ; namespace : string
  ; workload : string
  ; consuming_containers : string list
  ; configmap : string
  ; ca_key : string
  ; ca_path : string
  ; target : kube_target
  }

type migration_ca_binding =
  { instance : instance
  ; run : run
  ; subject : string
  ; namespace : string
  ; container : string
  ; configmap : string
  ; ca_key : string
  ; ca_path : string
  ; target : kube_target
  }

let ca_binding (Ca_requirement i) =
  (* Only the catalog can construct a CA requirement, always for a consumer. *)
  match i.workload with
  | None -> invalid_arg "CA requirement has no workload"
  | Some w ->
    { instance = i
    ; run = i.run
    ; subject = i.subject
    ; namespace = w.namespace
    ; workload = w.name
    ; consuming_containers = w.consuming_containers
    ; configmap = i.database.ca_configmap
    ; ca_key = i.run.ca_key
    ; ca_path = i.run.ca_path
    ; target = i.run.kubernetes
    }
;;

let migration_ca_binding (Migration_ca_requirement i) =
  let m = i.database.migration in
  { instance = i
  ; run = i.run
  ; subject = i.subject
  ; namespace = m.namespace
  ; container = m.container
  ; configmap = m.configmap
  ; ca_key = i.run.ca_key
  ; ca_path = i.run.ca_path
  ; target = i.run.kubernetes
  }
;;

let plan i =
  match i.kind with
  | Ca -> Ca_delivery (Ca_requirement i)
  | Dml -> Dml_delivery (Dml_requirement i)
  | No_master -> No_master_copy (No_master_requirement i)
  | Tls -> Tls_connectivity (Tls_requirement i)
  | Migration -> Migration_input (Migration_requirement i)
  | Migration_ca -> Migration_ca_delivery (Migration_ca_requirement i)
;;

let requested = function
  | Ca_delivery (Ca_requirement i)
  | Dml_delivery (Dml_requirement i)
  | No_master_copy (No_master_requirement i)
  | Tls_connectivity (Tls_requirement i)
  | Migration_input (Migration_requirement i)
  | Migration_ca_delivery (Migration_ca_requirement i) -> i
;;

let reconcile_keys ~expected ~actual =
  if not (unique expected)
  then error "duplicate expected instance"
  else if not (unique actual)
  then error "duplicate actual instance"
  else if List.sort String.compare expected <> List.sort String.compare actual
  then error "missing or unexpected instance"
  else Ok ()
;;

let reconcile_plan o requests =
  let* () =
    reconcile_keys
      ~expected:(List.map instance_key o.required)
      ~actual:(List.map (fun r -> (requested r).key) requests)
  in
  let kind = function
    | Ca_delivery _ -> Ca
    | Dml_delivery _ -> Dml
    | No_master_copy _ -> No_master
    | Tls_connectivity _ -> Tls
    | Migration_input _ -> Migration
    | Migration_ca_delivery _ -> Migration_ca
  in
  if
    List.for_all
      (fun r ->
         let actual = requested r in
         kind r = actual.kind
         && List.exists (fun expected -> expected = actual) o.required)
      requests
  then Ok ()
  else error "plan requirement semantics mismatch"
;;

let check_ownership ~claims ~assignments =
  let* () = reconcile_keys ~expected:claims ~actual:(List.map fst assignments) in
  if
    List.for_all
      (fun (_, owner) ->
         match owner with
         | Legacy_matrix s | Typed_family s -> nonempty s)
      assignments
  then Ok ()
  else error "empty policy owner"
;;

type dml_facts =
  { namespace : string
  ; workload : string
  ; credential_class : string
  ; key : string
  ; nonempty : bool
  }

type unit_secret_facts =
  { namespace : string
  ; workload : string
  ; references : secret_address list
  }

type tls_facts =
  { namespace : string
  ; workload : string
  ; verified : bool
  }

type migration_facts =
  { database : string
  ; key : string
  ; nonempty : bool
  }

type 'a observation =
  { run : run
  ; subject : string
  ; evidence : string list
  ; state : 'a state
  }

type recorded_check =
  | Ca_checked of ca_requirement * ca_facts observation
  | Dml_checked of dml_requirement * dml_facts observation
  | No_master_checked of no_master_requirement * unit_secret_facts observation
  | Tls_checked of tls_requirement * tls_facts observation
  | Migration_checked of migration_requirement * migration_facts observation
  | Migration_ca_checked of migration_ca_requirement * migration_ca_facts observation

type decision =
  | Pass
  | Fail of string
  | Unknown of string
  | Not_run of string

type verdict =
  { instance : instance
  ; decision : decision
  ; evidence : string list
  }

let evaluate_observation (i : instance) o predicate =
  let decision =
    if (not (same_run i.run o.run)) || i.subject <> o.subject
    then Unknown "receipt run/contract/assessment/subject mismatch"
    else (
      match o.state with
      | Absent -> Fail "required object positively absent"
      | Unreadable reason -> Unknown reason
      | Present facts -> predicate facts)
  in
  { instance = i; decision; evidence = o.evidence }
;;

let workload_matches (i : instance) namespace name =
  match i.workload with
  | Some w -> namespace = w.namespace && name = w.name
  | None -> false
;;

let established matches good =
  if not matches
  then Unknown "object identity mismatch"
  else if good
  then Pass
  else Fail "declared delivery invariant falsified"
;;

let canonical_path ~absolute path =
  let pieces = String.split_on_char '/' path in
  let parts =
    if absolute
    then (
      match pieces with
      | "" :: rest -> rest
      | _ -> [])
    else pieces
  in
  parts <> []
  && List.for_all (fun p -> p <> "" && p <> "." && p <> "..") parts
  && ((not absolute) || String.starts_with ~prefix:"/" path)
  && (absolute || not (String.starts_with ~prefix:"/" path))
;;

let context_matches target (c : read_context) =
  c.target = target
  && c.verified_at >= 0
  && c.started_at >= c.verified_at
  && c.finished_at >= c.started_at
  && c.finished_at - c.verified_at <= 300
  &&
  match c.expires_at with
  | None -> true
  | Some expires -> c.finished_at <= expires
;;

let contains_path parent path =
  parent = path || parent = "/" || String.starts_with ~prefix:(parent ^ "/") path
;;

let delivered_path (mount : ca_mount) relative =
  let join parent child = if parent = "/" then "/" ^ child else parent ^ "/" ^ child in
  match mount.sub_path with
  | None -> Some (join mount.path relative)
  | Some sub when sub = relative -> Some mount.path
  | Some sub when String.starts_with ~prefix:(sub ^ "/") relative ->
    Some
      (join
         mount.path
         (String.sub
            relative
            (String.length sub + 1)
            (String.length relative - String.length sub - 1)))
  | Some _ -> None
;;

let evaluate_ca_objects
      ~namespace
      ~name
      ~containers
      ~configmap_name
      (i : instance)
      ~(template : pod_template kube_read)
      ~(configmap : ca_configmap kube_read)
  =
  let reads_match =
    template.requirement = instance_identity i
    && configmap.requirement = instance_identity i
    && template.subject = i.subject
    && configmap.subject = i.subject
    && context_matches i.run.kubernetes template.context
    && context_matches i.run.kubernetes configmap.context
  in
  if not reads_match
  then Unknown "CA read requirement/identity/cluster/freshness mismatch"
  else (
    match template.state, configmap.state with
    | Unreadable message, _ | _, Unreadable message -> Unknown message
    | Absent, _ | _, Absent -> Fail "required Kubernetes object positively absent"
    | Present deployment, Present configmap ->
      if
        (deployment.namespace <> namespace || deployment.name <> name)
        || configmap.namespace <> deployment.namespace
        || configmap.name <> configmap_name
      then Unknown "CA object identity mismatch"
      else if
        (not (List.mem "ca" i.run.capabilities))
        || not (List.mem (i.run.ca_key, true) configmap.entries)
      then Fail "candidate-declared CA key missing or empty"
      else (
        let check_container name =
          match
            List.find_opt (fun c -> c.container_name = name) deployment.containers
          with
          | None -> Fail "declared consuming container missing"
          | Some container ->
            let covering =
              List.filter
                (fun (m : ca_mount) -> contains_path m.path i.run.ca_path)
                container.mounts
            in
            let covering =
              List.sort
                (fun (a : ca_mount) b ->
                   Int.compare (String.length b.path) (String.length a.path))
                covering
            in
            (match covering with
             | [] -> Fail "consuming container does not mount the declared CA location"
             | mount :: _ when mount.sub_path_expr <> None ->
               Unknown "dynamic subPathExpr cannot establish CA location"
             | mount :: _ ->
               (match
                  List.find_opt
                    (fun (v : ca_volume) -> v.volume_name = mount.volume_name)
                    deployment.volumes
                with
                | None -> Fail "CA mount references missing volume"
                | Some v when v.source_configmap <> Some configmap_name ->
                  Fail "CA mount references another volume source"
                | Some v ->
                  let path =
                    match v.items with
                    | None -> Some i.run.ca_key
                    | Some items -> List.assoc_opt i.run.ca_key items
                  in
                  (match path with
                   | Some relative when delivered_path mount relative = Some i.run.ca_path
                     -> Pass
                   | _ -> Fail "CA key projection or mount redirects the declared CA file")))
        in
        let results = List.map check_container containers in
        match
          List.find_opt
            (function
              | Unknown _ -> true
              | _ -> false)
            results
        with
        | Some unknown -> unknown
        | None ->
          (match List.find_opt (( <> ) Pass) results with
           | Some failure -> failure
           | None -> Pass)))
;;

let evaluate_ca (i : instance) (f : ca_facts) =
  match i.workload with
  | None -> Unknown "CA requirement has no declared consumer"
  | Some w ->
    evaluate_ca_objects
      ~namespace:w.namespace
      ~name:w.name
      ~containers:w.consuming_containers
      ~configmap_name:i.database.ca_configmap
      i
      ~template:f.deployment
      ~configmap:f.configmap
;;

let evaluate_migration_ca (i : instance) (f : migration_ca_facts) =
  let m = i.database.migration in
  if
    f.execution.requirement <> instance_identity i
    || f.execution.subject <> i.subject
    || (not (context_matches i.run.kubernetes f.execution.context))
    || f.execution.context.finished_at > f.job.context.started_at
    || f.execution.context.finished_at > f.configmap.context.started_at
  then Unknown "migration execution requirement/identity/context mismatch"
  else (
    match f.execution.state with
    | Unreadable message -> Unknown message
    | Absent -> Unknown "migration execution receipt unavailable"
    | Present execution ->
      if
        execution.namespace <> m.namespace
        || not (nonempty execution.name && nonempty execution.uid)
      then Unknown "migration execution identity mismatch"
      else (
        match f.job.state with
        | Present job when job.uid <> execution.uid ->
          Unknown "migration Job UID differs from execution receipt"
        | _ ->
          evaluate_ca_objects
            ~namespace:m.namespace
            ~name:execution.name
            ~containers:[ m.container ]
            ~configmap_name:m.configmap
            i
            ~template:f.job
            ~configmap:f.configmap))
;;

let evaluate = function
  | Ca_checked (Ca_requirement i, o) -> evaluate_observation i o (evaluate_ca i)
  | Migration_ca_checked (Migration_ca_requirement i, o) ->
    evaluate_observation i o (evaluate_migration_ca i)
  | Dml_checked (Dml_requirement i, o) ->
    evaluate_observation i o (fun (f : dml_facts) ->
      established
        (workload_matches i f.namespace f.workload)
        (List.mem "dml" i.run.capabilities
         && f.credential_class = i.run.dml_class
         && f.key = i.run.credential_key
         && f.nonempty))
  | No_master_checked (No_master_requirement i, o) ->
    evaluate_observation i o (fun (f : unit_secret_facts) ->
      established
        (workload_matches i f.namespace f.workload)
        (not (List.mem i.database.administrative_secret f.references)))
  | Tls_checked (Tls_requirement i, o) ->
    evaluate_observation i o (fun (f : tls_facts) ->
      established
        (workload_matches i f.namespace f.workload)
        (List.mem "tls" i.run.capabilities && f.verified))
  | Migration_checked (Migration_requirement i, o) ->
    evaluate_observation i o (fun (f : migration_facts) ->
      established (f.database = i.database.id) (f.key = i.run.credential_key && f.nonempty))
;;

let reconcile_outcomes o verdicts =
  let* () =
    reconcile_keys
      ~expected:(List.map instance_key o.required)
      ~actual:(List.map (fun v -> v.instance.key) verdicts)
  in
  if List.for_all (fun v -> List.mem v.instance o.required) verdicts
  then Ok ()
  else error "outcome run mismatch"
;;

let accept_mechanism o requests verdicts =
  let* () = reconcile_plan o requests in
  let* () = reconcile_outcomes o verdicts in
  if List.for_all (fun v -> v.decision = Pass) verdicts && verdicts <> []
  then Ok ()
  else error "required claim unestablished"
;;

let verdict_json v =
  let status, detail =
    match v.decision with
    | Pass -> "PASS", "established"
    | Fail s -> "FAIL", s
    | Unknown s -> "UNKNOWN", s
    | Not_run s -> "NOT_RUN", s
  in
  `Assoc
    [ "instance", `String v.instance.key
    ; "requirement", `String (instance_identity v.instance)
    ; "run", run_json v.instance.run
    ; "decision", `String status
    ; "detail", `String detail
    ; "evidence", `List (List.map (fun s -> `String s) v.evidence)
    ]
;;

module Fixture = struct
  let bind
        ~scenario
        ~attempt
        ~assessment
        ~candidate_revision
        ~specimen
        ~kubernetes
        ~contract
    =
    let* canonical = canonical_json contract in
    let* ca_key = str "ca_key" contract in
    let* ca_path = str "ca_path" contract in
    let* credential_key = str "credential_key" contract in
    let* dml_class = str "dml_class" contract in
    let* capabilities =
      match field "capabilities" contract with
      | Some x -> strings x
      | None -> error "missing capabilities"
    in
    if field "schema" contract <> Some (`Int 1)
    then error "unsupported fixture contract schema"
    else if
      (not (canonical_path ~absolute:true ca_path))
      || String.contains ca_key '/'
      || not
           (List.for_all
              nonempty
              [ kubernetes.principal; kubernetes.cluster; kubernetes.endpoint ])
    then error "invalid fixture CA path or Kubernetes target"
    else if
      (not (hex 40 candidate_revision))
      || not (List.for_all nonempty [ attempt; assessment; specimen ])
    then error "invalid fixture binding"
    else
      Ok
        { scenario
        ; attempt
        ; assessment
        ; candidate = candidate_revision
        ; specimen
        ; contract_digest = sha256 canonical
        ; ca_key
        ; ca_path
        ; credential_key
        ; dml_class
        ; capabilities
        ; kubernetes
        ; candidate_binding = None
        }
  ;;

  let intent json =
    let* canonical = canonical_json json in
    let parse_list name parse =
      match field name json with
      | Some (`List xs) ->
        let rec loop = function
          | [] -> Ok []
          | x :: xs ->
            let* x = parse x in
            let* xs = loop xs in
            Ok (x :: xs)
        in
        loop xs
      | _ -> error ("missing list: " ^ name)
    in
    let* databases =
      parse_list "databases" (fun j ->
        let* id = str "id" j in
        let* ca_configmap = str "ca_configmap" j in
        let* administrative_secret =
          match field "administrative_secret" j with
          | Some secret ->
            let* namespace = str "namespace" secret in
            let* name = str "name" secret in
            Ok { namespace; name }
          | None -> error "missing administrative secret binding"
        in
        let* migration =
          match field "migration" j with
          | Some m ->
            let* namespace = str "namespace" m in
            let* container = str "container" m in
            let* configmap = str "configmap" m in
            Ok { namespace; container; configmap }
          | None -> error "missing explicit migration execution context"
        in
        Ok { id; ca_configmap; administrative_secret; migration })
    in
    let* workloads =
      parse_list "workloads" (fun j ->
        let* id = str "id" j in
        let* namespace = str "namespace" j in
        let* name = str "name" j in
        let* database =
          match field "database" j with
          | Some `Null -> Ok None
          | Some (`String s) when nonempty s -> Ok (Some s)
          | _ -> error "database must be explicit string or null"
        in
        let* consuming_containers =
          match field "consuming_containers" j with
          | Some value -> strings value
          | None -> error "missing explicit consuming containers"
        in
        if
          (not (unique consuming_containers))
          || (database <> None && consuming_containers = [])
        then error "incomplete or duplicate consuming container selection"
        else
          Ok
            { resource = "deployment"
            ; id
            ; namespace
            ; name
            ; database
            ; consuming_containers
            })
    in
    if
      (not (unique (List.map (fun (d : database) -> d.id) databases)))
      || (not (unique (List.map (fun (w : workload) -> w.id) workloads)))
      || not
           (unique
              (List.map (fun (w : workload) -> w.namespace ^ "/" ^ w.name) workloads))
    then error "duplicate canonical subject"
    else if
      not
        (List.for_all
           (fun (w : workload) ->
              match w.database with
              | None -> true
              | Some id -> List.exists (fun (d : database) -> d.id = id) databases)
           workloads)
    then error "unresolved database dependency"
    else Ok { databases; workloads; intent_digest = sha256 canonical }
  ;;

  let observe run ~subject ~evidence state =
    if evidence = [] || (not (List.for_all (hex 64) evidence)) || not (nonempty subject)
    then error "missing/invalid fixture evidence reference"
    else Ok { run; subject; evidence; state }
  ;;

  let blocked instance ~evidence reason =
    if evidence = [] || (not (List.for_all (hex 64) evidence)) || not (nonempty reason)
    then error "missing blocker evidence"
    else Ok { instance; decision = Not_run reason; evidence }
  ;;
end

(* Adapt typed product declarations, never their naming rules. The deliberately
   narrow supported subset is checked before selection so unsupported promises
   cannot disappear from the qualification-owned obligation universe. *)
let bind_candidate ~scenario ~attempt ~assessment ~kubernetes verified =
  let module C = Sol_cli_database_contract_data in
  let* () =
    match scenario, Qual_candidate.provider verified with
    | Aws, Sol_cli_provider.Aws | Gcp, Sol_cli_provider.Gcp -> Ok ()
    | _ -> error "qualification scenario differs from the candidate target provider"
  in
  let d = Qual_candidate.definition verified in
  let s = Qual_candidate.specimen verified in
  let* () =
    if
      (not
         (List.for_all
            nonempty
            [ attempt
            ; assessment
            ; kubernetes.principal
            ; kubernetes.cluster
            ; kubernetes.endpoint
            ]))
      || (not (canonical_path ~absolute:true d.ca_file))
      || String.contains d.ca_key '/'
    then error "invalid candidate assessment or CA binding"
    else if d.volume_identity <> "internal_linkage"
    then error "unsupported CA volume identity contract"
    else Ok ()
  in
  let* db =
    match s.database with
    | Some db -> Ok db
    | None -> error "required database declaration is missing"
  in
  let* administrative_secret =
    match db.ownership, db.credential_authority, db.administrative_references with
    | "sol", Some _, [ a ] -> Ok { namespace = a.namespace; name = a.name }
    | _ ->
      error
        "unsupported database authority; required database claims remain unestablished"
  in
  let m = db.migration in
  let* migration_ca =
    match m.ca with
    | Some ca -> Ok ca
    | None -> error "required migration CA declaration is missing"
  in
  let matches_ca (ca : C.ca) = ca.key = d.ca_key && ca.file = d.ca_file in
  let* () =
    if
      m.context <> "database_migration"
      || m.resource <> "Job"
      || m.job_identity <> "requires_execution_receipt"
      || m.container <> d.migration_container
      || m.credential.namespace <> m.namespace
      || migration_ca.configmap.namespace <> m.namespace
      || not (matches_ca migration_ca)
    then error "unsupported or inconsistent migration execution declaration"
    else Ok ()
  in
  let* () =
    if
      s.workloads = []
      || (not (unique (List.map (fun (w : C.workload) -> w.subject) s.workloads)))
      || not
           (unique
              (List.map (fun (w : C.workload) -> w.namespace ^ "/" ^ w.name) s.workloads))
    then error "missing or duplicate workload identities"
    else Ok ()
  in
  let consumers = List.filter (fun (w : C.workload) -> w.database <> None) s.workloads in
  let* ca_configmap =
    match consumers with
    | { ca = Some ca; _ } :: _ -> Ok ca.configmap.name
    | _ -> error "required consumer CA declarations are missing"
  in
  let* workloads =
    Sol_cli_result.map_list
      (fun (w : C.workload) ->
         let* () =
           if not (unique w.declared_uses && unique w.consuming_containers)
           then error "duplicate dependency or container identity"
           else (
             match w.database, w.ca, w.credential with
             | None, None, None
               when w.consuming_containers = []
                    && not (List.mem db.resource w.declared_uses) -> Ok ()
             | Some id, Some ca, Some credential
               when id = db.resource
                    && List.mem id w.declared_uses
                    && w.resource = "deployment"
                    && w.consuming_containers <> []
                    && credential.namespace = w.namespace
                    && (not
                          (List.exists
                             (fun (a : C.address) -> a = credential)
                             db.administrative_references))
                    && credential <> m.credential
                    && ca.configmap.namespace = w.namespace
                    && ca.configmap.name = ca_configmap
                    && matches_ca ca -> Ok ()
             | _ ->
               error
                 "unsupported or incomplete workload/database/container delivery \
                  declaration")
         in
         Ok
           { resource = w.resource
           ; id = w.subject
           ; namespace = w.namespace
           ; name = w.name
           ; database = w.database
           ; consuming_containers = w.consuming_containers
           })
      s.workloads
  in
  let database =
    { id = db.resource
    ; ca_configmap
    ; administrative_secret
    ; migration =
        { namespace = m.namespace
        ; container = m.container
        ; configmap = migration_ca.configmap.name
        }
    }
  in
  let e = Qual_candidate.expected verified in
  (* Digests bind the entire declarations, including credential/migration addresses.
     Store only nonsecret provenance; the complete typed subject set is retained in intent. *)
  let receipt =
    `Assoc
      [ "revision", `String e.revision
      ; "bundle_digest", `String e.bundle_digest
      ; "definition_digest", `String e.definition_digest
      ; "specimen_digest", `String e.specimen_digest
      ; "target", `String e.target
      ; "requested_target", `String e.requested_target
      ; "workspace", `String s.workspace
      ]
  in
  let run =
    { attempt
    ; assessment
    ; candidate = d.revision
    ; specimen = s.digest
    ; scenario
    ; contract_digest = d.digest
    ; ca_key = d.ca_key
    ; ca_path = d.ca_file
    ; credential_key = d.credential_key
    ; dml_class = d.dml_class
    ; (* This adapter implements only candidate-bound CA evaluation. Unsupported
        DML/TLS facts cannot PASS, but their policy obligations remain required. *)
      capabilities = [ "ca" ]
    ; kubernetes
    ; candidate_binding = Some receipt
    }
  in
  Ok (run, { databases = [ database ]; workloads; intent_digest = s.digest })
;;

let expected_workloads (intent : intent) =
  List.map
    (fun (w : workload) ->
       `Assoc
         [ "subject", `String w.id
         ; "resource", `String w.resource
         ; "namespace", `String w.namespace
         ; "name", `String w.name
         ; ( "database"
           , match w.database with
             | None -> `Null
             | Some v -> `String v )
         ; ( "consuming_containers"
           , `List (List.map (fun x -> `String x) w.consuming_containers) )
         ])
    intent.workloads
;;
