type root_status =
  | Root_present
  | Root_not_applicable
  | Root_not_implemented

type platform_storage =
  { storage_class : string
  ; csi_driver : string
  }

let failure_mentions markers message =
  let lowercased = String.lowercase_ascii message in
  List.exists (fun marker -> Sol_cli_string.contains ~needle:marker lowercased) markers
;;

let aws_failure_means_absent =
  failure_mentions
    [ "nosuchbucket"
    ; "nosuchentity"
    ; "resourcenotfound"
    ; "(404)"
    ; "not found"
    ; "does not exist"
    ; "cannot be found"
    ]
;;

let gcp_failure_means_absent =
  failure_mentions
    [ "notfound"; "not found"; "does not exist"; "was not found"; "(404)"; "status: 404" ]
;;

type identity_contract =
  { identity : Sol_cli_installation.prerequisite
  ; policy_output : string
  ; declared_as : string
  }

type authority =
  | No_authority_required
  | Mechanism of
      { matchers : Sol_cli_terraform_plan.matcher list
      ; scope : Sol_cli_terraform.scope
      ; reconciliation_scope : string list -> Sol_cli_terraform.scope
      }

type authorization_reconciler =
  | Reconciler_role of string
  | Reconciler_service_account of string

type authorization_workload =
  { unit : string
  ; namespace : string
  ; secrets : string list
  }

type t =
  { root_status : root_status
  ; workload_identity_issuer : Sol_cli_config.target -> (string, string) result
  ; backend_config :
      Sol_cli_config.target
      -> bucket:string
      -> object_key:string
      -> (string list, string) result
  ; cluster_access_role_arn : Sol_cli_config.target -> (string option, string) result
  ; platform_storage : platform_storage
  ; cluster_substrate :
      (outputs_json:string
       -> region:string
       -> cluster_name:string
       -> (Sol_cli_cluster_substrate.t, string) result)
        option
  ; installation_prerequisites : Sol_cli_installation.prerequisite list
  ; installation_probes :
      Sol_cli_installation.installation_config -> Sol_cli_installation.probe list
  ; installation_backend :
      Sol_cli_installation.installation_config -> (string list, string) result
  ; installation_vars :
      manage_dns_zone:bool
      -> ?parent_zone_id:string
      -> Sol_cli_installation.installation_config
      -> (string * string) list
  ; installation_zone_address : string
  ; installation_zone_import_address : string
  ; installation_zone_lookup : string -> string list
  ; installation_zone_candidates : string -> ((string * string) list, string) result
  ; installation_nameservers_output : string
  ; installation_failure_means_absent : string -> bool
  ; installation_identity_contracts : identity_contract list
  ; installation_created_prerequisites : Sol_cli_installation.prerequisite list
  ; installation_state_backend_address : string
  ; installation_retire_state_backend :
      run:(string list -> Sol_cli_installation.observation)
      -> Sol_cli_installation.installation_config
      -> (unit, string) result
  ; own_vars :
      Sol_cli_config.target
      -> workspace:string
      -> (string * string) list
      -> (string * string) list
  ; profile_vars : production:bool -> production_postgres:bool -> (string * string) list
  ; guarded_removals : string list
  ; root_declared_vars :
      has_postgres:bool
      -> kafka_connection:Yojson.Safe.t option
      -> production_postgres:bool
      -> ecr_repositories:(unit -> (string, string) result)
      -> ((string * string) list, string) result
  ; destroy_guard_vars : final_snapshot:string option -> (string * string) list
  ; authority : authority
  ; guarded_addresses : string list
  ; cloud_ready_expectation : string
  ; production_qualified : bool
  ; state_locking : string option
  ; scoped_identities : string list
  ; authorization_reconciler_field : string
  ; authorization_trust_field : string
  ; authorization_destroy_trust_placeholder : string
  ; authorization_root_vars :
      Sol_cli_config.target -> ((string * string) list, string) result
  ; authorization_serverless_root_vars :
      Sol_cli_config.target
      -> Sol_cli_grant.serverless_unit list
      -> ((string * string) list, string) result
  ; authorization_fence_addresses : string list
  ; authorization_reconciler :
      Sol_cli_config.target -> (authorization_reconciler, string) result
  ; authorization_assumption :
      authorization_reconciler -> ((string * string) list, string) result
  ; authorization_principal_matches :
      authorization_reconciler -> principal:string -> (unit, string) result
  ; authorization_effective_access :
      Sol_cli_config.target -> authorization_workload list -> (unit, string) result
  }

let public_delegation_probe domain =
  Sol_cli_installation.present_if_output_names
    ~reason:
      (Printf.sprintf
         "no public NS records resolve for %s, so nothing outside Sol can reach the zone \
          yet: the delegation has not propagated, or it has not been added"
         domain)
    Sol_cli_installation.Public_delegation
    [ "dig"; "+short"; "NS"; domain ]
;;

let dns_declaration
      ~manage_dns_zone
      (configuration : Sol_cli_installation.installation_config)
  =
  if not manage_dns_zone
  then "false", ""
  else (
    match Sol_cli_installation.zone_domain configuration.zone with
    | None -> "false", ""
    | Some domain -> "true", domain)
;;

let add_opt k = function
  | None -> Fun.id
  | Some v -> fun xs -> (k, v) :: xs
;;

let required name value =
  Option.to_result ~none:("the cloud lifecycle requires target." ^ name) value
;;

let aws_backend_config
  :  Sol_cli_config.target
  -> bucket:string
  -> object_key:string
  -> (string list, string) result
  =
  fun target ~bucket ~object_key ->
  match Sol_cli_config.provider_field target "state_lock_table" with
  | Some table ->
    Ok
      [ "bucket=" ^ bucket
      ; "key=" ^ object_key
      ; "region=" ^ target.region
      ; "dynamodb_table=" ^ table
      ; "encrypt=true"
      ]
  | _ ->
    Error
      "an AWS target must declare aws.state_lock_table: S3 has no native state locking, \
       so two applies could corrupt the same state"
;;

let aws_cluster_access_role_arn : Sol_cli_config.target -> (string option, string) result =
  fun target ->
  Result.map
    Option.some
    (required
       "aws.cluster_access_role_arn"
       (Sol_cli_config.provider_field target "cluster_access_role_arn"))
;;

