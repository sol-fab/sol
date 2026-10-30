type outcome =
  | Established
  | Not_declared

(* The authorization root's Terraform state is the durable evidence of whether the
   reconciler identity and its fence were ever established. Current configuration is not:
   a target may have created them and later removed the trust declaration. That must still
   be torn down. *)
type destroy_decision =
  | Never_established
  | Destroy_established
  | Destruction_unknown of string

let destroy_decision ~declared_trust:_ ~state =
  match state with
  | Sol_cli_cloud_destroy.State_empty -> Never_established
  | Sol_cli_cloud_destroy.State_represented _ -> Destroy_established
  | Sol_cli_cloud_destroy.State_unreadable reason -> Destruction_unknown reason
;;

let outcome_to_string = function
  | Established -> "the authorization reconciler identity and its fence are established"
  | Not_declared ->
    "the target declares no authorization reconciler trust principal, so no reconciler \
     identity or fence is created"
;;

let capabilities (target : Sol_cli_config.target) =
  Sol_cli_provider_capabilities.capabilities_of target.provider
;;

let declared_trust = Sol_cli_provider_capabilities.authorization_trust
let root_vars target = (capabilities target).authorization_root_vars target

let with_provider_field (target : Sol_cli_config.target) key value =
  let provider = Sol_cli_provider.to_string target.provider in
  let fields =
    Option.value (List.assoc_opt provider target.provider_fields) ~default:[]
  in
  let fields = (key, value) :: List.remove_assoc key fields in
  let provider_fields =
    (provider, fields) :: List.remove_assoc provider target.provider_fields
  in
  { target with provider_fields }
;;

(* The trust principal is only read by the impersonation member, which is being destroyed.
   When the current configuration no longer declares it, a syntactically valid placeholder
   lets Terraform plan the destruction; the state resource is the thing being removed, and
   no new trust is granted. *)
let destroy_trust_placeholder target =
  (capabilities target).authorization_destroy_trust_placeholder
;;

let destroy_root_vars target =
  match declared_trust target with
  | Some _ -> root_vars target
  | None ->
    let field = (capabilities target).authorization_trust_field in
    root_vars (with_provider_field target field (destroy_trust_placeholder target))
;;

let prepare_root ~assets (target : Sol_cli_config.target) =
  let open Result.Syntax in
  let provider = target.provider in
  let* backend = Sol_cli_cloud_lifecycle.authorization_backend target in
  let dir =
    Sol_cli_terraform_workdir.chdir
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:backend
  in
  let* _ =
    Sol_cli_terraform_workdir.materialize
      ~assets
      ~provider
      ~role:Sol_cli_platform_assets.Authorization
      ~backend_config:backend
  in
  let* () =
    Sol_cli_terraform.init ~chdir:dir ~backend_config:backend ()
    |> Result.map ignore
    |> Result.map_error Sol_cli_process.error_to_string
  in
  Ok (dir, backend)
;;

let prepare ~assets target =
  let open Result.Syntax in
  let* dir, _backend = prepare_root ~assets target in
  let* vars = root_vars target in
  Ok (dir, Sol_cli_terraform.kv_args vars)
;;

let read_state dir =
  match Sol_cli_terraform.show_json ~chdir:dir () with
  | Ok result -> Ok (Sol_cli_cloud_destroy.inventory_of_show_json result.stdout)
  | Error (Sol_cli_process.Non_zero result) ->
    Error
      (Printf.sprintf
         "the authorization root's Terraform state could not be read: terraform show \
          exited %d%s"
         result.exit_code
         (let detail = String.trim result.stderr in
          if detail = "" then "" else ": " ^ detail))
  | Error error ->
    Error
      ("the authorization root's Terraform state could not be read: "
       ^ Sol_cli_process.error_to_string error)
;;

let fence ~assets ~run_log ~target =
  match declared_trust target with
  | None -> Ok Not_declared
  | Some _ ->
    let open Result.Syntax in
    let* dir, vars = prepare ~assets target in
    let addresses = (capabilities target).authorization_fence_addresses in
    let* () =
      Sol_cli_run_log.run_phase run_log ~name:"authorization-fence-apply" (fun () ->
        match addresses with
        | first :: rest ->
          Sol_cli_terraform.apply
            ~scope:(Sol_cli_terraform.targets first rest)
            ~chdir:dir
            ~var_files:[]
            ~vars
            ()
        | [] -> Sol_cli_process.completed ~exit_code:0 ~stdout:"" ~stderr:"")
      |> Result.map ignore
      |> Result.map_error Sol_cli_process.error_to_string
    in
    Ok Established
