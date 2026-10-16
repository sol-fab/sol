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

let capture_query recorder read (query : K.query) =
  E.capture
    recorder
    ~subject:query.subject
    ~payload:(K.encode (K.classify query (read query)))
;;

let record recorder verdict observations =
  let* receipt = E.record_verdict recorder verdict ~observations in
  Ok { verdict; receipt; observations }
;;

(* The same exact-family accounting applies to consumer and migration CA. Typed
   dispatch below differs only because migrations additionally require execution. *)
let observe_family ~run ~obligations ~kind ~observe =
  let instances = D.instances obligations in
  let planned = List.map D.plan instances in
  let* () = D.reconcile_plan obligations planned in
  let expected = List.filter (fun i -> D.instance_kind i = kind) instances in
  if
    expected = []
    || not (List.for_all (fun i -> D.same_run run (D.instance_run i)) expected)
  then Error "CA observation requires complete nonempty family obligations for this run"
  else (
    let outcomes =
      List.map (fun instance -> { instance; result = observe (D.plan instance) }) expected
    in
    let* () =
      D.reconcile_keys
        ~expected:(List.map D.instance_key expected)
        ~actual:(List.map (fun o -> D.instance_key o.instance) outcomes)
    in
    Ok outcomes)
;;

let observe_one ~directory ~run ~recorder ~read requirement =
  let deployment_query, configmap_query = K.queries requirement in
  let* deployment = capture_query recorder read deployment_query in
  let* configmap = capture_query recorder read configmap_query in
  let* verdict = evaluate_recorded ~directory ~run ~requirement ~deployment ~configmap in
  record recorder verdict [ deployment; configmap ]
;;

let observe_all ~directory ~run ~obligations ~recorder ~read =
  observe_family ~run ~obligations ~kind:D.Ca ~observe:(function
    | D.Ca_delivery requirement -> observe_one ~directory ~run ~recorder ~read requirement
    | _ -> Error E.{ stage = "CA observation"; diagnostic = "wrong request family" })
;;

(* The execution receipt is a separate producer input, not a reconstructed Job name.
   Only fixture capture is installed until the product execution boundary is reviewed. *)
let decode_execution (captured : E.captured) =
  let json = captured.payload in
  let field key =
    match json with
    | `Assoc xs -> List.assoc_opt key xs
    | _ -> None
  in
  let text key =
    match field key with
    | Some (`String s) when String.trim s <> "" -> Ok s
    | _ -> Error { E.stage = "migration execution"; diagnostic = "missing " ^ key }
  in
  let* _ =
    match D.canonical_json json with
    | Ok text -> Ok text
    | Error diagnostic -> Error { E.stage = "migration execution"; diagnostic }
  in
  let* () =
    if
      field "schema" = Some (`Int 1) && field "kind" = Some (`String "MigrationExecution")
    then Ok ()
    else Error E.{ stage = "migration execution"; diagnostic = "unsupported receipt" }
  in
  let* requirement = text "requirement" in
  let* namespace = text "namespace" in
  let* name = text "name" in
  let* uid = text "uid" in
  let* context =
    match field "context" with
    | Some json ->
      (match D.read_context_of_json json with
       | Ok c -> Ok c
       | Error diagnostic -> Error { E.stage = "migration execution"; diagnostic })
    | None -> Error E.{ stage = "migration execution"; diagnostic = "missing context" }
  in
  Ok
    D.
      { requirement
      ; subject = captured.subject
      ; context
      ; state = Present { namespace; name; uid }
      }
;;

module Fixture = struct
  let capture_execution recorder requirement ~context (identity : D.job_identity) =
    let b = D.migration_ca_binding requirement in
    E.capture
      recorder
      ~subject:b.subject
      ~payload:
        (`Assoc
            [ "schema", `Int 1
            ; "kind", `String "MigrationExecution"
            ; "requirement", `String (D.instance_identity b.instance)
            ; "context", D.read_context_json context
            ; "namespace", `String identity.namespace
            ; "name", `String identity.name
            ; "uid", `String identity.uid
            ])
  ;;
end

let evaluate_migration_recorded ~directory ~run ~requirement ~execution ~job ~configmap =
  let* captured = E.read_capture ~directory ~run execution in
  let* execution_fact = decode_execution captured in
  let* job_fact = decode directory run job in
  let* configmap_fact = decode directory run configmap in
  match job_fact, configmap_fact with
  | K.Job_read job_fact, K.Configmap_read configmap_fact ->
    let facts =
      D.{ execution = execution_fact; job = job_fact; configmap = configmap_fact }
    in
    let evidence = List.map E.digest [ execution; job; configmap ] in
    let* observation =
      match
        D.Fixture.observe run ~subject:execution_fact.subject ~evidence (D.Present facts)
      with
      | Ok observation -> Ok observation
      | Error diagnostic -> Error { E.stage = "migration CA observation"; diagnostic }
    in
    Ok (D.evaluate (D.Migration_ca_checked (requirement, observation)))
  | _ ->
    Error
      E.{ stage = "migration CA observation"; diagnostic = "wrong resource receipt type" }
;;

let observe_migration_one ~directory ~run ~recorder ~read ~execution requirement =
  let* execution = execution requirement in
  let* captured = E.read_capture ~directory ~run execution in
  let* fact = decode_execution captured in
  let* identity =
    match fact.state with
    | D.Present identity -> Ok identity
    | _ ->
      Error
        E.{ stage = "migration execution"; diagnostic = "execution identity unavailable" }
  in
  let job_query, configmap_query = K.migration_queries requirement identity in
  let* job = capture_query recorder read job_query in
  let* configmap = capture_query recorder read configmap_query in
  let* verdict =
    evaluate_migration_recorded ~directory ~run ~requirement ~execution ~job ~configmap
  in
  record recorder verdict [ execution; job; configmap ]
;;

let observe_migrations ~directory ~run ~obligations ~recorder ~read ~execution =
  observe_family ~run ~obligations ~kind:D.Migration_ca ~observe:(function
    | D.Migration_ca_delivery requirement ->
      observe_migration_one ~directory ~run ~recorder ~read ~execution requirement
    | _ ->
      Error E.{ stage = "migration CA observation"; diagnostic = "wrong request family" })
;;
