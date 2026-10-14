type workload = Sol_cli_release_id.workload
type recorded_workload = Sol_cli_release_id.recorded_workload
type contract_fact = Sol_cli_release_id.contract_fact

type apply_mode =
  | Direct
  | Gitops

let apply_mode_to_string = function
  | Direct -> "direct"
  | Gitops -> "gitops"
;;

let apply_mode_of_string = function
  | "direct" -> Ok Direct
  | "gitops" -> Ok Gitops
  | s ->
    Error
      (Printf.sprintf
         "%S is not a valid apply_mode (expected \"direct\" or \"gitops\")"
         s)
;;

type t =
  { release_id : string
  ; workspace : string
  ; environment : string option
  ; workloads : recorded_workload list
  ; migrations : string list
  ; contract : contract_fact list
  ; apply_mode : apply_mode
  ; encoding_version : string option
  }

let sanitize_label (s : string) : string =
  let buf = Buffer.create (String.length s) in
  s
  |> String.iter (fun c ->
    match c with
    | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> Buffer.add_char buf c
    | 'A' .. 'Z' -> Buffer.add_char buf (Char.lowercase_ascii c)
    | _ -> Buffer.add_char buf '-');
  let out = Buffer.contents buf in
  let out = if String.length out > 63 then String.sub out 0 63 else out in
  let len = String.length out in
  let start = ref 0 in
  while
    !start < len && (out.[!start] = '-' || out.[!start] = '.' || out.[!start] = '_')
  do
    incr start
  done;
  let stop = ref (len - 1) in
  while
    !stop >= !start && (out.[!stop] = '-' || out.[!stop] = '.' || out.[!stop] = '_')
  do
    decr stop
  done;
  let trimmed =
    if !stop < !start then "" else String.sub out !start (!stop - !start + 1)
  in
  if trimmed = "" then "none" else trimmed
;;

let configmap_name (t : t) : string = Printf.sprintf "sol-release-%s" t.release_id

let current_configmap_name ~(workspace : string) : string =
  Printf.sprintf
    "sol-release-current-%s"
    (Sol_cli_kubernetes_name.sanitize_name workspace)
;;

let workload_of_spec (spec : Sol_cli_deployment_plan.service_spec) : workload =
  Sol_cli_deployment_plan.release_workload_of_spec spec
;;

let applied_by identity (w : workload) =
  { Sol_cli_release_id.spec = w; applied_by = identity; owned = [] }
;;

let workload_identity (w : recorded_workload) = w.Sol_cli_release_id.spec

let same_workload_identity (a : recorded_workload) (b : recorded_workload) =
  let a = a.Sol_cli_release_id.spec
  and b = b.Sol_cli_release_id.spec in
  String.equal a.domain b.domain
  && String.equal a.name b.name
  && String.equal a.primitive b.primitive
;;

let boundary_id ~workspace ~environment ~contract ~deployed ~inherited =
  Sol_cli_release_id.to_string
    (Sol_cli_release_id.of_boundary
       ~workspace
       ~environment
       ~contract
       ~deployed
       ~inherited)
;;

(* **The one derivation of a stored record's id**, used at write
   ([of_plan_with_boundary]) and at read ([validate]). A record is valid exactly when its
   stored id equals this. *)
let derived_release_id (t : t) : Sol_cli_release_id.t =
  Sol_cli_release_id.of_recorded_boundary
    ~workspace:t.workspace
    ~environment:t.environment
    ~contract:t.contract
    t.workloads
;;

