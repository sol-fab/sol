open Result.Syntax

type selection =
  { resolved : Sol_cli_workload_selection.resolved
  ; image_refs : (string * string) list
  }

let select ~image_refs inventory =
  let* resolved =
    Sol_cli_workload_selection.resolve_nonempty
      ~none:"no services found in app/ with a Dockerfile"
      None
      inventory
  in
  let* image_refs =
    Sol_cli_image_ref.resolve
      ~service_names:
        (List.map (fun (s : Sol_cli_manifest.service) -> s.name) resolved.services)
      image_refs
  in
  Ok { resolved; image_refs }
;;

type deployed =
  { services : Sol_cli_manifest.service list
  ; notes : string list
  }

let unit_id (s : Sol_cli_manifest.service) = Printf.sprintf "%s/%s" s.domain s.name

(* **The one ownership decision**: which inputs a unit must carry, and who owns each. The
   plan gate and `sol secret set` both resolve through it, so neither can reconstruct a
   different answer from the same facts.

   The inputs are the unit's declared application keys, `POSTGRES_URL` when it consumes the
   target's database, and the target's Kafka keys ([required_secret_keys] is the single
   definition of that set). [Target_database] is the delivery the per-key routing already
   names from `db_uses_target`; [Unmapped] is a required key the target maps no authority
   for, which planning refuses and `secret set` cannot write. *)
type input_owner =
  | Unit_secret
  | External_secret of
      { store : string
      ; key : string
      }
  | Target_database
  | Unmapped

let owner_of_authority (authority : Sol_cli_config.secret_authority option) =
  match authority with
  | Some Sol_cli_config.Sol_managed -> Unit_secret
  | Some (Sol_cli_config.External { store; key }) -> External_secret { store; key }
  | None -> Unmapped
;;

let unit_input_owners
      ~(config : Sol_cli_config.t)
      ~unit_address
      ~transport
      ~db_uses_target
      ~declared
  =
  Sol_cli_manifest.required_secret_keys ~transport ~db_uses_target declared
  |> List.map (fun key ->
    if db_uses_target && String.equal key Sol_cli_manifest.postgres_url_key
    then key, Target_database
    else
      ( key
      , owner_of_authority
          (Sol_cli_config.secret_authority config.target ~unit_address ~key) ))
;;

(* Which target database a unit consumes, by `Sol_cli_deployment_plan.db_uses_target` — the
   same function `Sol_cli_deployment_plan.of_services_result` calls to fill
   [spec.db_uses_target], so `sol secret set` resolves the same capability the plan gate
   carries.

   The declaration resolved here is the **workspace** declaration: `db_uses_target` reads
   the unit's `uses:` edge from [Sol_cli_config.declared.services]. The unit's *declared
   secret keys* are a different input — the caller's [declared] to {!check_unit_secret_write}
   — and the two are not interchangeable. *)
let unit_consumes_target_database ~(config : Sol_cli_config.t) ~unit_name =
  let workspace = Sol_cli_config.declared_of_config config in
  match Sol_cli_resource_binding.resolve config with
  | Error _ as error -> error
  | Ok bindings ->
    let target = Sol_cli_kubernetes_name.sanitize_name config.target.name in
    let target_database =
      Option.map
        (fun (database : Sol_cli_resource_binding.t) -> database.resource)
        (Sol_cli_resource_binding.target_database bindings)
    in
    Ok
      (Option.is_some
         (Sol_cli_deployment_plan.db_uses_target
            (Some workspace)
            ~target:(Some target)
            ~target_database
            unit_name))
;;

(* **The `sol secret set` decision for one key.** It refuses a key the unit does not carry,
   a key the target's database binding supplies (the workload reads that from the class
   Secret, so a write to the unit Secret is never read), and a key an external authority
   owns. *)