(* The answer is the provider's own document; the lookup's exact zone is
   decided by name (see [installation_zone_candidates] and BUG-211). No
   [--query] projection is used, because Route53's ListHostedZonesByName is a
   prefix listing, and asking for element 0 is precisely what misattributed the
   installation's own zone to its parent. *)
let aws_installation_zone_lookup : string -> string list =
  fun domain ->
  [ "aws"
  ; "route53"
  ; "list-hosted-zones-by-name"
  ; "--dns-name"
  ; domain
  ; "--output"
  ; "json"
  ]
;;

(* [(name, identity, private)] for every zone the provider returned. [Id] is
   optional because the delegated-zone probe only needs the name; the adoption
   lookup requires it. *)
let aws_zones output =
  let open Sol_cli_json in
  let open Result.Syntax in
  let what = "the Route53 hosted-zone answer" in
  let* json = decode ~what output in
  let* zones = require ~what [ "HostedZones" ] list json in
  zones
  |> Sol_cli_result.map_list (fun zone ->
    let* name = require ~what [ "Name" ] string zone in
    let* private_zone = optional ~what [ "Config"; "PrivateZone" ] bool zone in
    let* identity = optional ~what [ "Id" ] string zone in
    Ok (name, identity, Option.value private_zone ~default:false))
;;

let public_zone_names zones =
  List.filter_map
    (fun (name, _, private_zone) -> if private_zone then None else Some name)
    zones
;;

let aws_installation_zone_candidates output =
  let open Result.Syntax in
  let* zones = aws_zones output in
  zones
  |> Sol_cli_result.map_list (fun (name, identity, private_zone) ->
    if private_zone
    then Ok None
    else (
      match identity with
      | Some identity -> Ok (Some (identity, name))
      | None ->
        Error "a public hosted zone in the Route53 answer named no identity to adopt"))
  |> Result.map (List.filter_map (fun candidate -> candidate))
;;

let aws_zone_probes
  : Sol_cli_installation.installation_config -> Sol_cli_installation.probe list
  =
  fun configuration ->
  let open Sol_cli_installation in
  match configuration.zone with
  | No_zone -> []
  | Service_zone { domain; ownership = Externally_delegated } ->
    [ unverifiable
        Delegated_zone
        (Printf.sprintf
           "%s is externally delegated: the zone lives outside AWS, so the delegation to \
            this installation cannot be observed where the installation looks — \
            confirming it is the delegation wait, not a provider lookup"
           domain)
    ]
  | Service_zone { domain; ownership } ->
    [ present_if_output_names
        ~present:(fun output ->
          match aws_zones output with
          | Ok zones ->
            List.exists
              (Sol_cli_installation.dns_names_equal domain)
              (public_zone_names zones)
          | Error _ -> false)
        ~reason:
          (Printf.sprintf
             "no Route53 hosted zone named %s, although the target declares it %s"
             domain
             (match ownership with
              | Sol_created -> "sol-created"
              | User_supplied -> "user-supplied"
              | Externally_delegated -> "(external)"))
        Delegated_zone
        (aws_installation_zone_lookup domain)
    ]
    @ [ public_delegation_probe domain ]
;;

let aws_installation_probes
  : Sol_cli_installation.installation_config -> Sol_cli_installation.probe list
  =
  fun configuration ->
  let open Sol_cli_installation in
  let role_name arn =
    match Sol_cli_string.after_opt ~needle:":role/" arn with
    | Some name -> name
    | None ->
      (match String.rindex_opt arn '/' with
       | Some i when i + 1 < String.length arn ->
         String.sub arn (i + 1) (String.length arn - i - 1)
       | _ -> arn)
  in
  let role prerequisite name =
    match name with
    | Some arn ->
      present_if_output
        prerequisite
        [ "aws"; "iam"; "get-role"; "--role-name"; role_name arn ]
    | None ->
      absent
        prerequisite
        (Printf.sprintf
           "the resolved installation configuration names no %s"
           (prerequisite_label prerequisite))
  in
  [ present_if_output
      State_backend
      [ "aws"
      ; "s3api"
      ; "head-bucket"
      ; "--bucket"
      ; configuration.state_bucket
      ; "--region"
      ; configuration.region
      ]
  ; (match configuration.lock_table with
     | Some table ->
       present_if_output
         State_lock
         [ "aws"
         ; "dynamodb"
         ; "describe-table"
         ; "--table-name"
         ; table
         ; "--region"
         ; configuration.region
         ]
     | None ->
       absent
         State_lock
         "the resolved installation configuration names no lock table, and the AWS \
          durable root declares one")
  ; role Provisioning_identity configuration.provisioning_identity
  ; role Cluster_access_identity configuration.cluster_access_identity
  ; role Deploy_identity configuration.deploy_identity
  ; role Operator_identity configuration.operator_identity
  ]
  @ aws_zone_probes configuration
;;

let aws_installation_backend
  : Sol_cli_installation.installation_config -> (string list, string) result
  =
  fun configuration ->
  match configuration.lock_table with
  | None ->
    Error
      "an AWS installation must declare aws.state_lock_table before the durable root can \
       be reconciled: S3 has no native state locking, so a root whose backend names no \
       lock table could corrupt its own state"
  | Some table ->
    Ok
      [ "bucket=" ^ configuration.state_bucket
      ; "key=" ^ configuration.state_prefix ^ "/default.tfstate"
      ; "region=" ^ configuration.region
      ; "dynamodb_table=" ^ table
      ; "encrypt=true"
      ]
;;

let aws_installation_vars
  :  manage_dns_zone:bool
  -> ?parent_zone_id:string
  -> Sol_cli_installation.installation_config
  -> (string * string) list
  =
  fun ~manage_dns_zone ?parent_zone_id configuration ->
  [ "region", configuration.region
  ; "state_bucket", configuration.state_bucket
  ; "state_lock_table", Option.value configuration.lock_table ~default:""
  ; "manage_dns_zone", fst (dns_declaration ~manage_dns_zone configuration)
  ; "base_domain", snd (dns_declaration ~manage_dns_zone configuration)
  ; "parent_zone_id", Option.value parent_zone_id ~default:""
  ]
;;

let aws_own_vars
  :  Sol_cli_config.target
  -> workspace:string
  -> (string * string) list
  -> (string * string) list
  =
  fun target ~workspace shared ->
  let vars =
    shared
    |> add_opt "cluster_endpoint_cidr" target.cluster_endpoint_cidr
    |> add_opt
         "provisioner_role_arn"
         (Sol_cli_config.provider_field target "provisioner_role_arn")
    |> add_opt
         "cluster_access_role_arn"
         (Sol_cli_config.provider_field target "cluster_access_role_arn")
    |> add_opt "deploy_role_arn" (Sol_cli_config.provider_field target "deploy_role_arn")
    |> add_opt
         "operator_role_arn"
         (Sol_cli_config.provider_field target "operator_role_arn")
    |> add_opt "workspace_name" (Some workspace)
  in
  (* The durable root owns and ensures the delegated zone for every declared
     dns_zone_ownership, so the cluster root reuses it. It must never create a
     second hosted zone for base_domain: that would make its own
     data.aws_route53_zone lookup ambiguous and block an ordinary destroy. *)
  match target.base_domain with
  | Some domain when not (Sol_cli_string.is_blank domain) ->
    ("create_route53_zone", "false") :: vars
  | _ -> vars
;;

let required_field target field =
  match Sol_cli_config.provider_field target field with
  | Some value when not (Sol_cli_string.is_blank value) -> Ok value
  | Some _ | None ->
    Error
      (Printf.sprintf
         "target %s must declare %s.%s for the authorization reconciler to run"
         target.name
         (Sol_cli_provider.to_string target.provider)
         field)
;;

let authorization_role_path arn =
  let marker = ":role/" in
  let width = String.length marker in
  let rec scan i =
    if i + width > String.length arn
    then None
    else if String.sub arn i width = marker
    then Some (String.sub arn (i + width) (String.length arn - i - width))
    else scan (i + 1)
  in
  Option.value (scan 0) ~default:(Filename.basename arn)
;;

let run_command args =
  Sol_cli_process.run (Sol_cli_process.cmd args)
  |> Result.map (fun (output : Sol_cli_process.output) -> output.stdout)
  |> Result.map_error Sol_cli_process.error_to_string
;;

(* DEC-051/DEC-063: the trusted Kubernetes service-account OIDC issuer is
   target/infrastructure truth. A driver establishes exactly one such issuer and
   reports it here, or reports why it cannot; [Error] means "there is no trusted
   issuer to consume", and every caller must fail closed. The value is never
   application configuration and is never taken from the [iss] claim of an
   incoming token. *)
let oidc_issuer_of_output ~provider ?expected_host output =
  let output = String.trim output in
  let uri = Uri.of_string output in
  match
    Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.query uri, Uri.fragment uri
  with
  | Some "https", Some host, None, [], None
    when Option.fold ~none:true ~some:(String.equal host) expected_host -> Ok output
  | _ ->
    Error
      (Printf.sprintf
         "%s reported no usable HTTPS Kubernetes OIDC issuer URL: %S"
         provider
         output)
;;

let aws_workload_identity_issuer ~run (target : Sol_cli_config.target) =
  match target.cluster_name with
  | None ->
    Error "the aws target must declare cluster_name to establish its trusted OIDC issuer"
  | Some cluster_name ->
    Result.bind
      (run
         [ "aws"
         ; "eks"
         ; "describe-cluster"
         ; "--name"
         ; cluster_name
         ; "--region"
         ; target.region
         ; "--query"
         ; "cluster.identity.oidc.issuer"
         ; "--output"
         ; "text"
         ])
      (oidc_issuer_of_output ~provider:"AWS EKS")
;;

let gcp_workload_identity_issuer ~run (target : Sol_cli_config.target) =
  match target.cluster_name, Sol_cli_config.provider_field target "project_id" with
  | None, _ ->
    Error "the gcp target must declare cluster_name to establish its trusted OIDC issuer"
  | _, None ->
    Error
      "the gcp target must declare gcp.project_id to establish its trusted OIDC issuer"
  | _, Some project_id when Sol_cli_string.is_blank project_id ->
    Error
      "the gcp target must declare a non-blank gcp.project_id to establish its OIDC \
       issuer"
  | Some cluster_name, Some project_id ->
    let path_segment = Uri.pct_encode in
    let expected_issuer =
      Printf.sprintf
        "https://container.googleapis.com/v1/projects/%s/locations/%s/clusters/%s"
        (path_segment project_id)
        (path_segment target.region)
        (path_segment cluster_name)
    in
    let url = expected_issuer ^ "/.well-known/openid-configuration" in
    let open Result.Syntax in
    (* The GKE cluster OIDC discovery document is part of Google's public API:
       the callee fetches it and the advertised JWKS without Google credentials,
       so discovery here must not depend on an operator credential either — a
       deploy that only "works" with operator credentials would hide a target
       whose workloads cannot verify tokens at runtime. *)
    let* response = run [ "curl"; "-fsS"; url ] in
    let discovered_issuer =
      match Yojson.Safe.from_string response with
      | `Assoc fields ->
        (match List.assoc_opt "issuer" fields with
         | Some (`String issuer) -> Ok issuer
         | _ -> Error "GKE OIDC discovery response has no string issuer")
      | _ -> Error "GKE OIDC discovery response is not a JSON object"
      | exception Yojson.Json_error message ->
        Error ("GKE OIDC discovery returned invalid JSON: " ^ message)
    in
    let* discovered =
      Result.bind
        discovered_issuer
        (oidc_issuer_of_output ~provider:"GKE" ~expected_host:"container.googleapis.com")
    in
    if discovered = expected_issuer
    then Ok discovered
    else Error "GKE OIDC discovery issuer does not match the declared target cluster"