let of_plan_with_boundary
      ?(owned = [])
      ~(apply_mode : apply_mode)
      ~(retained : recorded_workload list)
      (plan : Sol_cli_deployment_plan.t)
  : t
  =
  let deployed = List.map workload_of_spec plan.services in
  (* Attach the UID evidence captured at apply to the workload it identifies.
     [owned] is matched by the full identity — kind, namespace and name
     (docs/architecture/ownership.md); a workload with no matching evidence
     records none, which a removal must read as "no evidence". Matching kind too
     matters: two units can normalize to one name and still project to different
     objects (a Deployment and a CronJob both named [charge-svc]). A unit's
     ExternalSecret is attached through the one projection in
     [Sol_cli_deployment_plan.external_secret_of_spec], shared with evidence capture and
     the prune's declared set.

     Invariant: every entry captured into [owned] must be attached to some workload here,
     or it is silently dropped before the record is written. That is how a correct capture
     and a correct prune once shipped with the evidence never recorded — a new evidence
     type needs a matching arm here and a test that it survives into the record
     (test_deploy_run: "a captured evidence entry is recorded with its workload"). *)
  let owned_for (spec : Sol_cli_deployment_plan.service_spec) =
    let resource = Sol_cli_deployment_plan.resource_of_spec spec in
    let namespace = Sol_cli_deployment_plan.namespace_to_string spec.namespace in
    let name = Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name in
    let external_secret = Sol_cli_deployment_plan.external_secret_of_spec spec in
    List.filter
      (fun (o : Sol_cli_release_id.owned_object) ->
         String.equal o.namespace namespace
         && ((String.equal o.resource resource && String.equal o.name name)
             ||
             match external_secret with
             | Some (external_namespace, external_name) ->
               String.equal o.resource "externalsecret"
               && String.equal o.namespace external_namespace
               && String.equal o.name external_name
             | None -> false))
      owned
  in
  let deployed_records = List.map (applied_by "") deployed in
  let inherited =
    if Sol_cli_deployment_plan.is_whole_workspace plan
    then []
    else
      List.filter
        (fun (w : recorded_workload) ->
           not (List.exists (fun a -> same_workload_identity w a) deployed_records))
        retained
  in
  let release_id =
    boundary_id
      ~workspace:plan.workspace
      ~environment:plan.environment.env
      ~contract:plan.contract
      ~deployed
      ~inherited:(List.map (fun w -> w.Sol_cli_release_id.spec, w.applied_by) inherited)
  in
  let record =
    { release_id
    ; workspace = plan.workspace
    ; environment = plan.environment.env
    ; workloads =
        List.map2
          (fun (spec : Sol_cli_deployment_plan.service_spec) w ->
             { (applied_by (Sol_cli_release_id.to_string plan.release_id) w) with
               Sol_cli_release_id.owned = owned_for spec
             })
          plan.services
          deployed
        @ inherited
    ; migrations = List.map Sol_cli_plan_ids.Migration_file.to_string plan.migrations
    ; contract = plan.contract
    ; apply_mode
    ; encoding_version = Some Sol_cli_release_id.encoding_version
    }
  in
  (* The record's id must be the id its **own stored content** rederives, because that is
     exactly what a later read checks ([validate], via [derived_release_id]). Deriving it from
     the finished record makes that true by construction rather than by agreement between two
     computations.

     They did not agree: [boundary_id] derives with the deployed workloads' `applied_by` set to
     the *content* id, while the record stores them with `applied_by` = `plan.release_id`, and
     `applied_by` is itself part of what the derivation reads. Whenever those two ids differed
     -- a scoped deploy, where an already-applied workload is *retained* -- the deploy wrote a
     record every later deploy refused as corrupt ("its content rederives ...") and the target
     could not be deployed to again (#1440). *)
  { record with release_id = Sol_cli_release_id.to_string (derived_release_id record) }
;;

let of_plan ~(apply_mode : apply_mode) (plan : Sol_cli_deployment_plan.t) : t =
  of_plan_with_boundary ~apply_mode ~retained:[] plan
;;

let stale_encoding_version_message (t : t) written_with =
  Printf.sprintf
    "release record %s was written with encoding_version %s, but this CLI writes %s: the \
     record predates a release-identity format change and cannot be verified against it \
     (a release-identity format change, not damage)"
    t.release_id
    written_with
    Sol_cli_release_id.encoding_version
;;

let undeclared_encoding_version_message (t : t) derived =
  Printf.sprintf
    "release record %s declares no encoding_version, and its content rederives %s: the \
     record predates the encoding_version marker this CLI writes (now %s), so a \
     release-identity format change and damaged content cannot be told apart here -- \
     re-record the release with this CLI rather than assuming the record is damaged"
    t.release_id
    (Sol_cli_release_id.to_string derived)
    Sol_cli_release_id.encoding_version
;;

let validate ~(name : string) (t : t) : (unit, string) result =
  let open Result.Syntax in
  let* id = Sol_cli_release_id.of_string t.release_id in
  if not (String.equal name (configmap_name t))
  then
    Error
      (Printf.sprintf
         "%s is not the record for release %s (expected name %s)"
         name
         t.release_id
         (configmap_name t))
  else (
    match t.encoding_version with
    | Some written_with
      when not (String.equal written_with Sol_cli_release_id.encoding_version) ->
      Error (stale_encoding_version_message t written_with)
    | _ ->
      let derived = derived_release_id t in
      if derived <> id
      then
        Error
          (match t.encoding_version with
           | None -> undeclared_encoding_version_message t derived
           | Some _ ->
             Printf.sprintf
               "release record %s is corrupt: its content rederives %s"
               t.release_id
               (Sol_cli_release_id.to_string derived))
      else Ok ())
;;

let sorted_pairs pairs =
  pairs
  |> List.sort (fun (a, av) (b, bv) ->
    let by_key = String.compare a b in
    if by_key <> 0 then by_key else String.compare av bv)
;;

let pairs_to_assoc pairs =
  `Assoc (List.map (fun (k, v) -> k, `String v) (sorted_pairs pairs))
