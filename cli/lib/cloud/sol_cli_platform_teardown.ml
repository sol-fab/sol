open Result.Syntax

let kinds_of_api_resources text =
  String.split_on_char '\n' text
  |> List.filter_map (fun line ->
    match
      String.split_on_char ' ' (String.trim line)
      |> List.filter (fun field -> field <> "")
      |> List.rev
    with
    | kind :: _ :: _ -> Some kind
    | _ -> None)
  |> List.sort_uniq compare
;;

let served_api_kinds env =
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         ~env
         [ "kubectl"; "api-resources"; "--verbs=delete"; "--no-headers" ])
  with
  | Ok result -> Ok (kinds_of_api_resources result.stdout)
  | Error (Sol_cli_process.Non_zero result) ->
    Error
      (Printf.sprintf
         "kubectl api-resources exited %d: %s"
         result.exit_code
         (String.trim result.stderr))
  | Error error -> Error (Sol_cli_process.error_to_string error)
;;

let unserved_of_show_json ~served text =
  let field path json =
    Sol_cli_json.field path json
    |> Sol_cli_json.string
    |> Fun.flip Option.bind Sol_cli_string.non_blank
  in
  let unserved resource =
    if field [ "type" ] resource <> Some "kubernetes_manifest"
    then None
    else (
      let kind =
        match field [ "values"; "manifest"; "kind" ] resource with
        | Some _ as kind -> kind
        | None -> field [ "values"; "object"; "kind" ] resource
      in
      match kind, field [ "address" ] resource with
      | Some kind, Some address when not (List.mem kind served) -> Some (address, kind)
      | _ -> None)
  in
  match Sol_cli_json.decode_sensitive ~what:"terraform show -json" text with
  | Error message -> Error message
  | Ok json ->
    let rec collect acc module_json =
      let* acc =
        match Sol_cli_json.field [ "resources" ] module_json with
        | `Null -> Ok acc
        | `List resources -> Ok (List.rev_append (List.filter_map unserved resources) acc)
        | _ -> Error "unexpected `terraform show -json` resources shape"
      in
      match Sol_cli_json.field [ "child_modules" ] module_json with
      | `Null -> Ok acc
      | `List children ->
        List.fold_left
          (fun acc child ->
             let* acc = acc in
             collect acc child)
          (Ok acc)
          children
      | _ -> Error "unexpected `terraform show -json` child_modules shape"
    in
    (match Sol_cli_json.field [ "values" ] json with
     | `Null -> Ok []
     | values ->
       (match Sol_cli_json.field [ "root_module" ] values with
        | `Null -> Ok []
        | root -> Result.map List.rev (collect [] root)))
;;

let unserved_manifest_resources ~served ~chdir =
  match Sol_cli_terraform.show_json ~chdir () with
  | Ok result -> unserved_of_show_json ~served result.stdout
  | Error (Sol_cli_process.Non_zero result) ->
    Error (Printf.sprintf "terraform show exited %d" result.exit_code)
  | Error error -> Error (Sol_cli_process.error_to_string error)
;;

let platform_namespaces =
  [ "cert-manager"
  ; "ingress-nginx"
  ; "argocd"
  ; "redpanda"
  ; Sol_cli_manifest.monitoring_namespace
  ; "postgresql"
  ]
;;

(* One platform namespace's state, from an explicit classification of the read rather than from
   its exit status:

     - PRESENT: the read succeeded and named the namespace.
     - ABSENT: the API server answered NotFound, which is a positive observation that the
       namespace object is not there.
     - UNKNOWN: anything else -- refused, unauthorized, timed out, unreachable, unlaunchable, or
       a successful read that did not name the namespace. A failed read is not absence.

   This verification runs after the platform destroy and its answer is what lets the destroy
   claim absence, so reading an unreadable namespace as a namespace that is gone is a false
   success (sol-fab/sol#1497). Kubernetes evaluates RBAC for the resource before object lookup,
   so an identity without a grant in the namespace answers Forbidden; only NotFound establishes
   that nothing is there. *)
type namespace_state =
  | Namespace_present
  | Namespace_absent
  | Namespace_unknown of string

let namespace_state ~env namespace =
  let args = [ "kubectl"; "get"; "namespace"; namespace; "-o"; "name" ] in
  match Sol_cli_process.run (Sol_cli_process.cmd ~env args) with
  | Error error ->
    (match Sol_cli_kubectl.classify error with
     | Sol_cli_kubectl.Not_found -> Namespace_absent
     | _ -> Namespace_unknown (Sol_cli_process.error_to_string error))
  | Ok (answered : Sol_cli_process.output) ->
    let printed = String.trim answered.stdout in
    let expected = Printf.sprintf "namespace/%s" namespace in
    if String.equal printed expected
    then Namespace_present
    else
      Namespace_unknown
        (Printf.sprintf "the read answered %S rather than %S" printed expected)
;;

let verify_absent ~env =
  let rec go = function
    | [] -> Ok ()
    | namespace :: rest ->
      (match namespace_state ~env namespace with
       | Namespace_absent -> go rest
       | Namespace_present ->
         Error (Printf.sprintf "namespace %s is still there" namespace)
       | Namespace_unknown reason ->
         Error
           (Printf.sprintf
              "whether namespace %s is gone could not be established: %s"
              namespace
              reason))
  in
  go platform_namespaces
;;

let absent env =
  match verify_absent ~env with
  | Ok () -> true
  | Error _ -> false
;;

let terraform_outcome = Sol_cli_terraform_steps.terraform_outcome

let destroy ~run_log ~env ~chdir ~vars =
  let destroy_once () = Sol_cli_terraform.destroy ~env ~chdir ~var_files:[] ~vars () in
  let destroy = Sol_cli_run_log.run_phase run_log ~name:"platform-destroy" destroy_once in
  let verify_absent () =
    match verify_absent ~env with
    | Ok () -> Ok ()
    | Error reason ->
      Error
        (Printf.sprintf "platform absence verification failed after destroy: %s" reason)
  in
  match destroy with
  | Ok _ -> verify_absent ()
  | _ ->
    (match served_api_kinds env with
     | Error message ->
       Sol_cli_report.err
         "error: the platform destroy failed, and the recovery step could not determine \
          which kinds the cluster serves: %s"
         message;
       terraform_outcome destroy
     | Ok served ->
       (match unserved_manifest_resources ~served ~chdir with
        | Error message ->
          Sol_cli_report.err
            "error: the platform destroy failed, and the recovery step could not read \
             the platform state: %s"
            message;
          terraform_outcome destroy
        | Ok [] -> terraform_outcome destroy
        | Ok unserved ->
          Sol_cli_report.app
            "\n\
            \  platform destroy could not delete %d resource(s) whose kind this cluster \
             does not serve, so they cannot exist;\n\
            \  forgetting them in state (the objects, not the objects' absence, is what \
             Terraform cannot address):"
            (List.length unserved);
          let* () =
            List.fold_left
              (fun acc (address, kind) ->
                 let* () = acc in
                 Sol_cli_report.app
                   "    %s (%s is not served by this cluster)"
                   address
                   kind;
                 terraform_outcome
                   (Sol_cli_run_log.run_phase
                      run_log
                      ~name:"platform-destroy-forget-unserved"
                      (fun () -> Sol_cli_terraform.state_rm ~env ~chdir ~address ())))
              (Ok ())
              unserved
          in
          let retry =
            Sol_cli_run_log.run_phase run_log ~name:"platform-destroy-retry" destroy_once
          in
          (match retry with
           | Ok _ -> verify_absent ()
           | _ -> terraform_outcome retry)))
;;