;;

let apply_serverless_identities ~assets ~run_log ~target units =
  let open Result.Syntax in
  let* dir, _backend = prepare_root ~assets target in
  let* vars = (capabilities target).authorization_serverless_root_vars target units in
  let* () =
    Sol_cli_run_log.run_phase
      run_log
      ~name:"authorization-serverless-identities"
      (fun () ->
         Sol_cli_terraform.apply
           ~scope:Sol_cli_terraform.whole_root
           ~chdir:dir
           ~var_files:[]
           ~vars:(Sol_cli_terraform.kv_args vars)
           ())
    |> Result.map ignore
    |> Result.map_error Sol_cli_process.error_to_string
  in
  let* output =
    Sol_cli_terraform.output_json ~chdir:dir ()
    |> Result.map_error Sol_cli_process.error_to_string
  in
  let* json =
    Sol_cli_json.decode ~what:"authorization outputs" output.stdout
    |> Result.map_error (fun message -> "authorization outputs are invalid: " ^ message)
  in
  match Sol_cli_json.field [ "serverless_service_accounts"; "value" ] json with
  | `Assoc accounts ->
    Ok
      (List.map
         (fun (unit, value) ->
            match value with
            | `String email when String.trim email <> "" -> unit, email
            | _ -> unit, "")
         accounts)
  | _ -> Error "authorization output serverless_service_accounts is not a map"
;;

let verify_destroyed_state state =
  match state with
  | Sol_cli_cloud_destroy.State_empty -> Ok ()
  | State_represented resources ->
    Error
      (Printf.sprintf
         "the authorization root's state still represents %d resource(s) after \
          `terraform destroy`: %s. Terraform's exit status is not evidence that the \
          authorization identities are gone."
         (List.length resources)
         (String.concat
            ", "
            (List.map (fun (r : Sol_cli_cloud_destroy.resource) -> r.address) resources)))
  | State_unreadable reason ->
    Error
      (Printf.sprintf
         "the authorization root's state could not be read after `terraform destroy` \
          (%s), so its absence is not established"
         reason)
;;

type destroy_result =
  { outcome : outcome
  ; identities : (string * string list) list
  }

let identities_of_state ~(target : Sol_cli_config.target) state =
  Sol_cli_provider_registry.authorization_state_identities target.provider ~target state
;;

let destroy_with_identities ~assets ~run_log ~target =
  if Sol_cli_string.is_blank (capabilities target).authorization_trust_field
  then Ok { outcome = Not_declared; identities = [] }
  else
    let open Result.Syntax in
    let* dir, backend = prepare_root ~assets target in
    (* Empty state is only evidence that nothing was established when the previous
       authorization operation is resolved. An interrupted or failed apply may have
       created provider resources without recording them; the existing state guard
       refuses that case instead of letting an empty state claim absence. *)
    let* () =
      Sol_cli_state_guard.check
        ~constructive:true
        ~accept_unresolved:false
        ~chdir:dir
        ~backend_config:backend
      |> Result.map_error (fun message ->
        "the authorization root's state cannot be trusted as evidence: " ^ message)
    in
    let* state = read_state dir in
    match destroy_decision ~declared_trust:(declared_trust target) ~state with
    | Never_established -> Ok { outcome = Not_declared; identities = [] }
    | Destruction_unknown reason -> Error reason
    | Destroy_established ->
      let identities = identities_of_state ~target state in
      let* vars = destroy_root_vars target in
      let* () =
        Sol_cli_run_log.run_phase run_log ~name:"authorization-destroy" (fun () ->
          Sol_cli_terraform.destroy
            ~chdir:dir
            ~var_files:[]
            ~vars:(Sol_cli_terraform.kv_args vars)
            ())
        |> Result.map ignore
        |> Result.map_error Sol_cli_process.error_to_string
      in
      let* state = read_state dir in
      let* () = verify_destroyed_state state in
      Ok { outcome = Established; identities }
;;

let destroy ~assets ~run_log ~target =
  destroy_with_identities ~assets ~run_log ~target
  |> Result.map (fun result -> result.outcome)
;;