let check_unit_secret_write
      ~(config : Sol_cli_config.t)
      ~unit_address
      ~unit_name
      ~declared
      ~key
  =
  let* db_uses_target = unit_consumes_target_database ~config ~unit_name in
  let transport =
    Sol_cli_manifest.kafka_transport
      (Sol_cli_profile.platform_shape config.Sol_cli_config.target.profile)
  in
  let owners =
    unit_input_owners ~config ~unit_address ~transport ~db_uses_target ~declared
  in
  match List.assoc_opt key owners with
  | None -> Error (Printf.sprintf "%s/%s is not a declared secret" unit_address key)
  | Some Unit_secret -> Ok ()
  | Some Target_database ->
    Error
      (Printf.sprintf
         "%s/%s is not written by `sol secret set`: this unit consumes the target's \
          database, so the deploy delivers POSTGRES_URL from the target's DML class \
          Secret instead"
         unit_address
         key)
  | Some (External_secret _) ->
    Error
      (Printf.sprintf
         "%s/%s is externally managed; sol secret set cannot write it"
         unit_address
         key)
  | Some Unmapped ->
    Error
      (Printf.sprintf
         "target %s has no authority mapping for %s/%s; add it under \
          targets.<provider>/<region>.secrets in sol/environments.yml"
         config.target.name
         unit_address
         key)
;;

let secret_authorities_for_plan ~config plan =
  let missing = ref [] in
  let mappings = ref [] in
  List.iter
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       let unit_address = spec.domain ^ "/" ^ spec.source_name in
       let transport = Sol_cli_manifest.kafka_transport_of_config spec.config in
       let owners =
         unit_input_owners
           ~config
           ~unit_address
           ~transport
           ~db_uses_target:(Option.is_some spec.db_uses_target)
           ~declared:(List.map fst spec.secrets)
       in
       List.iter
         (fun (key, owner) ->
            match owner with
            | Unmapped -> missing := (unit_address, key) :: !missing
            | Target_database -> ()
            | Unit_secret ->
              mappings := (unit_address, key, Sol_cli_config.Sol_managed) :: !mappings
            | External_secret { store; key = remote } ->
              mappings
              := (unit_address, key, Sol_cli_config.External { store; key = remote })
                 :: !mappings)
         owners)
    plan.Sol_cli_deployment_plan.services;
  match List.rev !missing with
  | (unit_address, key) :: _ ->
    Error
      (Printf.sprintf
         "target %s has no secret authority for %s/%s; declare it under \
          targets.<provider>/<region>.secrets in sol/environments.yml"
         config.Sol_cli_config.target.name
         unit_address
         key)
  | [] -> Ok (List.rev !mappings)
;;

let secret_sources_for_plan ~config plan =
  let* authorities = secret_authorities_for_plan ~config plan in
  let source = function
    | Sol_cli_config.Sol_managed -> Sol_cli_manifest.Sol_managed
    | Sol_cli_config.External { store; key } -> Sol_cli_manifest.External { store; key }
  in
  let services =
    List.map
      (fun (spec : Sol_cli_deployment_plan.service_spec) ->
         let unit_address = spec.domain ^ "/" ^ spec.source_name in
         let secret_sources =
           authorities
           |> List.filter_map (fun (unit, key, authority) ->
             if String.equal unit unit_address then Some (key, source authority) else None)
         in
         { spec with secret_sources })
      plan.Sol_cli_deployment_plan.services
  in
  Ok { plan with services }
;;

let apply_target ~target ~(config : Sol_cli_config.t) selection =
  let* () =
    if Sol_cli_config.target_declared config.target
    then Ok ()
    else
      Error
        (Printf.sprintf
           "target %S is not declared in %s -- sol deploy requires an explicit target, \
            even an empty one, so a typo'd or unintended target can't silently inherit \
            sol.yml's shared defaults and deploy anyway."
           target
           (Sol_cli_config.target_source config.target))
  in
  let omission =
    Sol_cli_workload_selection.apply_omission
      ~is_omitted:(fun s -> Sol_cli_config.is_omitted_service config ~name:s.name)
      selection.resolved
  in
  let notes =
    List.map
      (fun s ->
         Printf.sprintf
           "Note: %s is omitted by target %s, so it is excluded from this deploy."
           (unit_id s)
           target)
      omission.excluded
  in
  let* () =
    match
      selection.image_refs
      |> List.find_map (fun (name, _) ->
        omission.excluded
        |> List.find_opt (fun (s : Sol_cli_manifest.service) -> String.equal s.name name))
    with
    | None -> Ok ()
    | Some s ->
      Error
        (Printf.sprintf
           "--image-ref names %s, which target %s omits, so this whole-target deploy \
            excludes it. Drop the reference."
           s.name
           target)
  in
  match omission.selected with
  | [] ->
    Error
      (Printf.sprintf
         "target %s omits every service, so this whole-target deploy has nothing to \
          deploy: %s."
         target
         (String.concat ", " (List.map unit_id omission.excluded)))
  | services -> Ok { services; notes }
