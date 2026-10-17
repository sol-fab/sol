module D = Qual_domain
module K = Qual_kubernetes
module I = Sol_cli_kube_identity
open Result.Syntax

type t =
  { ctx : Sol_cli_kube_destination.context
  ; expected : D.kube_target
  ; operator_diagnostics : (I.error -> unit) option
  }

let create ?operator_diagnostics ~ctx ~expected () =
  { ctx; expected; operator_diagnostics }
;;

let target (i : I.t) : D.kube_target =
  { principal = i.principal; cluster = i.cluster; endpoint = i.endpoint }
;;

let now () = int_of_float (Unix.gettimeofday ())

let safe_failure transport error =
  Option.iter (fun f -> f error) transport.operator_diagnostics;
  I.diagnostic error
;;

(* One observation of the live authority, used to timestamp a submission receipt
   independently of whatever the product reports. Resource reads still bracket
   themselves; this context is never a substitute for that bracketing. *)
let establish transport =
  match I.observe ~ctx:transport.ctx with
  | Error error -> Error (safe_failure transport error)
  | Ok identity ->
    let observed = target identity in
    if observed <> transport.expected
    then Error "observed Kubernetes principal/cluster/endpoint mismatch"
    else (
      let now = now () in
      Ok
        { D.target = observed
        ; verified_at = now
        ; started_at = now
        ; finished_at = now
        ; expires_at = Some (now + 300)
        })
;;

let read transport (query : K.query) =
  let started = now () in
  let execute () =
    if query.target <> transport.expected
    then Error "query belongs to another observation authority"
    else
      let* before =
        I.observe ~ctx:transport.ctx |> Result.map_error (safe_failure transport)
      in
      if target before <> transport.expected
      then Error "observed Kubernetes principal/cluster/endpoint mismatch"
      else (
        let resource =
          match query.resource with
          | K.Deployment -> "deployments.apps"
          | K.Job -> "jobs.batch"
          | K.Configmap -> "configmaps"
        in
        (* Native exact-name lists establish absence without interpreting stderr.
           No cached discovery or manual selector can shorten the expected universe. *)
        let result =
          Sol_cli_kubectl.run
            ~ctx:transport.ctx
            ~timeout_s:15.
            [ "get"
            ; resource
            ; "--namespace"
            ; query.namespace
            ; "--field-selector"
            ; "metadata.name=" ^ query.name
            ; "-o"
            ; "json"
            ]
        in
        (match result with
         | Error error -> ignore (safe_failure transport (I.Command ("read", error)))
         | Ok _ -> ());
        let* after =
          I.observe ~ctx:transport.ctx |> Result.map_error (safe_failure transport)
        in
        if not (I.same before after)
        then Error "Kubernetes observation authority changed during read"
        else Ok (before, result))
  in
  match execute () with
  | Error message ->
    { K.context =
        { D.target = transport.expected
        ; verified_at = -1
        ; started_at = started
        ; finished_at = now ()
        ; expires_at = Some 0
        }
    ; result = K.Spawn_failed message
    }
  | Ok (identity, result) ->
    let finished = now () in
    let result =
      if finished < started || finished - started > 300
      then K.Spawn_failed "Kubernetes observation freshness window expired"
      else (
        match result with
        | Ok output -> K.Exited { code = 0; stdout = output.stdout; stderr = "" }
        | Error (Sol_cli_process.Non_zero f) ->
          K.Exited
            { code = f.exit_code
            ; stdout = ""
            ; stderr = Printf.sprintf "Kubernetes read exited %d" f.exit_code
            }
        | Error (Timeout _) -> K.Timed_out "Kubernetes read timed out"
        | Error (Spawn_failed _) -> K.Spawn_failed "Kubernetes read could not start")
    in
    { K.context =
        { D.target = target identity
        ; verified_at = started
        ; started_at = started
        ; finished_at = finished
        ; expires_at = Some (started + 300)
        }
    ; result
    }
;;
