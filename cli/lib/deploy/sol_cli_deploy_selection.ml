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
   names from `db_uses_target`; [Target_kafka] is the delivery the deploy writes from the
   resolved managed Kafka authority, so it is resource-owned rather than an application
   secret; [External_secret] is the binding's explicitly declared external-store key;
   [Unmapped] is a required key no current binding supplies, which planning refuses and
   `secret set` cannot write.

   The reader side of this decision is `Sol_cli_manifest_yaml.secret_name_for_key`;
   [Sol_cli_manifest.required_secret_keys] is the third leg (which keys exist). *)
type input_owner =
  | Unit_secret
  | External_secret of
      { store : string
      ; key : string
      }
  | Target_database
  | Target_kafka of { secret : string }
  | Conflicting
  | Unmapped

let owner_of_authority (authority : Sol_cli_config.secret_authority option) =
  match authority with
  | Some Sol_cli_config.Sol_managed -> Unit_secret
  | Some (Sol_cli_config.External { store; key }) -> External_secret { store; key }
  | None -> Unmapped
;;

(* A Kafka key the resolved binding supplies cannot also have an application authority
   mapping: two producers for one delivered value is the conflicting-writer shape the
   credential contract forbids. With no Kafka binding the application mapping is the
   authority, as before. *)
let kafka_key_owner ~(config : Sol_cli_config.t) ~unit_address kafka key =
  let declared = Sol_cli_config.secret_authority config.target ~unit_address ~key in
  let target = Sol_cli_kubernetes_name.sanitize_name config.target.name in
  match
    ( List.assoc_opt key (Sol_cli_resource_binding.kafka_secret_sources ~target kafka)
    , declared )
  with
  | Some _, Some _ -> Conflicting
  | Some (Sol_cli_secret_source.Target_kafka { secret }), None -> Target_kafka { secret }
  | Some (Sol_cli_secret_source.External { store; key }), None ->
    External_secret { store; key }
  | Some Sol_cli_secret_source.Sol_managed, _ | None, _ -> owner_of_authority declared
;;

let unit_input_owners
      ~(config : Sol_cli_config.t)
      ~kafka
      ~unit_address
      ~transport
      ~db_uses_target
      ~declared
  =
  let kafka_keys = Sol_cli_manifest.kafka_required_secret_keys transport in
  Sol_cli_manifest.required_secret_keys ~transport ~db_uses_target declared
  |> List.map (fun key ->
    if db_uses_target && String.equal key Sol_cli_manifest.postgres_url_key
    then key, Target_database
    else if List.mem key kafka_keys
    then key, kafka_key_owner ~config ~unit_address kafka key
    else
      ( key
      , owner_of_authority
          (Sol_cli_config.secret_authority config.target ~unit_address ~key) ))
;;

(* Secret writes and planning use the same resolved selection and declared uses.
   Declaring a POSTGRES_URL secret alone does not make a unit a database consumer. *)
