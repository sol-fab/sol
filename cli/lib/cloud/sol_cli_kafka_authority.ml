open Result.Syntax

type reference =
  { resource : string
  ; reference : string
  ; username : string
  ; mechanism : string
  }

let reference_of_json text =
  let* json = Sol_cli_json.decode_sensitive ~what:"Kafka authority reference" text in
  let field name =
    Sol_cli_json.require ~what:"Kafka authority" [ name ] Sol_cli_json.string json
  in
  let* resource = field "resource" in
  let* reference = field "reference" in
  let* username = field "username" in
  let* mechanism = field "mechanism" in
  if List.exists Sol_cli_string.is_blank [ resource; reference; username; mechanism ]
  then Error "the Kafka authority reference contains an empty identity/posture field"
  else Ok { resource; reference; username; mechanism }
;;

let reference_json reference =
  `Assoc
    [ "resource", `String reference.resource
    ; "reference", `String reference.reference
    ; "username", `String reference.username
    ; "mechanism", `String reference.mechanism
    ]
;;

let reference_output outputs =
  let* value = Sol_cli_terraform_outputs.raw outputs ~name:"kafka_authority" in
  match value with
  | None -> Ok None
  | Some text ->
    let* reference = reference_of_json text in
    (* Project the typed public fields. Never forward unknown producer fields
       into CLI arguments merely because the required metadata parsed. *)
    Ok (Some (Yojson.Safe.to_string (reference_json reference)))
;;

let check_reference ~resource text =
  let* reference = reference_of_json text in
  if
    reference.resource <> resource
    || reference.username <> Sol_cli_manifest_cluster_env.kafka_sasl_username
    || reference.mechanism <> Sol_cli_manifest_cluster_env.kafka_sasl_mechanism
  then
    Error
      "the recorded Kafka authority does not match the selected resource and \
       authentication contract"
  else Ok reference
;;

(* A create action is not proof of a fresh installation. In particular, forgetting
   random_password while keeping a broker must not rotate that broker on repair. *)
type generation =
  | Reuse
  | Initialize

type authority_resources =
  { secret : string
  ; version : string
  }

let generation ~resources ~managed changes =
  let action address =
    List.find_opt
      (fun (change : Sol_cli_terraform_plan.change) ->
         Sol_cli_terraform_plan.same_resource change.address address)
      changes
    |> Option.map (fun (change : Sol_cli_terraform_plan.change) -> change.action)
  in
  let random = action "random_password.kafka" in
  let secret = action resources.secret in
  let version = action resources.version in
  match managed, random, secret, version with
  | false, None, None, None -> Ok Reuse
  (* An update to the secret container is metadata-only; the version still has to
     be unchanged. *)
  | true, Some No_op, Some (No_op | Update), Some No_op -> Ok Reuse
  (* A retry after a partial first apply reuses the generator value already in
     state and only finishes the missing authority objects. This is not rotation:
     the broker/storage absence check still has to hold before it is accepted. *)
  | true, (Some No_op | Some Create), Some Create, Some Create -> Ok Initialize
  | _ ->
    Error
      "Kafka generation or authority state is missing or would be replaced. Restore the \
       recorded credential authority/state before deployment; automatic rotation and \
       implicit authority recreation are unsupported."
;;

type authority_state =
  | Authority_current
  | Authority_missing of string
  | Authority_unobservable of string

let check_reuse_authority = function
  | Authority_current -> Ok ()
  | Authority_missing detail ->
    Error
      (Printf.sprintf
         "the Kafka credential authority is not current (%s). Restore the recorded \
          provider secret and its active version; automatic regeneration is unsupported."
         detail)
  | Authority_unobservable detail ->
    Error
      (Printf.sprintf
         "the Kafka credential authority could not be observed (%s). Refusing to reuse a \
          credential whose provider secret and active version are unknown."
         detail)
;;

type initialization_evidence =
  { broker : Sol_cli_absence.observation
  ; storage : Sol_cli_absence.observation
  ; authority : Sol_cli_absence.observation
  }

let check_initial_absence { broker; storage; authority } =
  let rec check = function
    | [] -> Ok ()
    | Sol_cli_absence.Absent _ :: rest -> check rest
    | Sol_cli_absence.Present present :: _ ->
      Error
        ("Kafka initialization refused: surviving "
         ^ present.resource_class
         ^ "; restore the existing credential authority rather than generating a \
            replacement")
    | Sol_cli_absence.Unobservable unknown :: _ ->
      Error
        ("Kafka initialization cannot establish absence of "
         ^ unknown.resource_class
         ^ ": "
         ^ unknown.reason)
    | Sol_cli_absence.External excluded :: _ ->
      Error
        ("Kafka initialization requires positive absence, not an excluded "
         ^ excluded.resource_class)
    | Sol_cli_absence.Not_attributable unknown :: _ ->
      Error
        ("Kafka initialization cannot attribute "
         ^ unknown.resource_class
         ^ ": "
         ^ unknown.reason)
  in
  check [ broker; storage; authority ]
;;

(* Terraform refresh compares the existing broker projection with the durable
   authority. Creation recovers delivery after cluster replacement; changing an
   existing projection would be implicit rotation, which is outside this contract. *)
let broker_projection_policy : Sol_cli_terraform_plan.policy =
  { phase = "Kafka credential delivery"
  ; rules =
      [ { matches = [ Resource "module.platform.kubernetes_secret_v1.redpanda_users" ]
        ; allows = [ Create ]
        ; reason =
            "create a missing delivery object without changing a surviving broker's \
             credential"
        }
      ]
  }
;;

(* The actual full-platform execution plan enforces the same immutable projection
   boundary. An earlier targeted check is not permission for a later update. *)
let platform_policy : Sol_cli_terraform_plan.policy =
  { phase = "platform reconciliation"
  ; rules =
      broker_projection_policy.rules
      @ [ { matches =
              [ Except (Resource "module.platform.kubernetes_secret_v1.redpanda_users") ]
          ; allows = [ Create; Update; Delete; Replace ]
          ; reason =
              "ordinary platform reconciliation outside the immutable broker credential \
               projection"
          }
        ]
  }
;;

(* A surviving Pod matters even when its controller has already been removed.
   This namespace is Sol's existing native broker boundary; no naming recipe for
   chart-created workload objects is reconstructed here. *)
let observe_broker ~env ~namespace =
  let argv =
    [ "kubectl"; "get"; "pods,statefulsets"; "--namespace"; namespace; "--output=json" ]
  in
  let resource_class = "Kafka broker" in
  let checked_with = String.concat " " argv in
  let unknown reason =
    Sol_cli_absence.Unobservable { resource_class; reason; checked_with }
  in
  match Sol_cli_process.run (Sol_cli_process.cmd ~env argv) with
  | Error (Sol_cli_process.Non_zero result) -> unknown (String.trim result.stderr)
  | Error error -> unknown (Sol_cli_process.error_to_string error)
  | Ok result when String.trim result.stderr <> "" -> unknown (String.trim result.stderr)
  | Ok result ->
    let found =
      let* objects =
        Sol_cli_json.items ~what:"the native broker workload observation" result.stdout
      in
      Sol_cli_result.map_list
        (Sol_cli_json.require
           ~what:"a broker workload"
           [ "metadata"; "uid" ]
           Sol_cli_json.string)
        objects
    in
    (match found with
     | Error reason -> unknown reason
     | Ok found ->
       let identity = "workloads in the native broker namespace " ^ namespace in
       let attribution =
         Sol_cli_absence.Within_target
           "the target cluster's dedicated native broker namespace"
       in
       (match found with
        | [] ->
          Sol_cli_absence.Absent { resource_class; identity; attribution; checked_with }
        | found -> Present { resource_class; identity; attribution; checked_with; found }))
;;

(* Destruction accounts for every target disk. Initialization asks the narrower
   question whether any of those disks could hold this broker's data. Reuse the
   existing inventory identities, and require affirmative metadata before excluding
   a disk; missing metadata remains unknown. No second inventory is maintained. *)
let scope_storage observation ~is_kafka =
  match observation with
  | Sol_cli_absence.Present present ->
    let found =
      Sol_cli_result.map_list
        (fun identity ->
           Result.map
             (fun owned -> if owned then Some identity else None)
             (is_kafka identity))
        present.found
    in
    let resource_class = "Kafka storage" in
    (match found with
     | Error reason ->
       Sol_cli_absence.Unobservable
         { resource_class; reason; checked_with = present.checked_with }
     | Ok found ->
       let found = List.filter_map Fun.id found in
       let identity = "the native broker's persistent storage" in
       let attribution =
         Sol_cli_absence.Within_target
           "the provider's CSI namespace metadata; a confirmed node boot mapping is \
            excluded"
       in
       (match found with
        | [] ->
          Sol_cli_absence.Absent
            { resource_class; identity; attribution; checked_with = present.checked_with }
        | found ->
          Present
            { resource_class
            ; identity
            ; attribution
            ; checked_with = present.checked_with
            ; found
            }))
  | observation -> observation
;;

(* Inspect Terraform's resolved input, rather than reparsing HCL/CLI overrides.
   The same typed binding supplies both the expected intent and provisioning. *)
let check_plan_inputs ~kafka ~cluster_name text =
  let* json = Sol_cli_json.decode_sensitive ~what:"the native Kafka plan" text in
  let* expected =
    match kafka, cluster_name with
    | Sol_cli_resource_binding.Managed_kafka _, Some cluster_name ->
      Ok
        (Option.value
           (Sol_cli_resource_binding.kafka_native_connection ~cluster_name kafka)
           ~default:`Null)
    | Managed_kafka _, None ->
      Error "managed Kafka requires its declared cluster identity"
    | _ -> Ok `Null
  in
  let* connection =
    Sol_cli_json.require
      ~what:"the native Kafka plan"
      [ "variables"; "kafka_connection" ]
      Sol_cli_json.assoc
      json
  in
  let* actual =
    match List.assoc_opt "value" connection with
    | Some value -> Ok value
    | None -> Error "the native Kafka plan omits its resolved binding input"
  in
  let equal =
    match expected, actual with
    | `Null, `Null -> true
    | `Assoc expected, `Assoc actual ->
      List.sort String.compare (List.map fst expected)
      = List.sort String.compare (List.map fst actual)
      && List.for_all
           (fun (key, value) -> List.assoc_opt key actual = Some value)
           expected
    | _ -> false
  in
  if equal
  then Ok ()
  else
    Error
      "the resolved Terraform Kafka input conflicts with the declared binding; remove \
       provisioning overrides rather than changing its ownership or credential identity"
;;
