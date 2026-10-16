module D = Qual_domain
module E = Qual_evidence
module K = Qual_kubernetes
open Result.Syntax

type recorded =
  { verdict : D.verdict
  ; receipt : E.reference
  ; observations : E.reference list
  }

type outcome =
  { instance : D.instance
  ; result : (recorded, E.error) result
  }

let decode directory run reference =
  let* captured = E.read_capture ~directory ~run reference in
  match K.decode captured with
  | Ok observation -> Ok observation
  | Error message -> Error { E.stage = "Kubernetes projection"; diagnostic = message }
;;

let evaluate_recorded ~directory ~run ~requirement ~deployment ~configmap =
  let* deployment_fact = decode directory run deployment in
  let* configmap_fact = decode directory run configmap in
  match deployment_fact, configmap_fact with
  | K.Deployment_read deployment_fact, K.Configmap_read configmap_fact ->
    let facts = D.{ deployment = deployment_fact; configmap = configmap_fact } in
    let evidence = List.map E.digest [ deployment; configmap ] in
    let* observation =
      match
        D.Fixture.observe run ~subject:deployment_fact.subject ~evidence (D.Present facts)
      with
      | Ok observation -> Ok observation
      | Error message -> Error { E.stage = "CA observation"; diagnostic = message }
    in
    Ok (D.evaluate (D.Ca_checked (requirement, observation)))
  | _ -> Error E.{ stage = "CA observation"; diagnostic = "wrong resource receipt type" }
;;

let observe_one ~directory ~run ~recorder ~read requirement =
  let deployment_query, configmap_query = K.queries requirement in
  let capture query =
    let observation = K.classify query (read query) in
    E.capture recorder ~subject:query.subject ~payload:(K.encode observation)
  in
  let* deployment = capture deployment_query in
  let* configmap = capture configmap_query in
  let* verdict = evaluate_recorded ~directory ~run ~requirement ~deployment ~configmap in
  let observations = [ deployment; configmap ] in
  let* receipt = E.record_verdict recorder verdict ~observations in
  Ok { verdict; receipt; observations }
;;

let observe_all ~directory ~run ~obligations ~recorder ~read =
  let instances = D.instances obligations in
  let planned = List.map D.plan instances in
  let* () = D.reconcile_plan obligations planned in
  let expected = List.filter (fun i -> D.instance_kind i = D.Ca) instances in
  let requirements =
    List.filter_map
      (function
        | D.Ca_delivery r -> Some r
        | _ -> None)
      planned
  in
  let* () =
    D.reconcile_keys
      ~expected:(List.map D.instance_key expected)
      ~actual:(List.map (fun r -> D.instance_key (D.ca_binding r).instance) requirements)
  in
  if
    expected = []
    || not (List.for_all (fun r -> D.same_run run (D.ca_binding r).run) requirements)
  then Error "CA observation requires a nonempty complete obligation set for this run"
  else (
    let outcomes =
      List.map
        (fun requirement ->
           let instance = (D.ca_binding requirement).instance in
           { instance; result = observe_one ~directory ~run ~recorder ~read requirement })
        requirements
    in
    let* () =
      D.reconcile_keys
        ~expected:(List.map D.instance_key expected)
        ~actual:(List.map (fun outcome -> D.instance_key outcome.instance) outcomes)
    in
    Ok outcomes)
;;