let unit_consumes_target_database ~(config : Sol_cli_config.t) ~unit_name =
  let workspace = Sol_cli_config.declared_of_config config in
  let* database = Sol_cli_resource_binding.resolve_postgres config in
  let target = Sol_cli_kubernetes_name.sanitize_name config.target.name in
  Ok
    (Option.is_some
       (Sol_cli_resource_binding.postgres_use_target
          (Sol_cli_deployment_plan.database_for_uses
             ~target:(Some target)
             ~database
             (Sol_cli_deployment_plan.declared_uses (Some workspace) unit_name))))
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
  let* platform_shape = Sol_cli_config.platform_shape config in
  let transport = Sol_cli_manifest.kafka_transport platform_shape in
  let* kafka = Sol_cli_resource_binding.resolve_kafka config in
  let kafka = Sol_cli_resource_binding.kafka_for_shape ~shape:platform_shape kafka in
  let owners =
    unit_input_owners ~config ~kafka ~unit_address ~transport ~db_uses_target ~declared
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
  | Some (Target_kafka _) ->
    Error
      (Printf.sprintf
         "%s/%s is delivered by the target's Kafka authority; the deploy writes it and \
          `sol secret set` cannot override it"
         unit_address
         key)
  | Some Conflicting ->
    Error
      (Printf.sprintf
         "target %s maps %s/%s, but its Kafka binding already owns that delivered value; \
          remove the application authority mapping"
         config.target.name
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

let secret_authorities_for_plan
      ~(config : Sol_cli_config.t)
      (plan : Sol_cli_deployment_plan.t)
  =
  let missing = ref [] in
  let mappings = ref [] in
  let conflicts = ref [] in
  List.iter
    (fun (spec : Sol_cli_deployment_plan.service_spec) ->
       let unit_address = spec.domain ^ "/" ^ spec.source_name in
       let transport = Sol_cli_manifest.kafka_transport_of_config spec.config in
       let owners =
         unit_input_owners
           ~config
           ~kafka:plan.kafka
           ~unit_address
           ~transport
           ~db_uses_target:
             (Option.is_some (Sol_cli_resource_binding.postgres_use_target spec.database))
           ~declared:(List.map fst spec.secrets)
       in
       List.iter
         (fun (key, owner) ->
            match owner with
            | Unmapped -> missing := (unit_address, key) :: !missing
            | Conflicting -> conflicts := (unit_address, key) :: !conflicts
            | Target_database -> ()
            | Target_kafka { secret } ->
              mappings
              := (unit_address, key, Sol_cli_secret_source.Target_kafka { secret })
                 :: !mappings
            | Unit_secret ->
              mappings
              := (unit_address, key, Sol_cli_secret_source.Sol_managed) :: !mappings
            | External_secret { store; key = remote } ->
              mappings
              := ( unit_address
                 , key
                 , Sol_cli_secret_source.External { store; key = remote } )
                 :: !mappings)
         owners)
    plan.Sol_cli_deployment_plan.services;
  match List.rev !conflicts with
  | (unit_address, key) :: _ ->
    Error
      (Printf.sprintf
         "target %s maps %s/%s, but its Kafka binding already owns that delivered value; \
          remove the application authority mapping"
         config.Sol_cli_config.target.name
         unit_address
         key)
  | [] ->
    (match List.rev !missing with
     | (unit_address, key) :: _ ->
       Error
         (Printf.sprintf
            "target %s has no secret authority for %s/%s; declare it under \
             targets.<provider>/<region>.secrets in sol/environments.yml"
            config.Sol_cli_config.target.name
            unit_address
            key)
     | [] -> Ok (List.rev !mappings))
;;

let secret_sources_for_plan ~config plan =
  let* authorities = secret_authorities_for_plan ~config plan in
  let services =
    List.map
      (fun (spec : Sol_cli_deployment_plan.service_spec) ->
         let unit_address = spec.domain ^ "/" ^ spec.source_name in
         let secret_sources =
           authorities
           |> List.filter_map (fun (unit, key, source) ->
             if String.equal unit unit_address then Some (key, source) else None)
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

let declaration_plan (input : Planning_input.t) =
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
  (* Resolve the database once; identity, consumer routing, trust and external
     delivery are projections of this selection. *)
  let target = Sol_cli_kubernetes_name.sanitize_name config.target.name in
  let* database = Sol_cli_resource_binding.resolve_postgres config |> refused in
  let* kafka = Sol_cli_resource_binding.resolve_kafka config |> refused in
  (* A GitOps emit cannot run the database setup step, so it cannot deliver a database Sol
     provisions. Refuse it here, keyed on the binding rather than on a profile, so the
     ownership matrix is established by the deploy contract and not by whichever profile a
     target happens to select. An externally bound database emits its class Secrets from the
     plan's resource delivery below. *)
  let* () =
    (match emit_to, database with
     | Some _, Sol_cli_resource_binding.Managed_postgres resource ->
       Error
         (Printf.sprintf
            "target %s cannot emit a GitOps bundle: it provisions database %S, whose \
             setup Job and class credentials run during a direct apply. Bind the \
             database externally to emit it, or deploy this target directly."
            config.target.name
            resource)
     | _ -> Ok ())
    |> refused
  in
  let* platform_shape = Sol_cli_config.platform_shape config |> refused in
  let kafka = Sol_cli_resource_binding.kafka_for_shape ~shape:platform_shape kafka in
  (* Managed Kafka's credential is read from the provider and written to the broker
     delivery Secret during a direct apply. A GitOps bundle cannot materialize that
     confidential value, so emitting one would render a reference that nothing delivers. *)
  let* () =
    (match emit_to, kafka with
     | Some _, Sol_cli_resource_binding.Managed_kafka resource ->
       Error
         (Printf.sprintf
            "target %s cannot emit a GitOps bundle: it provisions Kafka %S, whose \
             provider-backed credential and broker delivery run during a direct apply. \
             Bind Kafka externally to emit it, or deploy this target directly."
            config.target.name
            resource)
     | _ -> Ok ())
    |> refused
  in
  let* plan =
    Sol_cli_factory.plan_of_services
      ~workspace
      ~env
      ~facts
      ~requested_scope
      ~declared:(Sol_cli_config.declared_of_config config)
      ~platform_shape
      ~image_refs
      ~inventory
      ~target
      ~database
      ~kafka
      services
    |> refused
  in
  let* plan = secret_sources_for_plan ~config plan |> refused in
  (* **The target-scoped delivery** of an externally bound database, resolved once from the
     binding. Direct apply and the GitOps emit render the class ExternalSecrets from this
     same value, so they cannot name different objects; a binding that cannot deliver every
     class is refused here, before anything is applied. *)
  let* plan =
    match database with
    | Sol_cli_resource_binding.External_postgres binding ->
      let declared = Sol_cli_config.declared_of_config config in
      let dml_namespaces =
        Sol_cli_database_setup_run.dml_namespaces ~declared:(Some declared) ~database plan
      in
      let database_identity =
        Sol_cli_database_setup_run.identity ~workspace ~config ~database
      in
      let resource_delivery =
        Sol_cli_database_setup_run.resource_delivery
          ~target:database_identity.Sol_cli_database_setup_render.target
          ~resource:database_identity.Sol_cli_database_setup_render.resource
          ~migration_namespace:
            (Sol_cli_database_setup_render.database_namespace database_identity)
          ~dml_namespaces
          binding
      in
      Ok { plan with Sol_cli_deployment_plan.resource_delivery = Some resource_delivery }
    | _ -> Ok plan
  in
  Ok plan
;;

let plan ?(evaluation = Sol_cli_profile_preflight.All) (input : Planning_input.t) =
  let* plan = declaration_plan input in
  let apply_mode =
    match input.emit_to with
    | Some _ -> Sol_cli_release.Gitops
    | None -> Sol_cli_release.Direct
  in
  let* () =
    Sol_cli_profile_preflight.check
      ~evaluation
      ~target:input.config.target
      ~apply_mode
      plan
    |> Result.map_error (fun (profile, findings) -> Preflight (profile, findings))
  in
  Ok plan
;;

let target_plan
      ?(evaluation = Sol_cli_profile_preflight.All)
      (input : Target_plan_input.t)
  =
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
    ~evaluation
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
