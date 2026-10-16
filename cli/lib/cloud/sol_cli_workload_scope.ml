type workload =
  { resource : string
  ; name : string
  ; uid : string
  }

type scope =
  { namespace : string
  ; workloads : workload list
  }

type workload_kind =
  | Deployment
  | CronJob
  | Job
  | Rollout

let kinds = [ Deployment; CronJob; Job; Rollout ]
let selector ~workspace = "workspace=" ^ workspace
let pod_template_labels = [ "spec"; "template"; "metadata"; "labels" ]
let job_template_prefix = [ "spec"; "jobTemplate" ]

let resource_of_kind = function
  | Deployment -> "deployment"
  | CronJob -> "cronjob"
  | Job -> "job"
  | Rollout -> "rollout"
;;

let optional_kind = function
  | Rollout -> true
  | Deployment | CronJob | Job -> false
;;

let list_args ~namespace ~kind =
  [ "get"; resource_of_kind kind; "-n"; namespace; "--output"; "json" ]
;;

(* Existence is read from the cluster-scoped object rather than inferred from the namespaced
   listing. A namespaced read answers [Forbidden] -- not [NotFound] -- for an identity with no
   grant in the namespace, and RBAC is evaluated before namespace existence, so the namespaced
   listing alone cannot tell "the namespace is empty" from "this identity may not look"
   (sol-fab/sol#1488). Presence of the namespace object is what makes a workload possible. *)
let namespace_exists_args ~namespace =
  [ "get"; "namespace"; namespace; "--output"; "json" ]
;;

(* One authoritative namespace-existence observation, classified by the command layer, which
   owns the process error. The decision below interprets it. *)
type namespace_probe =
  | Namespace_exists
  | Namespace_absent
  | Namespace_unreachable of string
  | Namespace_unestablished of string

type release_failure =
  { namespace : string
  ; kind : string option
  ; operation : string
  ; reason : string
  }

type release =
  | Workloads_released
  | Workloads_not_releasable of string
  | Workloads_unestablished of release_failure

let failure_to_string failure =
  match failure.kind with
  | Some kind ->
    Printf.sprintf
      "in namespace %s, %s the %s failed: %s"
      failure.namespace
      failure.operation
      kind
      failure.reason
  | None ->
    Printf.sprintf
      "in namespace %s, %s failed: %s"
      failure.namespace
      failure.operation
      failure.reason
;;

let delete_args ~namespace ~names ~timeout_seconds =
  [ "delete" ]
  @ names
  @ [ "-n"
    ; namespace
    ; "--ignore-not-found"
    ; "--wait=true"
    ; Printf.sprintf "--timeout=%ds" timeout_seconds
    ]
;;

let wait_args ~namespace ~workspace ~timeout_seconds =
  [ "wait"
  ; "--for=delete"
  ; "pod"
  ; "-n"
  ; namespace
  ; "--selector"
  ; selector ~workspace
  ; Printf.sprintf "--timeout=%ds" timeout_seconds
  ]
;;

let kind_of_name = function
  | "Deployment" -> Some Deployment
  | "CronJob" -> Some CronJob
  | "Job" -> Some Job
  | "Rollout" -> Some Rollout
  | _ -> None
;;

let template_labels_of_kind = function
  | Deployment | Job | Rollout -> pod_template_labels
  | CronJob -> job_template_prefix @ pod_template_labels
;;

let template_carries_workspace ~kind ~workspace item =
  Sol_cli_json.field (template_labels_of_kind kind @ [ "workspace" ]) item
  |> Sol_cli_json.string
  = Some workspace
;;

let workload_of_item ~workspace item =
  let kind =
    Option.bind (Sol_cli_json.field [ "kind" ] item |> Sol_cli_json.string) kind_of_name
  in
  let name = Sol_cli_json.field [ "metadata"; "name" ] item |> Sol_cli_json.string in
  match kind, name with
  | Some kind, Some name when not (Sol_cli_string.is_blank name) ->
    if template_carries_workspace ~kind ~workspace item
    then
      Some
        { resource = resource_of_kind kind
        ; name
        ; uid =
            Sol_cli_json.field [ "metadata"; "uid" ] item
            |> Sol_cli_json.string
            |> Option.value ~default:""
        }
    else None
  | _ -> None
;;

let workload_to_string (w : workload) = Printf.sprintf "%s/%s" w.resource w.name

let compare_workload (a : workload) (b : workload) =
  let by_resource = String.compare a.resource b.resource in
  if by_resource <> 0
  then by_resource
  else (
    let by_name = String.compare a.name b.name in
    if by_name <> 0 then by_name else String.compare a.uid b.uid)
;;

let workloads_of_json json ~workspace =
  match Sol_cli_json.items ~what:"the workload listing" json with
  | Error message -> Error message
  | Ok items ->
    Ok
      (items
       |> List.filter_map (workload_of_item ~workspace)
       |> List.sort_uniq compare_workload)
;;

(* Which listed workloads Sol may remove: the live UID equals the UID recorded when Sol
   applied it (docs/architecture/ownership.md). A workload with no recorded UID, a
   different UID, or none observed is retained. The label that listed it only selected
   what to look at. *)
let partition_owned ~(evidence : Sol_cli_release_id.owned_object list) (scope : scope) =
  let owns (w : workload) =
    let id =
      { Sol_cli_workload_ownership.resource = w.resource
      ; namespace = scope.namespace
      ; name = w.name
      }
    in
    let recorded = Sol_cli_workload_ownership.recorded_uid evidence id in
    (not (String.equal w.uid ""))
    && Sol_cli_workload_ownership.owns ~recorded ~live_uid:w.uid
  in
  List.partition owns scope.workloads
;;

type read_error =
  | No_cluster of string
  | Read_unestablished of release_failure

type read_result =
  { scopes : scope list
  ; namespaces_absent : string list
  }

(* [namespace_probe] answers whether one declared namespace exists, from an identity that can
   establish it cluster-wide. Absence is then a positive observation about the namespace --
   and a workload cannot exist without its namespace -- rather than an inference from a
   namespaced read that could not be authorized.

   One observation decides one namespace, and it is classified once. A view that could not be
   established is not evidence of absence, so it refuses: it does not fall back to the weaker
   namespaced read that this observation exists to replace. The namespaced reads still run per
   namespace and still fail closed: once a namespace exists its workloads may exist too, and an
   identity that may not read them has established nothing. *)
let read_workloads ~run ~namespace_probe ~namespaces ~workspace
  : (read_result, read_error) result
  =
  let read_namespace ~contacted namespace =
    match namespace_probe namespace with
    | Namespace_absent -> Ok (contacted, `Absent)
    | Namespace_unreachable reason when not contacted ->
      Error (No_cluster (Printf.sprintf "the cluster could not be reached (%s)" reason))
    | Namespace_unreachable reason | Namespace_unestablished reason ->
      Error
        (Read_unestablished
           { namespace
           ; kind = None
           ; operation = "establishing whether the namespace exists"
           ; reason
           })
    | Namespace_exists ->
      let rec read_kind ~contacted found = function
        | [] -> Ok (contacted, List.concat (List.rev found))
        | kind :: rest ->
          let resource = resource_of_kind kind in
          let unestablished operation reason =
            Error
              (Read_unestablished { namespace; kind = Some resource; operation; reason })
          in
          (match run (list_args ~namespace ~kind) with
           | Ok json ->
             (match workloads_of_json json ~workspace with
              | Ok workloads -> read_kind ~contacted:true (workloads :: found) rest
              | Error reason -> unestablished "reading" reason)
           | Error e ->
             let reason = Sol_cli_process.error_to_string e in
             (match Sol_cli_kubectl.classify e with
              | Sol_cli_kubectl.No_resource_type when optional_kind kind ->
                read_kind ~contacted:true found rest
              | Sol_cli_kubectl.Not_found -> read_kind ~contacted:true found rest
              | Sol_cli_kubectl.Unreachable when not contacted ->
                Error
                  (No_cluster
                     (Printf.sprintf "the cluster could not be reached (%s)" reason))
              | _ -> unestablished "reading" reason))
      in
      (match read_kind ~contacted [] kinds with
       | Ok (contacted, workloads) -> Ok (contacted, `Present { namespace; workloads })
       | Error error -> Error error)
  in
  let rec go ~contacted scopes absent = function
    | [] -> Ok { scopes = List.rev scopes; namespaces_absent = List.rev absent }
    | namespace :: rest ->
      (match read_namespace ~contacted namespace with
       | Ok (contacted, `Absent) -> go ~contacted scopes (namespace :: absent) rest
       | Ok (contacted, `Present scope) -> go ~contacted (scope :: scopes) absent rest
       | Error error -> Error error)
  in
  go ~contacted:false [] [] namespaces
;;

let to_string scope =
  match scope.workloads with
  | [] -> Printf.sprintf "%s: no workload of this workspace is running" scope.namespace
  | workloads ->
    Printf.sprintf
      "%s: releasing %s"
      scope.namespace
      (String.concat ", " (List.map workload_to_string workloads))
;;

(* Release (delete) every workload of this workspace in the given namespaces, but only
   those whose live UID matches the recorded evidence: the `workspace` label selects
   candidates, it never authorizes removal. Everything else is retained and reported. The
   command layer supplies the cluster-bound existence probe/read/delete/wait, so the
   decision itself is exercised without a cluster.

   A target whose declared namespaces all positively do not exist has nothing to release:
   the release is not applicable, and destruction proceeds without an override
   (sol-fab/sol#1491). A target with no declared namespace at all is the same case. Every
   other answer keeps the checks below, including the refusal when a namespace exists and
   its workloads cannot be established. *)
let release_workloads
      ~run
      ~namespace_probe
      ~delete
      ~wait
      ~(evidence : Sol_cli_release_id.owned_object list)
      ~namespaces
      ~workspace
  : release
  =
  match read_workloads ~run ~namespace_probe ~namespaces ~workspace with
  | Error (No_cluster reason) -> Workloads_not_releasable reason
  | Error (Read_unestablished failure) -> Workloads_unestablished failure
  | Ok { scopes; namespaces_absent } ->
    let every_namespace_absent =
      namespaces <> [] && List.length namespaces_absent = List.length namespaces
    in
    if namespaces = [] || every_namespace_absent
    then
      Workloads_not_releasable
        (match namespaces with
         | [] ->
           "this target declares no application namespace, so it has no workload to \
            release from"
         | namespaces ->
           Printf.sprintf
             "no declared namespace of this target exists (%s), so no workload of this \
              target can be running"
             (String.concat ", " namespaces))
    else (
      let unreleased namespace operation reason =
        Workloads_unestablished { namespace; kind = None; operation; reason }
      in
      let remove (scope : scope) : (unit, release) result =
        let owned, retained = partition_owned ~evidence scope in
        let warn_retained () =
          if retained <> []
          then
            Sol_cli_report.warn
              "%s: retaining %d workload(s) Sol cannot prove it owns (no recorded UID \
               match): %s"
              scope.namespace
              (List.length retained)
              (String.concat ", " (List.map workload_to_string retained))
        in
        match owned with
        | [] ->
          warn_retained ();
          Ok ()
        | owned ->
          Sol_cli_report.app "  %s" (to_string { scope with workloads = owned });
          (match
             delete ~namespace:scope.namespace ~names:(List.map workload_to_string owned)
           with
           | Error e ->
             Error
               (unreleased
                  scope.namespace
                  "removing the workloads it found"
                  (Sol_cli_process.error_to_string e))
           | Ok () ->
             warn_retained ();
             (match wait ~namespace:scope.namespace with
              | Ok () -> Ok ()
              | Error e ->
                Error
                  (unreleased
                     scope.namespace
                     "waiting for the pods to go"
                     (Sol_cli_process.error_to_string e))))
      in
      let rec go = function
        | [] -> Workloads_released
        | scope :: rest ->
          (match remove scope with
           | Ok () -> go rest
           | Error unreleased -> unreleased)
      in
      go scopes)
;;
