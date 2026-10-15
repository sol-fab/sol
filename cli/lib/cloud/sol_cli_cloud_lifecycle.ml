let backend_config (target : Sol_cli_config.target) ~root =
  let layer =
    match root with
    | `Cloud -> "cloud"
    | `Platform -> "platform"
    | `Authorization -> "authorization"
  in
  let object_key = Printf.sprintf "sol/%s/%s.tfstate" target.name layer in
  match target.state_bucket with
  | Some bucket ->
    (Sol_cli_provider_capabilities.capabilities_of target.provider).backend_config
      target
      ~bucket
      ~object_key
  | None -> Error "target must declare state_bucket before Sol can use durable state"
;;

let authorization_backend target = backend_config target ~root:`Authorization

type cloud_target =
  { target : Sol_cli_config.target
  ; platform_shape : Sol_cli_profile.platform_shape
  ; cloud_backend : string list
  ; platform_backend : string list
  ; base_domain : string
  ; letsencrypt_email : string
  ; cluster_access_role_arn : string option
  }

let required = Sol_cli_provider_capabilities.required

let cloud_target ~platform_shape (target : Sol_cli_config.target) =
  let open Result.Syntax in
  let* cloud_backend = backend_config target ~root:`Cloud in
  let* platform_backend = backend_config target ~root:`Platform in
  let* base_domain = required "base_domain" target.base_domain in
  let* letsencrypt_email = required "letsencrypt_email" target.letsencrypt_email in
  let* cluster_access_role_arn =
    (Sol_cli_provider_capabilities.capabilities_of target.provider)
      .cluster_access_role_arn
      target
  in
  Ok
    { target
    ; platform_shape
    ; cloud_backend
    ; platform_backend
    ; base_domain
    ; letsencrypt_email
    ; cluster_access_role_arn
    }
;;

let platform_address address = "module.platform." ^ address
let target config = config.target
let cloud_backend config = config.cloud_backend
let platform_backend config = config.platform_backend

type platform_inputs =
  { base_domain : string
  ; letsencrypt_email : string
  ; region : string
  ; cluster_issuer : string option
  ; observability_backend : string option
  ; platform_profile : string
  ; alert_receiver_type : string option
  ; alert_receiver_url : string option
  ; alert_owner : string option
  ; alert_runbook_url : string option
  ; cluster : Sol_cli_cluster.t
  }

let profile_of_platform_vars vars =
  vars
  |> List.find_map (fun var ->
    match String.index_opt var '=' with
    | Some i when String.sub var 0 i = "platform_profile" ->
      let value = String.sub var (i + 1) (String.length var - i - 1) in
      if Sol_cli_string.is_blank value then None else Some value
    | _ -> None)
;;

type platform_credential =
  { namespace : string
  ; secret : string
  }

let redpanda_namespace = "redpanda"

