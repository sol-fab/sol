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

let secret_authorities_for_plan ~config plan =
  let missing = ref [] in
  let mappings = ref [] in
  List.iter
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       let unit_address = spec.domain ^ "/" ^ spec.source_name in
       let transport = Sol_cli_manifest.kafka_transport_of_config spec.config in
       (* 2b: when the unit consumes the target's database, `POSTGRES_URL` is supplied by
          the binding (the target's DML class Secret), not by an authority mapping, so it is
          not demanded here even if the unit also declares it. *)
       let declared =
         if Option.is_some spec.db_uses_target
         then
           List.filter
             (fun key ->
                not (String.equal key Sol_cli_database_setup_render.postgres_url_key))
             (List.map fst spec.secrets)
         else List.map fst spec.secrets
       in
       let required = Sol_cli_manifest.required_secret_keys ~transport declared in
       let resolution =
         Sol_cli_config.resolve_secret_authorities
           config.Sol_cli_config.target
           ~unit_address
           ~required_keys:required
       in
       List.iter
         (fun key -> missing := (unit_address, key) :: !missing)
         resolution.missing;
       List.iter
         (fun (key, authority) -> mappings := (unit_address, key, authority) :: !mappings)
         resolution.resolved)
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
  let* provisioned_database, target_database =
    Sol_cli_resource_binding.resolve config
    |> Result.map (fun bindings ->
      let resource_of (database : Sol_cli_resource_binding.t) = database.resource in
      ( Option.map resource_of (Sol_cli_resource_binding.provisioned_database bindings)
      , Option.map resource_of (Sol_cli_resource_binding.target_database bindings) ))
    |> refused
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