;;

let aws_authorization_root_vars target =
  let open Result.Syntax in
  let* trust = required_field target "reconciler_trust_principal_arn" in
  Ok
    [ "region", target.region
    ; "environment", target.env
    ; "cluster_name", Option.value target.cluster_name ~default:""
    ; "reconciler_trust_principal_arn", trust
    ]
;;

let gcp_authorization_root_vars target =
  let open Result.Syntax in
  let* trust = required_field target "reconciler_trust_principal" in
  let* project = required_field target "project_id" in
  Ok
    [ "region", target.region
    ; "environment", target.env
    ; "project_id", project
    ; "reconciler_trust_principal", trust
    ]
;;

let aws_authorization_reconciler target =
  Result.map
    (fun role_arn -> Reconciler_role role_arn)
    (required_field target "reconciler_role_arn")
;;

let aws_serverless_root_vars _target _units =
  Error "serverless runtime identities are not implemented for AWS targets"
;;

let gcp_serverless_root_vars target units =
  let open Result.Syntax in
  let* project = required_field target "project_id" in
  let* existing_trust =
    match required_field target "reconciler_trust_principal" with
    | Ok trust -> Ok trust
    | Error _ -> Ok ""
  in
  let units =
    `List (List.map Sol_cli_grant.serverless_unit_to_json units) |> Yojson.Safe.to_string
  in
  Ok
    [ "region", target.region
    ; "environment", target.env
    ; "project_id", project
    ; "reconciler_trust_principal", existing_trust
    ; "serverless_units", units
    ]
;;

let gcp_authorization_reconciler target =
  Result.map
    (fun account -> Reconciler_service_account account)
    (required_field target "reconciler_service_account")
;;

let aws_authorization_assumption (reconciler : authorization_reconciler) =
  match reconciler with
  | Reconciler_service_account _ ->
    Error "the AWS authorization reconciler must be an IAM role, not a service account"
  | Reconciler_role role_arn ->
    let open Result.Syntax in
    let* output =
      run_command
        [ "aws"
        ; "sts"
        ; "assume-role"
        ; "--role-arn"
        ; role_arn
        ; "--role-session-name"
        ; "sol-authorization"
        ; "--duration-seconds"
        ; "3600"
        ; "--output"
        ; "json"
        ]
    in
    let field key credentials =
      match List.assoc_opt key credentials with
      | Some (`String value) -> Ok value
      | Some _ -> Error (Printf.sprintf "sts:AssumeRole returned a non-string %s" key)
      | None -> Error (Printf.sprintf "sts:AssumeRole returned no %s" key)
    in
    let* json = Sol_cli_json.decode_sensitive ~what:"sts:AssumeRole" output in
    let* credentials =
      match json with
      | `Assoc fields ->
        (match List.assoc_opt "Credentials" fields with
         | Some (`Assoc credentials) -> Ok credentials
         | Some _ -> Error "sts:AssumeRole returned a non-object Credentials"
         | None -> Error "sts:AssumeRole returned no Credentials")
      | _ -> Error "sts:AssumeRole did not return a JSON object"
    in
    let* access_key_id = field "AccessKeyId" credentials in
    let* secret_access_key = field "SecretAccessKey" credentials in
    let* session_token = field "SessionToken" credentials in
    Ok
      [ "AWS_ACCESS_KEY_ID", access_key_id
      ; "AWS_SECRET_ACCESS_KEY", secret_access_key
      ; "AWS_SESSION_TOKEN", session_token
      ]