let platform_credentials_of_components ~platform_profile json =
  match
    Sol_cli_json.field [ "redpanda"; platform_profile; "auth"; "sasl"; "secretRef" ] json
  with
  | `String secret when not (Sol_cli_string.is_blank secret) ->
    [ { namespace = redpanda_namespace; secret } ]
  | _ -> []
;;

let missing_platform_credential_message ?deploy_handoff { namespace; secret } =
  (* Creating the Secret is an operator action that needs cluster access. When the
     target's cloud root has published how its deploy identity reaches the cluster,
     say so: it is the moment the operator needs it, and Sol has already computed
     it. Without one, keep the bare example. *)
  let create_lines =
    match deploy_handoff with
    | Some (command, context) ->
      [ "The cluster this needs is reachable with the deploy identity's command for this \
         target, which Sol has already computed:"
      ; ""
      ; Printf.sprintf "    %s" command
      ; ""
      ; Printf.sprintf
          "Run that, then create the Secret through the context it writes (%s):"
          context
      ; ""
      ; Printf.sprintf
          "    kubectl --context %s create secret generic %s -n %s \\"
          context
          secret
          namespace
      ; "      --from-literal=users.txt=\"sol-workloads:<password>:SCRAM-SHA-256\""
      ]
    | None ->
      [ "The credential is yours: Sol never generates, reads or stores it. Create the \
         Secret out of band, for example:"
      ; ""
      ; Printf.sprintf "    kubectl create secret generic %s -n %s \\" secret namespace
      ; "      --from-literal=users.txt=\"sol-workloads:<password>:SCRAM-SHA-256\""
      ]
  in
  String.concat
    "\n"
    ([ Printf.sprintf
         "the platform install cannot start: the operator-supplied Secret %s is absent \
          from namespace %s."
         secret
         namespace
     ; Printf.sprintf
         "The Redpanda chart declares auth.sasl.secretRef=%s and mounts that Secret as a \
          required volume on both the broker StatefulSet and the post-install Job, but \
          the chart does not create it."
         secret
     ; "Without it those pods never leave ContainerCreating, so Helm waits until its \
        timeout and the install reports only `context deadline exceeded`."
     ]
     @ create_lines
     @ [ ""; "then re-run `sol deploy <target>` to resume target reconciliation." ])
;;

type credential_presence =
  | Credential_present
  | Credential_absent
  | Credential_unverifiable of string

let credential_presence ~exit_code ~output =
  if exit_code = 0
  then Credential_present
  else (
    let said = String.lowercase_ascii output in
    if
      Sol_cli_string.contains ~needle:"notfound" said
      || Sol_cli_string.contains ~needle:"not found" said
    then Credential_absent
    else Credential_unverifiable (String.trim output))
;;

let unverifiable_platform_credential_message { namespace; secret } reason =
  String.concat
    "\n"
    [ Printf.sprintf
        "the platform install cannot start: Sol could not establish whether the \
         operator-supplied Secret %s exists in namespace %s, and it will not read a \
         failed check as an absent one."
        secret
        namespace
    ; Printf.sprintf "The check itself failed: %s" reason
    ; ""
    ; Printf.sprintf "    kubectl get secret %s -n %s -o name" secret namespace
    ; ""
    ; "Resolve that, then re-run `sol deploy <target>` to resume target reconciliation."
    ]
;;

let platform_inputs (target : cloud_target) (cluster : Sol_cli_cluster.t) =
  match
    cluster.check_identity ~cluster_access_role_arn:target.cluster_access_role_arn
  with
  | Error _ as refused -> refused
  | Ok () ->
    Ok
      { base_domain = target.base_domain
      ; letsencrypt_email = target.letsencrypt_email
      ; region = target.target.region
      ; cluster_issuer = target.target.cluster_issuer
      ; observability_backend = target.target.observability_backend
      ; platform_profile = Sol_cli_profile.platform_shape_to_string target.platform_shape
      ; alert_receiver_type = target.target.alert_receiver_type
      ; alert_receiver_url = target.target.alert_receiver_url
      ; alert_owner = target.target.alert_owner
      ; alert_runbook_url = target.target.alert_runbook_url
      ; cluster
      }
;;

type failure_policy =
  | Continue_to_destroy
  | Block_destroy

type 'a preparation_outcome =
  | Nothing_to_prepare
  | Prepared of 'a
  | Preparation_failed of
      { reason : string
      ; policy : failure_policy
      }

let preparation_failure = function
  | Nothing_to_prepare | Prepared _ -> None
  | Preparation_failed { reason; _ } -> Some reason
;;

let destruction_blocked = function
  | Nothing_to_prepare | Prepared _ -> None
  | Preparation_failed { policy = Continue_to_destroy; _ } -> None
  | Preparation_failed { reason; policy = Block_destroy } -> Some reason
;;

let represented_in ~state address =
  List.exists
    (fun observed -> Sol_cli_terraform_plan.same_resource address observed)
    state
;;

let preparations_eligible ~state ~desired = List.filter (represented_in ~state) desired

let preparations_unrepresented ~state ~desired =
  List.filter (fun address -> not (represented_in ~state address)) desired
;;

type platform_vars_context = Sol_cli_cluster.platform_vars_context =
  | Install
  | Destruction

let platform_terraform_vars ?(context = Install) inputs =
  let add_opt key value vars =
    match value with
    | None -> vars
    | Some value -> (key ^ "=" ^ value) :: vars
  in
  let optional vars =
    vars
    |> add_opt "cluster_issuer" inputs.cluster_issuer
    |> add_opt "observability_backend" inputs.observability_backend
    |> add_opt "platform_profile" (Some inputs.platform_profile)
    |> add_opt "alert_receiver_type" inputs.alert_receiver_type
    |> add_opt "alert_receiver_url" inputs.alert_receiver_url
    |> add_opt "alert_owner" inputs.alert_owner
    |> add_opt "alert_runbook_url" inputs.alert_runbook_url
  in
  let shared =
    [ "base_domain=" ^ inputs.base_domain
    ; "letsencrypt_email=" ^ inputs.letsencrypt_email
    ; "install_postgresql=false"
    ]
  in
  Result.map
    (fun { Sol_cli_cluster.fixed; optional = provider_optional } ->
       List.fold_left
         (fun vars (key, value) -> add_opt key value vars)
         (optional (shared @ fixed))
         provider_optional)
    (inputs.cluster.platform_vars
       context
       ~cluster_issuer:inputs.cluster_issuer
       ~region:inputs.region)
;;

type plan_phase =
  | Plannable
  | Deferred of string

let platform_plan_phases
      ~cluster_exists
      ~rbac_established
      ~install_window_open
      ~crds_established
  =
  let requires_cloud = "requires cloud substrate to exist" in
  let requires_rbac =
    "requires provisioner platform RBAC established by an earlier apply"
  in
  let requires_install_window =
    "requires the installation window that `sol deploy` opens (the platform root manages \
     objects outside the namespaces the steady-state provisioner holds)"
  in
  if not cluster_exists
  then Deferred requires_cloud, Deferred requires_cloud
  else if install_window_open
  then
    ( Plannable
    , if crds_established
      then Plannable
      else Deferred "requires cert-manager CRDs to be Established" )
  else if not rbac_established
  then Deferred requires_rbac, Deferred requires_rbac
  else if not crds_established
  then Plannable, Deferred "requires cert-manager CRDs to be Established"
  else Plannable, Deferred requires_install_window
;;

type authorization =
  | Required
  | Forbidden

let provisioner_authorization_checks =
  [ ( Required
    , [ "create"; "deployments.apps"; "-n"; Sol_cli_manifest.monitoring_namespace ] )
  ; Required, [ "create"; "services"; "-n"; "ingress-nginx" ]
  ; Required, [ "create"; "customresourcedefinitions.apiextensions.k8s.io" ]
  ; Required, [ "create"; "storageclasses.storage.k8s.io" ]
  ; Required, [ "create"; "clusterissuers.cert-manager.io" ]
  ; Required, [ "create"; "namespaces" ]
  ; Forbidden, [ "create"; "deployments.apps"; "-n"; "default" ]
  ; Forbidden, [ "create"; "services"; "-n"; "default" ]
  ; Forbidden, [ "create"; "jobs.batch"; "-n"; "default" ]
  ; Forbidden, [ "create"; "secrets"; "-n"; "default" ]
  ; Forbidden, [ "bind"; "clusterroles.rbac.authorization.k8s.io" ]
  ; Forbidden, [ "escalate"; "clusterroles.rbac.authorization.k8s.io" ]
  ]
;;

let provisioner_authorization_established ~can_i =
  provisioner_authorization_checks
  |> List.for_all (fun (expected, args) ->
    match expected with
    | Required -> can_i args
    | Forbidden -> not (can_i args))
;;

let install_window_authorization_checks =
  [ Required, [ "escalate"; "clusterroles" ]; Required, [ "bind"; "clusterroles" ] ]
;;

let install_window_open ~can_i =
  install_window_authorization_checks |> List.for_all (fun (_, args) -> can_i args)
;;

type readiness =
  | Established
  | Unmet of string
  | Unobservable of string

type readiness_check =
  { name : string
  ; reason : string
  ; accept : string -> bool
  ; argv : string list
  }

let check ?(accept = fun _ -> true) name reason argv = { name; reason; accept; argv }

let available_deployments namespace =
  [ "wait"
  ; "--for=condition=Available"
  ; "deployment"
  ; "--all"
  ; "-n"
  ; namespace
  ; "--timeout=5s"
  ]
;;

let converged_workload ~kind ~namespace ~ready_field ~desired_field =
  [ "get"
  ; kind
  ; "-n"
  ; namespace
  ; "-o"
  ; Printf.sprintf
      "jsonpath={range .items[*]}{.%s}/{.%s}{' '}{end}"
      ready_field
      desired_field
  ]
;;

let converged_daemonsets namespace =
  converged_workload
    ~kind:"daemonset"
    ~namespace
    ~ready_field:"status.numberReady"
    ~desired_field:"status.desiredNumberScheduled"
;;

let converged_statefulsets namespace =
  converged_workload
    ~kind:"statefulset"
    ~namespace
    ~ready_field:"status.readyReplicas"
    ~desired_field:"status.replicas"
;;

let bound_pvcs namespace =
  [ "get"
  ; "pvc"
  ; "-n"
  ; namespace
  ; "-o"
  ; "jsonpath={range .items[*]}{.status.phase}{' '}{end}"
  ]
;;

let ready_nodes =
  [ "get"
  ; "nodes"
  ; "-o"
  ; "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{' \
     '}{end}"
  ]
;;

let replicas_converged ?(require_desired = true) output =
  let pairs =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  pairs <> []
  && pairs
     |> List.for_all (fun pair ->
       match String.split_on_char '/' pair with
       | [ ready; desired ] ->
         (match int_of_string_opt ready, int_of_string_opt desired with
          | Some ready, Some desired ->
            ready = desired && (desired > 0 || not require_desired)
          | None, _ | _, None -> false)
       | _ -> false)
;;

let daemonsets_converged output = replicas_converged output
let statefulsets_converged output = replicas_converged ~require_desired:false output

let all_pvcs_bound output =
  let phases =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  phases <> [] && List.for_all (fun phase -> phase = "Bound") phases
;;

let all_nodes_ready output =
  let states =
    String.split_on_char ' ' (String.trim output) |> List.filter (fun part -> part <> "")
  in
  states <> [] && List.for_all (fun state -> state = "True") states
;;

type platform_storage = Sol_cli_provider_capabilities.platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

let platform_storage provider =
  (Sol_cli_provider_capabilities.capabilities_of provider).platform_storage
;;

let storage_class_entries =
  let jsonpath =
    "jsonpath={range .items[*]}"
    ^ "{.metadata.name}{'|'}{.provisioner}{'|'}"
    ^ "{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}"
    ^ "{' '}{end}"
  in
  [ "get"; "storageclass"; "-o"; jsonpath ]
;;

let sole_default_storage_class ~storage_class ~csi_driver output =
  let fields entry = String.split_on_char '|' entry in
  let is_default entry =
    match fields entry with
    | [ _; _; "true" ] -> true
    | _ -> false
  in
  match String.split_on_char ' ' (String.trim output) |> List.filter is_default with
  | [ entry ] ->
    (match fields entry with
     | [ name; provisioner; _ ] -> name = storage_class && provisioner = csi_driver
     | _ -> false)
  | [] | _ :: _ :: _ -> false
;;

let storage_checks provider =
  let { storage_class; csi_driver } = platform_storage provider in
  [ check
      ~accept:(sole_default_storage_class ~storage_class ~csi_driver)
      "default StorageClass"
      (Printf.sprintf
         "%s is absent, is not the only default StorageClass, or is not provided by %s"
         storage_class
         csi_driver)
      storage_class_entries
  ; check
      "block-storage CSI driver"
      (Printf.sprintf "the %s block-storage CSI driver is not registered" csi_driver)
      [ "get"; "csidriver/" ^ csi_driver ]
  ]
;;

let platform_certificate_checks =
  List.map
    (fun (declared : Sol_cli_platform_tls.declared_certificate) ->
       check
         (Printf.sprintf "platform certificate %s" declared.certificate)
         (Printf.sprintf
            "the platform's declared certificate %s/%s is not Ready, so the platform \
             cannot             serve the TLS it declares (DEC-056); an unpublished \
             delegation or a failing ACME             challenge is the usual reason"
            declared.namespace
            declared.certificate)
         [ "wait"
         ; "--for=condition=Ready"
         ; "certificate/" ^ declared.certificate
         ; "-n"
         ; declared.namespace
         ; "--timeout=5s"
         ])
    Sol_cli_platform_tls.certificates
;;

let readiness_checks ~provider =
  if not (Sol_cli_provider_capabilities.owns_root provider)
  then []
  else (
    let before_storage =
      [ check
          "cert-manager CRDs"
          "required cert-manager CRDs are not Established"
          [ "wait"
          ; "--for=condition=Established"
          ; "crd/certificates.cert-manager.io"
          ; "crd/clusterissuers.cert-manager.io"
          ; "--timeout=5s"
          ]
      ; check
          "cert-manager controllers"
          "cert-manager controller, webhook, or cainjector is unavailable"
          (available_deployments "cert-manager")
      ; check ~accept:all_nodes_ready "nodes" "a cluster node is not Ready" ready_nodes
      ]
    in
    before_storage
    @ storage_checks provider
    @ [ check
          "monitoring deployments"
          "a monitoring deployment is not available"
          (available_deployments "monitoring")
      ; check
          ~accept:statefulsets_converged
          "monitoring statefulsets"
          "a monitoring statefulset does not have every declared replica ready"
          (converged_statefulsets "monitoring")
      ; check
          ~accept:daemonsets_converged
          "monitoring daemonsets"
          "a monitoring daemonset does not have every scheduled pod ready"
          (converged_daemonsets "monitoring")
      ; check
          ~accept:all_pvcs_bound
          "monitoring PVCs"
          "a monitoring PersistentVolumeClaim is not Bound"
          (bound_pvcs "monitoring")
      ; check
          "Redpanda"
          "Redpanda broker-native cluster health is not healthy"
          [ "exec"
          ; "-n"
          ; "redpanda"
          ; "statefulset/redpanda"
          ; "--"
          ; "rpk"
          ; "cluster"
          ; "health"
          ; "--exit-when-healthy"
          ; "--watch=false"
          ]
      ; check
          ~accept:statefulsets_converged
          "Redpanda statefulset"
          "the Redpanda statefulset does not have every declared replica ready"
          (converged_statefulsets "redpanda")
      ; check
          ~accept:all_pvcs_bound
          "Redpanda PVCs"
          "a Redpanda PersistentVolumeClaim is not Bound"
          (bound_pvcs "redpanda")
      ; check
          "ingress-nginx"
          "ingress-nginx controller is unavailable"
          (available_deployments "ingress-nginx")
      ; check
          ~accept:(fun output -> output <> "")
          "ingress endpoint"
          "ingress-nginx LoadBalancer has no assigned endpoint"
          [ "get"
          ; "service/ingress-nginx-controller"
          ; "-n"
          ; "ingress-nginx"
          ; "-o"
          ; "jsonpath={.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}"
          ]
      ; check
          "Argo CD"
          "an Argo CD controller is unavailable"
          (available_deployments "argocd")
      ]
    @ platform_certificate_checks)
;;

(* Probe outcomes stay typed and keep the probe's own evidence. A probe that
   could not run (refused, timed out, tool missing, malformed output) is
   [Unobservable], never promoted to a confirmed [Unmet] condition. *)
let readiness ~provider ~run =
  readiness_checks ~provider
  |> List.map (fun check ->
    ( check.name
    , match run check.argv with
      | Ok output when check.accept (String.trim output) -> Established
      | Ok _ -> Unmet check.reason
      | Error why ->
        Unobservable (Printf.sprintf "could not observe %s: %s" check.name why) ))
;;

let readiness_invocations ~provider =
  List.map (fun check -> check.name, check.argv) (readiness_checks ~provider)
;;

let readiness_entries pick checks =
  checks
  |> List.filter_map (fun (name, result) ->
    match pick result with
    | None -> None
    | Some reason -> Some (name ^ ": " ^ reason))
;;

let readiness_summary checks =
  let unmet =
    readiness_entries
      (function
        | Unmet reason -> Some reason
        | Established | Unobservable _ -> None)
      checks
  in
  let unobservable =
    readiness_entries
      (function
        | Unobservable reason -> Some reason
        | Established | Unmet _ -> None)
      checks
  in
  match unmet, unobservable with
  | [], [] -> "Ready"
  | unmet, [] -> "Unmet — " ^ String.concat "; " unmet
  | [], unobservable -> "Unobservable — " ^ String.concat "; " unobservable
  | unmet, unobservable ->
    Printf.sprintf
      "Unmet — %s; unobservable — %s"
      (String.concat "; " unmet)
      (String.concat "; " unobservable)
;;

(* The lifecycle decision reads the typed outcomes, not the rendered summary, so
   changing readiness wording cannot change whether an apply advances. *)
let readiness_decision checks =
  if
    List.for_all
      (fun (_, result) ->
         match result with
         | Established -> true
         | Unmet _ | Unobservable _ -> false)
      checks
  then Ok ()
  else Error (readiness_summary checks)
;;

type phase =
  | Absent
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying

type phase_policy =
  | Bootstrap
  | Installation
  | Production
  | Destroy

let policy_of_phase = function
  | Absent | Cloud_bootstrap -> Bootstrap
  | Platform_installing | Platform_updating -> Installation
  | Ready -> Production
  | Preparing_destroy | Destroying -> Destroy
;;

let transition_allowed ~from ~to_ =
  match from, to_ with
  | Absent, Cloud_bootstrap -> true
  | Cloud_bootstrap, Platform_installing -> true
  | Platform_installing, Ready -> true
  | Ready, Platform_updating -> true
  | Platform_updating, Ready -> true
  | Ready, Preparing_destroy -> true
  | Preparing_destroy, Destroying -> true
  | Destroying, Absent -> true
  | _ -> false
;;

let destruction_available = function
  | Absent -> false
  | Cloud_bootstrap
  | Platform_installing
  | Ready
  | Platform_updating
  | Preparing_destroy
  | Destroying -> true
;;

let enter_destruction ~from =
  if destruction_available from then Preparing_destroy else Absent
;;

let ready_policy_applies phase = policy_of_phase phase = Production

type destroy_retention =
  | Retain_final_snapshot
  | Retain_nothing

let default_destroy_retention = Retain_final_snapshot

let destroy_retention_to_string = function
  | Retain_final_snapshot -> "final-snapshot"
  | Retain_nothing -> "none"
;;

let destroy_retention_of_string = function
  | "final-snapshot" -> Ok Retain_final_snapshot
  | "none" -> Ok Retain_nothing
  | other ->
    Error
      (Printf.sprintf
         "unknown destroy_retention %S (expected \"final-snapshot\" or \"none\")"
         other)
;;

let policy_vars ~provider ~phase ~destroy_snapshot_id ~retention =
  match policy_of_phase phase with
  | Bootstrap | Installation | Production -> []
  | Destroy ->
    (Sol_cli_provider_capabilities.capabilities_of provider).destroy_guard_vars
      ~final_snapshot:
        (match retention with
         | Retain_final_snapshot -> Some destroy_snapshot_id
         | Retain_nothing -> None)
;;

let phase_to_string = function
  | Absent -> "Absent"
  | Cloud_bootstrap -> "CloudBootstrap"
  | Platform_installing -> "PlatformInstalling"
  | Ready -> "Ready"
  | Platform_updating -> "PlatformUpdating"
  | Preparing_destroy -> "PreparingDestroy"
  | Destroying -> "Destroying"
;;

let observed_phase ~cloud_exists ~platform_installed =
  if not cloud_exists
  then Absent
  else if platform_installed
  then Ready
  else Platform_installing
;;

include Sol_cli_capability

let enter ~from ~to_ =
  if transition_allowed ~from ~to_
  then Ok to_
  else
    Error
      (Printf.sprintf
         "illegal lifecycle transition %s -> %s"
         (phase_to_string from)
         (phase_to_string to_))
;;
