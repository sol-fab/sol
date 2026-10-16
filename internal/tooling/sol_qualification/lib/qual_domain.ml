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

type owner =
  | Legacy_matrix of string
  | Typed_family of string

let sha256 text = Digestif.SHA256.(to_hex (digest_string text))
let ( let* ) = Result.bind
let error text = Error text
let nonempty s = String.trim s <> ""
let unique xs = List.length xs = List.length (List.sort_uniq String.compare xs)

let rec normalize = function
  | `Assoc fields ->
    if not (unique (List.map fst fields))
    then error "duplicate JSON field"
    else (
      let rec loop = function
        | [] -> Ok []
        | (k, v) :: rest ->
          let* v = normalize v in
          let* rest = loop rest in
          Ok ((k, v) :: rest)
      in
      let* fields = loop fields in
      Ok (`Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) fields)))
  | `List xs ->
    let rec loop = function
      | [] -> Ok []
      | x :: xs ->
        let* x = normalize x in
        let* xs = loop xs in
        Ok (x :: xs)
    in
    let* xs = loop xs in
    Ok (`List xs)
  | (`Null | `Bool _ | `String _ | `Int _) as v -> Ok v
  | _ -> error "unsupported canonical JSON value"
;;

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
  }

type database =
  { id : string
  ; ca_configmap : string
  }

type workload =
  { id : string
  ; namespace : string
  ; name : string
  ; database : string option
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

let run_json (r : run) =
  `Assoc
    [ "origin", `String "MECHANISM"
    ; "attempt", `String r.attempt
    ; "assessment", `String r.assessment
    ; "candidate", `String r.candidate
    ; "specimen", `String r.specimen
    ; "contract", `String r.contract_digest
    ; ( "provider"
      , `String
          (match r.scenario with
           | Aws -> "aws"
           | Gcp -> "gcp"
           | Local -> "local") )
    ]
;;

let same_run a b = a = b
let consumers (s : selection) = List.map (fun (w : workload) -> w.id) s.selected
let exclusions (s : selection) = s.excluded

let select run intent =
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
      required @ List.map (fun (d : database) -> make Migration d.id None d) databases
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
let instance_kind i = i.kind

let obligations_json o =
  `Assoc
    [ "run", run_json o.run
    ; "selection", `String o.selection_digest
    ; "required", `List (List.map (fun i -> `String i.key) o.required)
    ; ( "excluded"
      , `List
          (List.map
             (fun (k, reason) ->
                `Assoc [ "subject", `String k; "reason", `String reason ])
             o.excluded) )
    ]
;;

type ca_requirement = instance
type dml_requirement = instance
type no_master_requirement = instance
type tls_requirement = instance
type migration_requirement = instance

type request =
  | Ca_delivery of ca_requirement
  | Dml_delivery of dml_requirement
  | No_master_copy of no_master_requirement
  | Tls_connectivity of tls_requirement
  | Migration_input of migration_requirement

let plan i =
  match i.kind with
  | Ca -> Ca_delivery i
  | Dml -> Dml_delivery i
  | No_master -> No_master_copy i
  | Tls -> Tls_connectivity i
  | Migration -> Migration_input i
;;

let requested = function
  | Ca_delivery i
  | Dml_delivery i
  | No_master_copy i
  | Tls_connectivity i
  | Migration_input i -> i
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
  if List.for_all (fun r -> same_run o.run (requested r).run) requests
  then Ok ()
  else error "plan run mismatch"
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

type ca_facts =
  { namespace : string
  ; workload : string
  ; configmap : string
  ; key : string
  ; mount_path : string
  ; nonempty : bool
  }

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
  ; keys : string list
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

type 'a state =
  | Present of 'a
  | Absent
  | Unreadable of string

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

let evaluate = function
  | Ca_checked (i, o) ->
    evaluate_observation i o (fun (f : ca_facts) ->
      established
        (workload_matches i f.namespace f.workload)
        (List.mem "ca" i.run.capabilities
         && f.configmap = i.database.ca_configmap
         && f.key = i.run.ca_key
         && f.mount_path = i.run.ca_path
         && f.nonempty))
  | Dml_checked (i, o) ->
    evaluate_observation i o (fun (f : dml_facts) ->
      established
        (workload_matches i f.namespace f.workload)
        (List.mem "dml" i.run.capabilities
         && f.credential_class = i.run.dml_class
         && f.key = i.run.credential_key
         && f.nonempty))
  | No_master_checked (i, o) ->
    evaluate_observation i o (fun (f : unit_secret_facts) ->
      established
        (workload_matches i f.namespace f.workload)
        (not (List.mem i.run.credential_key f.keys)))
  | Tls_checked (i, o) ->
    evaluate_observation i o (fun (f : tls_facts) ->
      established
        (workload_matches i f.namespace f.workload)
        (List.mem "tls" i.run.capabilities && f.verified))
  | Migration_checked (i, o) ->
    evaluate_observation i o (fun (f : migration_facts) ->
      established (f.database = i.database.id) (f.key = i.run.credential_key && f.nonempty))
;;

let reconcile_outcomes o verdicts =
  let* () =
    reconcile_keys
      ~expected:(List.map instance_key o.required)
      ~actual:(List.map (fun v -> v.instance.key) verdicts)
  in
  if List.for_all (fun v -> same_run o.run v.instance.run) verdicts
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
    ; "run", run_json v.instance.run
    ; "decision", `String status
    ; "detail", `String detail
    ; "evidence", `List (List.map (fun s -> `String s) v.evidence)
    ]
;;

module Fixture = struct
  let bind ~scenario ~attempt ~assessment ~candidate_revision ~specimen ~contract =
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
        Ok { id; ca_configmap })
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
        Ok { id; namespace; name; database })
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