;;

let gcp_authorization_assumption (reconciler : authorization_reconciler) =
  match reconciler with
  | Reconciler_role _ ->
    Error "the GCP authorization reconciler must be a service account, not an IAM role"
  | Reconciler_service_account account ->
    let open Result.Syntax in
    let* token =
      run_command
        [ "gcloud"
        ; "auth"
        ; "print-access-token"
        ; "--impersonate-service-account"
        ; account
        ]
    in
    (match Sol_cli_string.non_blank_opt (Some (String.trim token)) with
     | Some token -> Ok [ "GOOGLE_OAUTH_ACCESS_TOKEN", token ]
     | None ->
       Error
         "gcloud returned no access token for the reconciler service account; is it \
          impersonatable by this caller?")
;;

let aws_authorization_principal_matches (reconciler : authorization_reconciler) ~principal
  =
  match reconciler with
  | Reconciler_service_account _ -> Error "the AWS reconciler is not a service account"
  | Reconciler_role arn ->
    if Sol_cli_string.is_blank principal
    then
      Error
        "the AWS caller identity could not be observed, so the reconciler is not \
         established"
    else if String.equal principal arn
    then Ok ()
    else (
      let assumed = "assumed-role/" ^ authorization_role_path arn ^ "/" in
      if Sol_cli_string.contains ~needle:assumed principal
      then Ok ()
      else
        Error
          (Printf.sprintf
             "the AWS caller %s is not the declared reconciler %s; run this command with \
              the reconciler identity, not another identity"
             principal
             arn))
;;

let gcp_authorization_principal_matches (reconciler : authorization_reconciler) ~principal
  =
  match reconciler with
  | Reconciler_role _ -> Error "the GCP reconciler is not an IAM role"
  | Reconciler_service_account account ->
    if Sol_cli_string.is_blank principal
    then
      Error
        "the GCP principal could not be observed, so the reconciler is not established"
    else if Sol_cli_string.contains ~needle:account principal
    then Ok ()
    else
      Error
        (Printf.sprintf "the GCP principal %s is not the declared reconciler" principal)
;;

let authorization_refusal (target : Sol_cli_config.target) ~unit ~capability ~resource =
  Printf.sprintf
    "unit %s does not have effective access to %s/%s in %s: the reconciler has not \
     established the grant. Run `sol grants apply %s`, then re-run this deploy (DEC-062 \
     rule 3)."
    unit
    capability
    resource
    target.name
    target.name
;;

let aws_simulation_decisions output =
  match Yojson.Safe.from_string output with
  | `List items ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | `String decision :: rest -> collect (decision :: acc) rest
      | _ :: _ -> Error "iam:SimulatePrincipalPolicy returned a non-string decision"
    in
    collect [] items
  | _ -> Error "iam:SimulatePrincipalPolicy did not return a JSON array"
  | exception Yojson.Json_error message ->
    Error ("iam:SimulatePrincipalPolicy returned invalid JSON: " ^ message)
;;

let aws_effective_access ~run (target : Sol_cli_config.target) workloads =
  let open Result.Syntax in
  let workloads =
    List.filter (fun (w : authorization_workload) -> w.secrets <> []) workloads
  in
  match workloads with
  | [] -> Ok ()
  | _ ->
    let* account =
      Result.bind
        (run
           [ "aws"
           ; "sts"
           ; "get-caller-identity"
           ; "--query"
           ; "Account"
           ; "--output"
           ; "text"
           ])
        (fun output ->
           match Sol_cli_string.non_blank_opt (Some (String.trim output)) with
           | Some account -> Ok account
           | None -> Error "aws sts get-caller-identity returned no account id")
    in
    let check_workload (workload : authorization_workload) =
      let role =
        Printf.sprintf
          "arn:aws:iam::%s:role/sol/%s/sol-%s-%s"
          account
          target.env
          target.env
          workload.unit
      in
      let rec check_keys = function
        | [] -> Ok ()
        | key :: rest ->
          let resource =
            Printf.sprintf
              "arn:aws:secretsmanager:%s:%s:secret:sol/%s/%s"
              target.region
              account
              target.env
              key
          in
          let* decisions =
            Result.bind
              (run
                 [ "aws"
                 ; "iam"
                 ; "simulate-principal-policy"
                 ; "--policy-source-arn"
                 ; role
                 ; "--action-names"
                 ; "secretsmanager:GetSecretValue"
                 ; "--resource-arns"
                 ; resource
                 ; "--query"
                 ; "EvaluationResults[*].EvalDecision"
                 ; "--output"
                 ; "json"
                 ])
              aws_simulation_decisions
          in
          let allowed =
            decisions <> []
            && List.for_all
                 (fun decision ->
                    String.equal (String.lowercase_ascii decision) "allowed")
                 decisions
          in
          if allowed
          then check_keys rest
          else
            Error
              (authorization_refusal
                 target
                 ~unit:workload.unit
                 ~capability:"secret"
                 ~resource:key)
      in
      check_keys workload.secrets
    in
    Sol_cli_result.map_list check_workload workloads |> Result.map ignore
