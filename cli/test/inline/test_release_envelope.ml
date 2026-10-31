module E = Sol_cli_release_envelope

let sample kind execution =
  { E.component_kind = kind
  ; component_name = "checkout"
  ; image = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ; execution
  ; runtime_identity = Some "runtime@example.iam.gserviceaccount.com"
  ; provider = "gcp"
  ; provider_detail = `Assoc [ "revision", `String "rev-1" ]
  ; rollback_identity = Some "rev-previous"
  }
;;

let test_roundtrip () =
  List.iter
    (fun (kind, execution) ->
       let value = sample kind execution in
       match E.of_json (E.to_json value) with
       | Error message -> Windtrap.fail message
       | Ok decoded ->
         Windtrap.equal
           Windtrap.string
           ~msg:"component kind roundtrips"
           (E.component_kind_to_string kind)
           (E.component_kind_to_string decoded.component_kind);
         Windtrap.equal
           Windtrap.string
           ~msg:"execution roundtrips"
           (E.execution_to_string execution)
           (E.execution_to_string decoded.execution))
    [ E.Svc, E.Gcp_cloud_run_service
    ; E.Fn, E.Gcp_cloud_run_job
    ; E.Worker, E.Kubernetes_deployment
    ; E.Task, E.Queue_task
    ]
;;

let test_unknown_schema_refused () =
  let json = E.to_json (sample E.Svc E.Gcp_cloud_run_service) in
  match json with
  | `Assoc fields ->
    let json = `Assoc (("schema", `Int 2) :: List.remove_assoc "schema" fields) in
    (match E.of_json json with
     | Error _ -> ()
     | Ok _ -> Windtrap.fail "an unknown release schema was accepted")
  | _ -> Windtrap.fail "release envelope is not an object"
;;

let%test "release envelope roundtrips" = test_roundtrip ()
let%test "release envelope refuses unknown schema" = test_unknown_schema_refused ()