;;

let compare_workload (a : recorded_workload) (b : recorded_workload) =
  let a = a.Sol_cli_release_id.spec
  and b = b.Sol_cli_release_id.spec in
  let by_domain = String.compare a.domain b.domain in
  if by_domain <> 0
  then by_domain
  else (
    let by_name = String.compare a.name b.name in
    if by_name <> 0 then by_name else String.compare a.primitive b.primitive)
;;

let compare_row4 (a1, a2, a3, a4) (b1, b2, b3, b4) =
  let c = String.compare a1 b1 in
  if c <> 0
  then c
  else (
    let c = String.compare a2 b2 in
    if c <> 0
    then c
    else (
      let c = String.compare a3 b3 in
      if c <> 0 then c else String.compare a4 b4))
;;

let rows_to_json rows =
  `List
    (List.sort compare_row4 rows
     |> List.map (fun (a, b, c, d) ->
       `List [ `String a; `String b; `String c; `String d ]))
;;

let rows3_to_json rows =
  `List
    (List.sort compare rows
     |> List.map (fun (a, b, c) -> `List [ `String a; `String b; `String c ]))
;;

let workload_to_json (w : workload) : Yojson.Safe.t =
  `Assoc
    [ "domain", `String w.domain
    ; "name", `String w.name
    ; "primitive", `String w.primitive
    ; "image", `String w.image
    ; "config", pairs_to_assoc w.config
    ; "secrets", pairs_to_assoc w.secrets
    ; "uses", `List (List.map (fun u -> `String u) w.uses)
    ; "external_secret_refs", rows3_to_json w.external_secret_refs
    ; ( "schedule"
      , match w.schedule with
        | None -> `Null
        | Some s -> `String s )
    ; "scheduled_concurrency", `String w.scheduled_concurrency
    ; "backoff_limit", `Int w.backoff_limit
    ; "replicas", `Int w.replicas
    ; "availability", `String w.availability
    ; "consumes_kafka", `Bool w.consumes_kafka
    ; "cpu", `String w.cpu
    ; "memory", `String w.memory
    ; "extra_labels", pairs_to_assoc w.extra_labels
    ; "volumes", rows_to_json w.volumes
    ; "rollout", `String w.rollout
    ; ( "ingress_host"
      , match w.ingress_host with
        | None -> `Null
        | Some h -> `String h )
    ; ( "ingress_path"
      , match w.ingress_path with
        | None -> `Null
        | Some p -> `String p )
    ; "cluster_issuer", `String w.cluster_issuer
    ; "calls", rows_to_json w.calls
    ]
;;

let owned_object_to_json (o : Sol_cli_release_id.owned_object) : Yojson.Safe.t =
  `Assoc
    [ "resource", `String o.resource
    ; "namespace", `String o.namespace
    ; "name", `String o.name
    ; "uid", `String o.uid
    ]
;;