;;

let gcp_secret_accessor_members output =
  let member_of = function
    | `Assoc fields ->
      (match List.assoc_opt "role" fields, List.assoc_opt "members" fields with
       | Some (`String "roles/secretmanager.secretAccessor"), Some (`List members) ->
         List.filter_map
           (function
             | `String member -> Some member
             | _ -> None)
           members
       | _ -> [])
    | _ -> []
  in
  match Yojson.Safe.from_string output with
  | `Assoc fields ->
    (match List.assoc_opt "bindings" fields with
     | Some (`List bindings) -> Ok (List.concat_map member_of bindings)
     | Some _ | None -> Ok [])
  | `List bindings -> Ok (List.concat_map member_of bindings)
  | _ -> Error "gcloud secrets get-iam-policy did not return a JSON object"
  | exception Yojson.Json_error message ->
    Error ("gcloud secrets get-iam-policy returned invalid JSON: " ^ message)
;;

let gcp_effective_access ~run (target : Sol_cli_config.target) workloads =
  let open Result.Syntax in
  let workloads =
    List.filter (fun (w : authorization_workload) -> w.secrets <> []) workloads
  in
  match workloads with
  | [] -> Ok ()
  | _ ->
    let* project = required_field target "project_id" in
    let check_workload (workload : authorization_workload) =
      let member =
        Printf.sprintf
          "serviceAccount:%s.svc.id.goog[%s/%s]"
          project
          workload.namespace
          workload.unit
      in
      let rec check_keys = function
        | [] -> Ok ()
        | key :: rest ->
          let secret = Printf.sprintf "sol-%s-%s" target.env key in
          let* members =
            Result.bind
              (run
                 [ "gcloud"
                 ; "secrets"
                 ; "get-iam-policy"
                 ; secret
                 ; "--project"
                 ; project
                 ; "--format"
                 ; "json"
                 ])
              gcp_secret_accessor_members
          in
          if List.mem member members
          then check_keys rest
          else
            Error
              (authorization_refusal
                 target
                 ~unit:workload.unit
                 ~capability:"secret"
                 ~resource:key)
      in
      check_keys workload.secrets
    in
    Sol_cli_result.map_list check_workload workloads |> Result.map ignore
;;

let aws_root_declared_vars
  :  has_postgres:bool
  -> kafka_connection:Yojson.Safe.t option
  -> production_postgres:bool
  -> ecr_repositories:(unit -> (string, string) result)
  -> ((string * string) list, string) result
  =
  fun ~has_postgres ~kafka_connection ~production_postgres ~ecr_repositories ->
  Result.map
    (fun ecr_repositories ->
       [ ( "kafka_connection"
         , Yojson.Safe.to_string (Option.value kafka_connection ~default:`Null) )
       ; "create_rds", string_of_bool has_postgres
       ; "rds_multi_az", string_of_bool production_postgres
       ; "ecr_repositories", ecr_repositories
       ])
    (ecr_repositories ())
;;

let aws_destroy_guard_vars : final_snapshot:string option -> (string * string) list =
  fun ~final_snapshot ->
  ("rds_deletion_protection", "false")
  ::
  (match final_snapshot with
   | Some identifier ->
     [ "rds_skip_final_snapshot", "false"; "rds_final_snapshot_identifier", identifier ]
   | None -> [ "rds_skip_final_snapshot", "true" ])
;;

let aws_installation_identity_contracts : identity_contract list =
  [ { identity = Sol_cli_installation.Provisioning_identity
    ; policy_output = "provisioner_policy_json"
    ; declared_as = "aws.provisioner_role_arn"
    }
  ; { identity = Sol_cli_installation.Cluster_access_identity
    ; policy_output = "cluster_access_policy_json"
    ; declared_as = "aws.cluster_access_role_arn"
    }
  ; { identity = Sol_cli_installation.Deploy_identity
    ; policy_output = "deploy_policy_json"
    ; declared_as = "aws.deploy_role_arn"
    }
  ; { identity = Sol_cli_installation.Operator_identity
    ; policy_output = "operator_policy_json"
    ; declared_as = "aws.operator_role_arn"
    }
  ]
;;