;;

type plan_error =
  | Refused of string
  | Preflight of Sol_cli_profile.t * Sol_cli_profile_preflight.finding list

module Planning_input = struct
  type t =
    { workspace : string
    ; registry : string
    ; sha : string
    ; emit_to : string option
    ; config : Sol_cli_config.t
    ; facts : Sol_cli_workspace_model.t
    ; inventory : Sol_cli_manifest.service list
    ; requested_scope : string
    ; image_refs : (string * string) list
    ; services : Sol_cli_manifest.service list
    }
end

module Target_plan_input = struct
  type t =
    { workspace : string
    ; registry : string
    ; sha : string
    ; emit_to : string option
    ; config : Sol_cli_config.t
    ; facts : Sol_cli_workspace_model.t
    ; inventory : Sol_cli_manifest.service list
    ; image_refs : (string * string) list
    ; services : Sol_cli_manifest.service list
    }
end

module Target_plan = struct
  type t = { deployment_plan : Sol_cli_deployment_plan.t }

  let profile t = t.deployment_plan.profile
  let to_deployment_plan t = t.deployment_plan
end

let plan (input : Planning_input.t) =
  let open Planning_input in
  let { workspace
      ; registry
      ; sha
      ; emit_to
      ; config
      ; facts
      ; inventory
      ; requested_scope
      ; image_refs
      ; services
      }
    =
    input
  in
  let refused r = Result.map_error (fun m -> Refused m) r in
  let* env_target =
    Sol_cli_env_target.customer_cloud_defaults ~registry ~image_tag:sha ~emit_to ()
    |> refused
  in
  let env =
    { (Sol_cli_env_target.to_env_config ~name:workspace env_target) with
      env = Some config.target.env
    ; cluster_issuer =
        Option.value config.target.cluster_issuer ~default:"letsencrypt-prod"
    }
  in
  (* 2d: the plan carries the target's sanitized identity and whether Sol provisions the
     database; the renderer derives any object name from both. 2b adds the target's postgres
     resource whatever its ownership, so a consumer's `POSTGRES_URL` routes to the class
     Secret for a Sol-provisioned and an externally bound database alike. The binding module
     owns *which* resource that is; the plan only carries the names. *)
  let target = Sol_cli_kubernetes_name.sanitize_name config.target.name in
  let* bindings = Sol_cli_resource_binding.resolve config |> refused in
  (* An external binding must be able to deliver every credential class before anything is
     applied; the renderer asks the same extraction, so this check and the delivery cannot
     disagree. *)
  let* () = Sol_cli_database_setup_run.validate_external_bindings bindings |> refused in
  let resource_of (database : Sol_cli_resource_binding.t) = database.resource in
  let provisioned_database =
    Option.map resource_of (Sol_cli_resource_binding.provisioned_database bindings)
  in
  let target_database =
    Option.map resource_of (Sol_cli_resource_binding.target_database bindings)
  in
  let* plan =
    Sol_cli_factory.plan_of_services
      ~workspace
      ~env
      ~facts
      ~requested_scope
      ~declared:(Sol_cli_config.declared_of_config config)
      ~image_refs
      ~inventory
      ~target
      ?target_database
      ?provisioned_database
      services
    |> refused
  in
  let* plan = secret_sources_for_plan ~config plan |> refused in
  let apply_mode =
    match emit_to with
    | Some _ -> Sol_cli_release.Gitops
    | None -> Sol_cli_release.Direct
  in
  let* () =
    Sol_cli_profile_preflight.check ~target:config.target ~apply_mode plan
    |> Result.map_error (fun (profile, findings) -> Preflight (profile, findings))
  in
  Ok plan
;;

let target_plan (input : Target_plan_input.t) =
  let open Target_plan_input in
  let { workspace
      ; registry
      ; sha
      ; emit_to
      ; config
      ; facts
      ; inventory
      ; image_refs
      ; services
      }
    =
    input
  in
  plan
    { Planning_input.workspace
    ; registry
    ; sha
    ; emit_to
    ; config
    ; facts
    ; inventory
    ; requested_scope = "workspace"
    ; image_refs
    ; services
    }
  |> Result.map (fun deployment_plan -> Target_plan.{ deployment_plan })
;;