let recorded_workload_to_json (w : recorded_workload) : Yojson.Safe.t =
  match workload_to_json w.Sol_cli_release_id.spec with
  | `Assoc fields ->
    (* A workload with no ownership evidence carries no [owned] field, so a record
       written before UID capture keeps the canonical body it already had. *)
    let owned =
      match w.Sol_cli_release_id.owned with
      | [] -> []
      | owned -> [ "owned", `List (List.map owned_object_to_json owned) ]
    in
    `Assoc (("applied_by", `String w.applied_by) :: (owned @ fields))
  | other -> other
;;

let compare_contract (a : contract_fact) (b : contract_fact) =
  String.compare a.subject b.subject
;;

let contract_fact_to_json (f : contract_fact) : Yojson.Safe.t =
  `Assoc
    [ "subject", `String f.subject
    ; "topic", `String f.topic
    ; "partitions", `Int f.partitions
    ; ( "key"
      , match f.key with
        | None -> `Null
        | Some k -> `String k )
    ; "schema_digest", `String f.schema_digest
    ]
;;

let to_json (t : t) : Yojson.Safe.t =
  `Assoc
    [ "release_id", `String t.release_id
    ; "workspace", `String t.workspace
    ; ( "environment"
      , match t.environment with
        | None -> `Null
        | Some e -> `String e )
    ; ( "workloads"
      , `List
          (List.map recorded_workload_to_json (List.sort compare_workload t.workloads)) )
    ; ( "migrations"
      , `List (List.map (fun m -> `String m) (List.sort String.compare t.migrations)) )
    ; ( "contract"
      , `List (List.map contract_fact_to_json (List.sort compare_contract t.contract)) )
    ; "apply_mode", `String (apply_mode_to_string t.apply_mode)
    ; ( "encoding_version"
      , match t.encoding_version with
        | None -> `Null
        | Some v -> `String v )
    ]
;;

let record_json_string (t : t) : string = Yojson.Safe.to_string (to_json t)

(* [record_digest] is a digest of the record's content, not of the ownership evidence
   captured beside a workload: the UID authorizes a removal by matching the live object
   (docs/architecture/ownership.md), it does not identify the release. Two records with
   the same content but different applied UIDs therefore share a digest, and a record
   written before UID capture keeps the digest it had. *)
let record_digest (t : t) : string =
  let without_ownership_evidence =
    { t with
      workloads =
        List.map
          (fun (w : recorded_workload) -> { w with Sol_cli_release_id.owned = [] })
          t.workloads
    }
  in
  Digest.to_hex (Digest.string (record_json_string without_ownership_evidence))
;;

let mem key = function
  | `Assoc kvs -> List.assoc_opt key kvs
  | _ -> None
;;

let str key json =
  match mem key json with
  | Some (`String s) -> s
  | _ -> ""
;;

let int key json =
  match mem key json with
  | Some (`Int i) -> i
  | _ -> 0
;;

let list key json =
  match mem key json with
  | Some (`List l) -> l
  | _ -> []
;;

let string_option key json =
  match mem key json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let pairs key json =
  match mem key json with
  | Some (`Assoc kvs) ->
    kvs
    |> List.map (fun (k, v) ->
      ( k
      , match v with
        | `String s -> s
        | _ -> "" ))
  | _ -> []
;;

let rows key json =
  match mem key json with
  | Some (`List rows) ->
    List.map
      (function
        | `List cells ->
          List.map
            (function
              | `String s -> s
              | _ -> "")
            cells
        | _ -> [])
      rows
  | _ -> []
;;

let row4 = function
  | [ a; b; c; d ] -> a, b, c, d
  | _ -> "", "", "", ""
;;

let row3 = function
  | [ a; b; c ] -> a, b, c
  | _ -> "", "", ""
;;

let workload_of_json (json : Yojson.Safe.t) : workload =
  { domain = str "domain" json
  ; name = str "name" json
  ; primitive = str "primitive" json
  ; image = str "image" json
  ; config = pairs "config" json
  ; secrets = pairs "secrets" json
  ; uses =
      (match Sol_cli_json.field [ "uses" ] json with
       | `List items ->
         List.filter_map
           (function
             | `String u -> Some u
             | _ -> None)
           items
       | _ -> [])
  ; external_secret_refs = List.map row3 (rows "external_secret_refs" json)
  ; schedule = string_option "schedule" json
  ; scheduled_concurrency = str "scheduled_concurrency" json
  ; backoff_limit = int "backoff_limit" json
  ; replicas = int "replicas" json
  ; availability =
      (match Sol_cli_json.field [ "availability" ] json with
       | `String s -> s
       | _ -> "single")
  ; consumes_kafka =
      (match Sol_cli_json.field [ "consumes_kafka" ] json with
       | `Bool b -> b
       | _ -> false)
  ; cpu = str "cpu" json
  ; memory = str "memory" json
  ; extra_labels = pairs "extra_labels" json
  ; volumes = List.map row4 (rows "volumes" json)
  ; rollout = str "rollout" json
  ; ingress_host = string_option "ingress_host" json
  ; ingress_path = string_option "ingress_path" json
  ; cluster_issuer = str "cluster_issuer" json
  ; calls = List.map row4 (rows "calls" json)
  }
;;

(* Ownership evidence captured at apply. A record written before UID capture has
   no [owned] field: that is "no evidence", never a corrupt record, so its absence
   must not fail the read. See docs/architecture/ownership.md. *)
let owned_objects_of_json json : Sol_cli_release_id.owned_object list =
  match Sol_cli_json.field [ "owned" ] json with
  | `List items ->
    List.filter_map
      (fun item ->
         let string_field key = Sol_cli_json.field [ key ] item |> Sol_cli_json.string in
         match
           ( string_field "resource"
           , string_field "namespace"
           , string_field "name"
           , string_field "uid" )
         with
         | Some resource, Some namespace, Some name, Some uid
           when not (String.equal uid "") ->
           Some { Sol_cli_release_id.resource; namespace; name; uid }
         | _ -> None)
      items
  | _ -> []
;;

let recorded_workload_of_json (json : Yojson.Safe.t) : recorded_workload =
  { Sol_cli_release_id.spec = workload_of_json json
  ; applied_by = str "applied_by" json
  ; owned = owned_objects_of_json json
  }
;;

let contract_fact_of_json (json : Yojson.Safe.t) : contract_fact =
  { subject = str "subject" json
  ; topic = str "topic" json
  ; partitions = int "partitions" json
  ; key = string_option "key" json
  ; schema_digest = str "schema_digest" json
  }
;;

let string_list key json =
  List.filter_map
    (function
      | `String s -> Some s
      | _ -> None)
    (list key json)
;;

let apply_mode_of_json (json : Yojson.Safe.t) : (apply_mode, string) result =
  match mem "apply_mode" json with
  | Some (`String s) -> apply_mode_of_string s
  | Some _ -> Error "release record has a non-string apply_mode"
  | None -> Error "release record is missing apply_mode"
;;

let of_json (json : Yojson.Safe.t) : (t, string) result =
  match str "release_id" json, str "workspace" json with
  | "", _ | _, "" -> Error "release record is missing release_id/workspace"
  | release_id, workspace ->
    let open Result.Syntax in
    let* apply_mode = apply_mode_of_json json in
    Ok
      { release_id
      ; workspace
      ; environment = string_option "environment" json
      ; workloads = List.map recorded_workload_of_json (list "workloads" json)
      ; migrations = string_list "migrations" json
      ; contract = List.map contract_fact_of_json (list "contract" json)
      ; apply_mode
      ; encoding_version = string_option "encoding_version" json
      }
;;

let to_configmap_json (t : t) : string =
  Yojson.Safe.pretty_to_string
    (`Assoc
        [ "apiVersion", `String "v1"
        ; "kind", `String "ConfigMap"
        ; "immutable", `Bool true
        ; ( "metadata"
          , `Assoc
              [ "name", `String (configmap_name t)
              ; "namespace", `String "default"
              ; ( "labels"
                , `Assoc
                    [ "sol.dev/type", `String "release"
                    ; "sol.dev/workspace", `String (sanitize_label t.workspace)
                    ] )
              ] )
        ; ( "data"
          , `Assoc
              [ "release_id", `String t.release_id
              ; "record", `String (record_json_string t)
              ; "record_digest", `String (record_digest t)
              ] )
        ])
;;

let to_current_configmap_json (t : t) : string =
  Yojson.Safe.pretty_to_string
    (`Assoc
        [ "apiVersion", `String "v1"
        ; "kind", `String "ConfigMap"
        ; ( "metadata"
          , `Assoc
              [ "name", `String (current_configmap_name ~workspace:t.workspace)
              ; "namespace", `String "default"
              ; ( "labels"
                , `Assoc
                    [ "sol.dev/type", `String "release-current"
                    ; "sol.dev/workspace", `String (sanitize_label t.workspace)
                    ] )
              ] )
        ; "data", `Assoc [ "release_id", `String t.release_id ]
        ])
;;

let bundle_files (t : t) : (string * string) list =
  [ configmap_name t ^ ".yaml", to_configmap_json t
  ; "sol-current-release.yaml", to_current_configmap_json t
  ]
;;

let item_name item =
  match mem "metadata" item with
  | Some metadata -> str "name" metadata
  | None -> ""
;;

let creation_timestamp_of_item ~label item =
  Sol_cli_json.require
    ~what:label
    [ "metadata"; "creationTimestamp" ]
    Sol_cli_json.string
    item
;;

let of_kubectl_item (item : Yojson.Safe.t) : (t, string) result =
  let name = item_name item in
  let label = if String.equal name "" then "<unnamed configmap>" else name in
  match mem "data" item with
  | None -> Error (Printf.sprintf "%s has no data" label)
  | Some data ->
    (match mem "record" data with
     | Some (`String record) ->
       (match mem "record_digest" data with
        | Some (`String stored) when String.length stored > 0 ->
          (* The digest covers the record's content, not its ownership evidence
             (see [record_digest]), so it is checked against the parsed record. *)
          let open Result.Syntax in
          let* parsed = Sol_cli_json.decode ~what:(label ^ ": data.record") record in
          let* r = of_json parsed |> Result.map_error (Printf.sprintf "%s: %s" label) in
          let* () =
            if String.equal (record_digest r) stored
            then Ok ()
            else Error (Printf.sprintf "%s failed integrity validation" label)
          in
          let* () = validate ~name r in
          Ok r
        | _ ->
          Error
            (Printf.sprintf
               "%s uses an unsupported record format: missing integrity digest"
               label))
     | _ -> Error (Printf.sprintf "%s has no data.record" label))
;;

let list_items json =
  Sol_cli_json.require ~what:"release list" [ "items" ] Sol_cli_json.list json
;;

let record_of_item item =
  of_kubectl_item item
  |> Result.map_error (Printf.sprintf "release history contains an invalid record: %s")
;;

let parse_kubectl_list_with_creation (json : Yojson.Safe.t)
  : ((t * string) list, string) result
  =
  let open Result.Syntax in
  let with_creation item =
    let* record = record_of_item item in
    let* created = creation_timestamp_of_item ~label:(item_name item) item in
    Ok (record, created)
  in
  let* items = list_items json in
  Sol_cli_result.map_list with_creation items
;;

let parse_kubectl_list json =
  let open Result.Syntax in
  let* items = list_items json in
  Sol_cli_result.map_list record_of_item items
;;

let format_table (records : t list) : string =
  let sorted = List.sort (fun a b -> String.compare a.release_id b.release_id) records in
  let rows =
    sorted
    |> List.map (fun r ->
      [ r.release_id
      ; (match r.environment with
         | None -> "-"
         | Some e -> e)
      ; string_of_int (List.length r.workloads)
      ])
  in
  let headers = [ "ID"; "ENV"; "WORKLOADS" ] in
  let widths =
    headers
    |> List.mapi (fun i h ->
      List.fold_left
        (fun acc row -> max acc (String.length (List.nth row i)))
        (String.length h)
        rows)
  in
  let render_row row =
    List.mapi (fun i cell -> Printf.sprintf "%-*s" (List.nth widths i) cell) row
    |> String.concat "  "
    |> fun s -> String.trim s
  in
  String.concat "\n" (render_row headers :: List.map render_row rows)
;;

let finish_deployment ~(record_release : unit -> (unit, string) result) ~report_success =
  let open Result.Syntax in
  let* () = record_release () in
  report_success ();
  Ok ()
;;