let aws : t =
  { root_status = Root_present
  ; workload_identity_issuer =
      (fun target -> aws_workload_identity_issuer ~run:run_command target)
  ; backend_config = aws_backend_config
  ; cluster_access_role_arn = aws_cluster_access_role_arn
  ; platform_storage = { storage_class = "gp3"; csi_driver = "ebs.csi.aws.com" }
  ; cluster_substrate = None
  ; installation_prerequisites =
      [ Sol_cli_installation.State_backend
      ; Sol_cli_installation.State_lock
      ; Sol_cli_installation.Provisioning_identity
      ; Sol_cli_installation.Cluster_access_identity
      ; Sol_cli_installation.Deploy_identity
      ; Sol_cli_installation.Operator_identity
      ; Sol_cli_installation.Delegated_zone
      ; Sol_cli_installation.Public_delegation
      ]
  ; installation_probes = aws_installation_probes
  ; installation_backend = aws_installation_backend
  ; installation_vars = aws_installation_vars
  ; own_vars = aws_own_vars
  ; profile_vars =
      (fun ~production ~production_postgres ->
        (if production
         then Sol_cli_profile.node_shape_vars Sol_cli_profile.recommended_node_shape
         else [])
        @ if production_postgres then [ "rds_deletion_protection", "true" ] else [])
  ; guarded_removals = [ "aws_ecr_repository" ]
  ; root_declared_vars = aws_root_declared_vars
  ; destroy_guard_vars = aws_destroy_guard_vars
  ; authority =
      Mechanism
        { matchers = [ Sol_cli_terraform_plan.Type "aws_eks_access_policy_association" ]
        ; scope = Sol_cli_terraform.targets "module.eks" []
        ; reconciliation_scope = Sol_cli_terraform.targets "module.eks"
        }
  ; guarded_addresses = [ "aws_db_instance.postgres" ]
  ; cloud_ready_expectation = "the EKS cluster and its EBS CSI addon are ACTIVE"
  ; production_qualified = true
  ; state_locking = Some "state_lock_table"
  ; installation_zone_address = "aws_route53_zone.qualification"
  ; installation_zone_import_address = "aws_route53_zone.qualification[0]"
  ; installation_zone_lookup = aws_installation_zone_lookup
  ; installation_zone_candidates = aws_installation_zone_candidates
  ; installation_nameservers_output = "dns_zone_nameservers"
  ; installation_failure_means_absent = aws_failure_means_absent
  ; installation_identity_contracts = aws_installation_identity_contracts
  ; installation_created_prerequisites =
      [ Sol_cli_installation.State_backend
      ; Sol_cli_installation.State_lock
      ; Sol_cli_installation.Delegated_zone
      ]
  ; installation_state_backend_address = "aws_s3_bucket.state"
  ; installation_retire_state_backend = Sol_cli_aws_state_backend.retire
  ; scoped_identities =
      [ "provisioner_role_arn"
      ; "cluster_access_role_arn"
      ; "deploy_role_arn"
      ; "operator_role_arn"
      ]
  ; authorization_reconciler_field = "reconciler_role_arn"
  ; authorization_trust_field = "reconciler_trust_principal_arn"
  ; authorization_destroy_trust_placeholder =
      "arn:aws:iam::000000000000:role/sol-destroy-placeholder"
  ; authorization_root_vars = aws_authorization_root_vars
  ; authorization_serverless_root_vars = aws_serverless_root_vars
  ; authorization_fence_addresses =
      [ "aws_iam_policy.workload_boundary"
      ; "aws_iam_role.reconciler"
      ; "aws_iam_role_policy.reconciler"
      ]
  ; authorization_reconciler = aws_authorization_reconciler
  ; authorization_assumption = aws_authorization_assumption
  ; authorization_principal_matches = aws_authorization_principal_matches
  ; authorization_effective_access =
      (fun target workloads -> aws_effective_access ~run:run_command target workloads)
  }
;;

let gcp_bootstrap_binding = "kubernetes_cluster_role_binding.provisioner_bootstrap_admin"

let gcp_zone_probes
  : Sol_cli_installation.installation_config -> Sol_cli_installation.probe list
  =
  fun configuration ->
  let open Sol_cli_installation in
  let zone_name =
    match Sol_cli_installation.zone_domain configuration.zone with
    | None -> None
    | Some domain ->
      Some
        (String.map
           (function
             | '.' -> '-'
             | character -> character)
           domain)
  in
  match configuration.zone, zone_name with
  | No_zone, _ -> []
  | Service_zone { domain; ownership = Externally_delegated }, _ ->
    [ unverifiable
        Delegated_zone
        (Printf.sprintf
           "%s is externally delegated: the zone lives outside Google Cloud, so the \
            delegation to this installation cannot be observed where the installation \
            looks — confirming it is the delegation wait, not a provider lookup"
           domain)
    ]
  | Service_zone { ownership; _ }, None ->
    [ unverifiable
        Delegated_zone
        (Printf.sprintf
           "the target declares %s zone ownership but names no domain, so the \
            installation cannot tell which zone to observe"
           (Sol_cli_installation.zone_ownership_declaration ownership))
    ]
  | Service_zone { domain; ownership }, Some name ->
    [ present_if_output_names
        ~reason:
          (Printf.sprintf
             "no Cloud DNS managed zone named %s for %s, although the target declares it \
              %s"
             name
             domain
             (match ownership with
              | Sol_created -> "sol-created"
              | User_supplied -> "user-supplied"
              | Externally_delegated -> "(external)"))
        Delegated_zone
        [ "gcloud"; "dns"; "managed-zones"; "describe"; name; "--format=value(name)" ]
    ]
    @ [ public_delegation_probe domain ]
;;

let gcp_installation_probes
  : Sol_cli_installation.installation_config -> Sol_cli_installation.probe list
  =
  fun configuration ->
  let open Sol_cli_installation in
  [ present_if_output_names
      ~reason:
        (Printf.sprintf "no Cloud Storage bucket gs://%s" configuration.state_bucket)
      State_backend
      [ "gcloud"
      ; "storage"
      ; "buckets"
      ; "describe"
      ; Printf.sprintf "gs://%s" configuration.state_bucket
      ; "--format=value(name)"
      ]
  ]
  @ gcp_zone_probes configuration
;;

let gcp_installation_vars
  :  manage_dns_zone:bool
  -> ?parent_zone_id:string
  -> Sol_cli_installation.installation_config
  -> (string * string) list
  =
  fun ~manage_dns_zone ?parent_zone_id configuration ->
  [ "project_id", Option.value configuration.project_id ~default:""
  ; "region", configuration.region
  ; "state_bucket", configuration.state_bucket
  ; "manage_dns_zone", fst (dns_declaration ~manage_dns_zone configuration)
  ; "base_domain", snd (dns_declaration ~manage_dns_zone configuration)
  ; "parent_zone_id", Option.value parent_zone_id ~default:""
  ]
;;

