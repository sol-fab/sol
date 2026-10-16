(* Project before capture: full Deployments may contain literal credentials.
   These templates retain only the independently observed fields the claim uses. *)
let configmap_output =
  {|go-template={
  "apiVersion": "{{.apiVersion}}", "kind": "{{.kind}}",
  "metadata": {"name": "{{.metadata.name}}", "namespace": "{{.metadata.namespace}}"},
  "ca_present": {{if .data}}{{if index .data "ca.crt"}}true{{else}}false{{end}}{{else}}false{{end}}
}|}
;;

let deployment_output =
  {|go-template={
  "apiVersion": "{{.apiVersion}}", "kind": "{{.kind}}",
  "metadata": {"name": "{{.metadata.name}}", "namespace": "{{.metadata.namespace}}"},
  "spec": {"template": {"spec": {"volumes": [
    {{$sep := ""}}{{range .spec.template.spec.volumes}}{{$sep}}
    {"name": "{{.name}}", "configMap": {"name": "{{if .configMap}}{{.configMap.name}}{{end}}"}}
    {{$sep = ","}}{{end}}
  ]}}}
}|}
;;

let () =
  let deploy_log = ref ""
  and target = ref ""
  and kubeconfig = ref "" in
  let evidence = ref ""
  and kubectl = ref "kubectl"
  and bound = ref 30. in
  let consumers = ref [] in
  let options =
    [ "--deploy-log", Arg.Set_string deploy_log, "PATH final deploy output"
    ; "--target", Arg.Set_string target, "TARGET expected declaration target"
    ; "--kubeconfig", Arg.Set_string kubeconfig, "PATH explicit observation identity"
    ; "--evidence", Arg.Set_string evidence, "PATH new evidence directory"
    ; ( "--kubectl"
      , Arg.Set_string kubectl
      , "PATH kubectl executable (offline adapter in tests)" )
    ; "--timeout", Arg.Set_float bound, "SECONDS per observation"
    ; ( "--consumer"
      , Arg.String (fun s -> consumers := s :: !consumers)
      , "NAMESPACE/DEPLOYMENT repeat for each selected database consumer" )
    ]
  in
  let usage = "Internal database CA contract prototype (read-only, opt-in)" in
  Arg.parse options (fun _ -> raise (Arg.Bad usage)) usage;
  let required = [ !deploy_log; !target; !kubeconfig; !evidence ] in
  if List.exists (( = ) "") required || (not (Float.is_finite !bound)) || !bound <= 0.
  then (
    prerr_endline
      "required: --deploy-log --target --kubeconfig --evidence and positive finite \
       --timeout";
    exit 2);
  let locations =
    List.rev_map
      (fun value ->
         match String.split_on_char '/' value with
         | [ namespace; name ] when namespace <> "" && name <> "" ->
           Database_ca.{ namespace; name }
         | _ ->
           prerr_endline "consumer must be NAMESPACE/DEPLOYMENT";
           exit 2)
      !consumers
  in
  try
    (* Refuse reuse instead of allowing stale evidence to masquerade as this run. *)
    Unix.mkdir !evidence 0o700;
    let index = ref 0 in
    let observations = ref [] in
    let module Observer = struct
      let read resource (location : Database_ca.location) =
        incr index;
        let kind, output =
          match resource with
          | Database_ca.Configmap -> "configmap", configmap_output
          | Deployment -> "deployment", deployment_output
        in
        let execution =
          Command.run
            ~directory:!evidence
            ~index:!index
            { program = !kubectl
            ; args =
                [ "--kubeconfig"
                ; !kubeconfig
                ; "get"
                ; kind
                ; location.name
                ; "--namespace"
                ; location.namespace
                ; "--ignore-not-found=true"
                ; "-o"
                ; output
                ]
            ; timeout_s = !bound
            }
        in
        observations
        := `Assoc
             [ "resource", `String kind
             ; "namespace", `String location.namespace
             ; "name", `String location.name
             ; "execution", `String (Filename.basename execution.record_path)
             ]
           :: !observations;
        match execution.outcome with
        | Completed 0 ->
          let stdout = Command.read execution.stdout_path |> String.trim in
          if stdout = ""
          then Database_ca.Absent
          else (
            try Present (Yojson.Safe.from_string stdout) with
            | Yojson.Json_error _ -> Unreadable "observation output is not JSON")
        | Completed code ->
          Unreadable
            (Printf.sprintf
               "observer exited %d; see %s"
               code
               (Filename.basename execution.stderr_path))
        | Timed_out ->
          Unreadable ("observer timed out; see " ^ Filename.basename execution.stderr_path)
        | Unavailable reason -> Unreadable reason
      ;;
    end
    in
    let module Qualification = Database_ca.Make (Observer) in
    let declaration =
      try Database_ca.declaration ~target:!target (Command.read !deploy_log) with
      | Sys_error reason -> Error reason
    in
    let claims = Qualification.run ~declaration ~consumers:locations in
    let passed, report =
      Contract.report
        ~context:
          [ "target", `String !target
          ; "kubeconfig", `String !kubeconfig
          ; "observer", `String !kubectl
          ; "timeout_s", `Float !bound
          ; "observations", `List (List.rev !observations)
          ]
        claims
    in
    Command.write_json (Filename.concat !evidence "report.json") report;
    List.iter
      (fun (c : Contract.claim) ->
         Printf.printf "%s %s\n" (Contract.verdict_name c.verdict) c.id)
      claims;
    exit (if passed then 0 else 1)
  with
  | Unix.Unix_error (error, fn, _) ->
    prerr_endline (fn ^ ": " ^ Unix.error_message error);
    exit 2
  | Sys_error reason ->
    prerr_endline reason;
    exit 2
;;