let gcp_own_vars
  :  Sol_cli_config.target
  -> workspace:string
  -> (string * string) list
  -> (string * string) list
  =
  fun target ~workspace:_ shared ->
  shared
  |> add_opt "cluster_endpoint_cidr" target.cluster_endpoint_cidr
  |> add_opt
       "provisioner_impersonators"
       (Sol_cli_config.provider_field target "provisioner_impersonator"
        |> Option.map (fun member -> Printf.sprintf "[%S]" member))
  |> add_opt
       "publisher_service_account"
       (Sol_cli_config.provider_field target "publisher_service_account")
  |> add_opt
       "create_dns_zone"
       (* The durable root owns and ensures the delegated zone for every declared
          dns_zone_ownership, so the cluster root reuses it. It must never create
          a second managed zone for base_domain: the inventory treats the zone as
          the operator's durable prerequisite, not as target residue. The choice
          is unconditional: leaving the variable unset would fall back to the
          root's create_dns_zone=true default for a target without base_domain. *)
       (Some "false")
  |> add_opt
       "gcs_soft_delete_retention_seconds"
       (Some
          (match Option.map String.trim target.destroy_retention with
           | Some "none" -> "0"
           | _ -> "604800"))
;;

(* gcloud's [=] filter is documented as not reliably exact across Google APIs,
   so the project's managed zones are listed and the exact zone is chosen by
   dnsName (see [installation_zone_candidates]). No filter is trusted to narrow
   that choice: a filter that under-matched would hide the zone and make Sol
   create a second one. *)
let gcp_installation_zone_lookup : string -> string list =
  fun _domain -> [ "gcloud"; "dns"; "managed-zones"; "list"; "--format=json" ]
;;

(* [(name, dns name, visibility)] for every managed zone the provider returned.
   Cloud DNS's default visibility is public, and a Sol installation publishes
   its delegation from a public zone. *)
let gcp_zones output =
  let open Sol_cli_json in
  let open Result.Syntax in
  let what = "the Cloud DNS managed-zone answer" in
  let* json = decode ~what output in
  let* zones = require ~what [] list json in
  zones
  |> Sol_cli_result.map_list (fun zone ->
    let* name = require ~what [ "name" ] string zone in
    let* dns_name = require ~what [ "dnsName" ] string zone in
    let* visibility = optional ~what [ "visibility" ] string zone in
    Ok (name, dns_name, Option.value visibility ~default:"public"))
;;

let gcp_installation_zone_candidates output =
  let open Result.Syntax in
  let* zones = gcp_zones output in
  zones
  |> Sol_cli_result.map_list (fun (name, dns_name, visibility) ->
    if String.equal visibility "private" then Ok None else Ok (Some (name, dns_name)))
  |> Result.map (List.filter_map (fun candidate -> candidate))
;;

let gcp : t =
  { root_status = Root_present
  ; workload_identity_issuer =
      (fun target -> gcp_workload_identity_issuer ~run:run_command target)
  ; backend_config =
      (fun _target ~bucket ~object_key ->
        Ok [ "bucket=" ^ bucket; "prefix=" ^ object_key ])
  ; cluster_access_role_arn = (fun _target -> Ok None)
  ; platform_storage =
      { storage_class = "standard-rwo"; csi_driver = "pd.csi.storage.gke.io" }
  ; cluster_substrate =
      Some
        (fun ~outputs_json ~region ~cluster_name ->
          Sol_cli_gcp_cluster.substrate_of_describe ~outputs_json ~region ~cluster_name)
  ; installation_prerequisites =
      [ Sol_cli_installation.State_backend
      ; Sol_cli_installation.Delegated_zone
      ; Sol_cli_installation.Public_delegation
      ]
  ; installation_probes = gcp_installation_probes
  ; installation_backend =
      (fun configuration ->
        Ok
          [ "bucket=" ^ configuration.state_bucket
          ; "prefix=" ^ configuration.state_prefix
          ])
  ; installation_vars = gcp_installation_vars
  ; own_vars = gcp_own_vars
  ; profile_vars = (fun ~production:_ ~production_postgres:_ -> [])
  ; guarded_removals = []
  ; root_declared_vars =
      (* GCP used to ignore this flag and declare Cloud SQL unconditionally, so omitting a
         postgres resource stopped provisioning on AWS and not on GCP. Both providers now
         derive provisioning from the same resolved ownership decision. *)
      (fun ~has_postgres ~kafka_connection ~production_postgres ~ecr_repositories:_ ->
        Ok
          [ "create_database", string_of_bool has_postgres
          ; "sql_high_availability", string_of_bool production_postgres
          ; "sql_deletion_protection", string_of_bool production_postgres
          ; ( "kafka_connection"
            , Yojson.Safe.to_string (Option.value kafka_connection ~default:`Null) )
          ])
  ; destroy_guard_vars =
      (fun ~final_snapshot:_ ->
        [ "sql_deletion_protection", "false"; "gke_deletion_protection", "false" ])
  ; authority =
      Mechanism
        { matchers = [ Sol_cli_terraform_plan.Resource gcp_bootstrap_binding ]
        ; scope = Sol_cli_terraform.targets gcp_bootstrap_binding []
        ; reconciliation_scope = Sol_cli_terraform.targets gcp_bootstrap_binding
        }
  ; guarded_addresses =
      [ "google_sql_database_instance.postgres"; "google_container_cluster.main" ]
  ; cloud_ready_expectation =
      "the GKE cluster is RUNNING and the Cloud SQL instance is RUNNABLE"
  ; production_qualified = true
  ; state_locking = None
  ; installation_zone_address = "google_dns_managed_zone.qualification"
  ; installation_zone_import_address = "google_dns_managed_zone.qualification[0]"
  ; installation_zone_lookup = gcp_installation_zone_lookup
  ; installation_zone_candidates = gcp_installation_zone_candidates
  ; installation_nameservers_output = "dns_zone_nameservers"
  ; installation_failure_means_absent = gcp_failure_means_absent
  ; installation_identity_contracts = []
  ; installation_created_prerequisites =
      [ Sol_cli_installation.State_backend; Sol_cli_installation.Delegated_zone ]
  ; installation_state_backend_address = "google_storage_bucket.state"
  ; installation_retire_state_backend = Sol_cli_gcp_state_backend.retire
  ; scoped_identities = []
  ; authorization_reconciler_field = "reconciler_service_account"
  ; authorization_trust_field = "reconciler_trust_principal"
  ; authorization_destroy_trust_placeholder =
      "user:sol-destroy-placeholder@example.invalid"
  ; authorization_root_vars = gcp_authorization_root_vars
  ; authorization_serverless_root_vars = gcp_serverless_root_vars
  ; authorization_fence_addresses =
      [ "google_service_account.reconciler"
      ; "google_project_iam_custom_role.authorization"
      ; "google_project_iam_member.reconciler_authorization"
      ; "google_service_account_iam_member.reconciler_impersonation"
      ]
  ; authorization_reconciler = gcp_authorization_reconciler
  ; authorization_assumption = gcp_authorization_assumption
  ; authorization_principal_matches = gcp_authorization_principal_matches
  ; authorization_effective_access =
      (fun target workloads -> gcp_effective_access ~run:run_command target workloads)
  }
;;

let byo_no_root =
  "the byo driver owns no cloud Terraform root: it is bring-your-own infrastructure, so \
   Sol has no provider lifecycle to run for it (DEC-051)"
;;

let byo_no_workload_issuer =
  "the byo driver does not own the cluster's lifecycle, so Sol does not establish a \
   trusted Kubernetes service-account OIDC issuer for it (DEC-051)"
;;

let byo : t =
  { root_status = Root_not_applicable
  ; workload_identity_issuer = (fun _ -> Error byo_no_workload_issuer)
  ; backend_config = (fun _ ~bucket:_ ~object_key:_ -> Error byo_no_root)
  ; cluster_access_role_arn = (fun _ -> Ok None)
  ; platform_storage = { storage_class = ""; csi_driver = "" }
  ; cluster_substrate = None
  ; installation_prerequisites = []
  ; installation_probes = (fun _ -> [])
  ; installation_backend = (fun _ -> Error byo_no_root)
  ; installation_vars = (fun ~manage_dns_zone:_ ?parent_zone_id:_ _ -> [])
  ; installation_zone_address = ""
  ; installation_zone_import_address = ""
  ; installation_zone_lookup = (fun _ -> [])
  ; installation_zone_candidates = (fun _ -> Ok [])
  ; installation_nameservers_output = ""
  ; installation_failure_means_absent = (fun _ -> false)
  ; installation_identity_contracts = []
  ; installation_created_prerequisites = []
  ; installation_state_backend_address = ""
  ; installation_retire_state_backend = (fun ~run:_ _ -> Ok ())
  ; own_vars = (fun _ ~workspace:_ shared -> shared)
  ; profile_vars = (fun ~production:_ ~production_postgres:_ -> [])
  ; guarded_removals = []
  ; root_declared_vars =
      (fun ~has_postgres:_
        ~kafka_connection:_
        ~production_postgres:_
        ~ecr_repositories:_ -> Ok [])
  ; destroy_guard_vars = (fun ~final_snapshot:_ -> [])
  ; authority = No_authority_required
  ; guarded_addresses = []
  ; cloud_ready_expectation = "the bring-your-own cluster is reachable"
  ; production_qualified = false
  ; state_locking = None
  ; scoped_identities = []
  ; authorization_reconciler_field = ""
  ; authorization_trust_field = ""
  ; authorization_destroy_trust_placeholder = ""
  ; authorization_root_vars = (fun _ -> Ok [])
  ; authorization_serverless_root_vars = (fun _ _ -> Error byo_no_root)
  ; authorization_fence_addresses = []
  ; authorization_reconciler = (fun _ -> Error byo_no_root)
  ; authorization_assumption = (fun _ -> Error byo_no_root)
  ; authorization_principal_matches = (fun _ ~principal:_ -> Error byo_no_root)
  ; authorization_effective_access = (fun _ _ -> Ok ())
  }
;;

let capabilities_of = function
  | Sol_cli_provider.Aws -> aws
  | Sol_cli_provider.Gcp -> gcp
  | Sol_cli_provider.Byo -> byo
;;

let authorization_trust (target : Sol_cli_config.target) =
  let capabilities = capabilities_of target.provider in
  match Sol_cli_config.provider_field target capabilities.authorization_trust_field with
  | Some value when not (Sol_cli_string.is_blank value) -> Some value
  | Some _ | None -> None
;;

let validate_target provider (target : Sol_cli_config.target) =
  let retention =
    match Option.map String.trim target.destroy_retention with
    | None | Some "final-snapshot" | Some "none" -> Ok ()
    | Some other ->
      Error
        (Printf.sprintf
           "unknown destroy_retention %S for target %s (expected \"final-snapshot\" or \
            \"none\")"
           other
           target.name)
  in
  match retention with
  | Error _ as error -> error
  | Ok () ->
    (match provider with
     | Sol_cli_provider.Gcp ->
       (match target.cluster_name with
        | Some cluster_name -> Sol_cli_gcp_cluster.validate_cluster_name cluster_name
        | None -> Ok ())
     | Sol_cli_provider.Aws | Sol_cli_provider.Byo -> Ok ())
;;

let owns_root provider = (capabilities_of provider).root_status = Root_present

let provider_console_url (target : Sol_cli_config.target) =
  match target.provider with
  | Sol_cli_provider.Aws ->
    Some
      (Printf.sprintf
         "https://console.aws.amazon.com/eks/home?region=%s#/clusters"
         target.region)
  | Sol_cli_provider.Gcp ->
    (match Sol_cli_config.provider_field target "project_id" with
     | Some project when not (Sol_cli_string.is_blank project) ->
       Some
         (Printf.sprintf
            "https://console.cloud.google.com/kubernetes/list/overview?project=%s"
            (String.trim project))
     | _ -> None)
  | Sol_cli_provider.Byo -> None
;;

let installation_nameservers_output provider =
  (capabilities_of provider).installation_nameservers_output
;;

let installation_identity_contracts provider =
  (capabilities_of provider).installation_identity_contracts
;;

let installation_prerequisites provider =
  (capabilities_of provider).installation_prerequisites
;;

let installation_created_prerequisites provider =
  (capabilities_of provider).installation_created_prerequisites
;;

let installation_probes provider configuration =
  (capabilities_of provider).installation_probes configuration
;;

let installation_backend provider configuration =
  (capabilities_of provider).installation_backend configuration
;;

let installation_vars provider ~manage_dns_zone ?parent_zone_id configuration =
  (capabilities_of provider).installation_vars
    ~manage_dns_zone
    ?parent_zone_id
    configuration
;;

let installation_observation ~provider argv =
  let absent_when = (capabilities_of provider).installation_failure_means_absent in
  match Sol_cli_process.run (Sol_cli_process.cmd argv) with
  | Ok output -> Sol_cli_installation.Observed output.stdout
  | Error (Sol_cli_process.Non_zero failure) ->
    let message = Sol_cli_process.failure_message failure in
    if absent_when message
    then Sol_cli_installation.Absent message
    else Sol_cli_installation.Unobservable message
  | Error error ->
    Sol_cli_installation.Unobservable (Sol_cli_process.error_to_string error)
;;

let observe_installation (target_cfg : Sol_cli_config.target) =
  let provider = target_cfg.Sol_cli_config.provider in
  match Sol_cli_installation.of_target target_cfg with
  | Error message -> Error message
  | Ok configuration ->
    let verdicts =
      installation_probes provider configuration
      |> Sol_cli_installation.observe ~run:(installation_observation ~provider)
    in
    Ok (configuration, verdicts)
;;
