let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let aws_config : Sol_cli_installation.installation_config =
  { state_bucket = "sol-state-test"
  ; state_prefix = "bootstrap/aws"
  ; region = "eu-west-1"
  ; lock_table = Some "sol-lock-test"
  ; provisioning_identity = Some "sol-provisioner"
  ; cluster_access_identity = Some "sol-cluster-access"
  ; deploy_identity = Some "sol-deploy"
  ; operator_identity = Some "sol-operator"
  ; zone =
      Sol_cli_installation.Service_zone
        { domain = "qual-aws.example.test"; ownership = Sol_cli_installation.Sol_created }
  ; project_id = None
  }
;;

let gcp_config : Sol_cli_installation.installation_config =
  { aws_config with
    state_prefix = "bootstrap/gcp"
  ; lock_table = None
  ; provisioning_identity = None
  ; cluster_access_identity = None
  ; deploy_identity = None
  ; operator_identity = None
  ; zone =
      Sol_cli_installation.Service_zone
        { domain = "qual-gcp.example.test"; ownership = Sol_cli_installation.Sol_created }
  ; project_id = Some "sol-project"
  }
;;

let probe_prerequisites provider config =
  Sol_cli_provider_capabilities.installation_probes provider config
  |> List.map Sol_cli_installation.probe_prerequisite
;;

let aws_target : Sol_cli_config.target =
  { name = "prod/aws/us-east-1"
  ; env = "prod"
  ; provider = Sol_cli_provider.Aws
  ; region = "us-east-1"
  ; registry = None
  ; base_domain = Some "api.acme.example"
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name = Some "acme-prod"
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; observability_logs_url = None
  ; observability_logs_username = None
  ; observability_logs_password_env = None
  ; observability_metrics_url = None
  ; observability_metrics_username = None
  ; observability_metrics_password_env = None
  ; observability_traces_url = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = Some "acme-tfstate"
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = Some "sol"
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; shape = Some Sol_cli_profile.Local
  ; provider_fields =
      [ ( "aws"
        , [ "state_lock_table", "acme-tflock"
          ; "provisioner_role_arn", "arn:aws:iam::111122223333:role/sol-provisioner"
          ; "cluster_access_role_arn", "arn:aws:iam::111122223333:role/sol-cluster-access"
          ; "deploy_role_arn", "arn:aws:iam::111122223333:role/sol-deploy"
          ; "operator_role_arn", "arn:aws:iam::111122223333:role/sol-operator"
          ] )
      ]
  ; secret_authorities = []
  }
;;

let gcp_target : Sol_cli_config.target =
  { aws_target with
    name = "qual/gcp/us-central1"
  ; env = "qual"
  ; provider = Sol_cli_provider.Gcp
  ; region = "us-central1"
  ; state_bucket = Some "sol-qualification-tfstate"
  ; base_domain = Some "qual-gcp.example.test"
  ; provider_fields = [ "gcp", [ "project_id", "sol-qualification" ] ]
  ; secret_authorities = []
  }
;;

let resolved_or_fail target =
  match Sol_cli_installation.of_target target with
  | Ok configuration -> configuration
  | Error message -> Windtrap.fail ("of_target refused a declared target: " ^ message)
;;

let probe_argv provider configuration prerequisite =
  Sol_cli_provider_capabilities.installation_probes provider configuration
  |> List.find_map (fun probe ->
    match probe with
    | Sol_cli_installation.Inspect probe when probe.prerequisite = prerequisite ->
      Some probe.argv
    | Sol_cli_installation.Inspect _
    | Sol_cli_installation.Unavailable _
    | Sol_cli_installation.Unverifiable _ -> None)
;;

let test_probe_coverage () =
  List.iter
    (fun (name, provider, config) ->
       let expected = Sol_cli_provider_capabilities.installation_prerequisites provider in
       let actual = probe_prerequisites provider config in
       Windtrap.equal
         (Windtrap.list Windtrap.string)
         ~msg:(name ^ ": every prerequisite is probed exactly once")
         (List.map Sol_cli_installation.prerequisite_label expected)
         (List.map Sol_cli_installation.prerequisite_label actual);
       let sorted = List.sort compare actual in
       let unique = List.sort_uniq compare actual in
       Windtrap.equal
         Windtrap.int
         ~msg:(name ^ ": no duplicate probes")
         (List.length sorted)
         (List.length unique))
    [ "aws", Sol_cli_provider.Aws, aws_config; "gcp", Sol_cli_provider.Gcp, gcp_config ]
;;

let test_provider_sets_are_not_the_same_shape () =
  let aws =
    Sol_cli_provider_capabilities.installation_prerequisites Sol_cli_provider.Aws
  in
  let gcp =
    Sol_cli_provider_capabilities.installation_prerequisites Sol_cli_provider.Gcp
  in
  check_bool
    "the AWS root declares a lock table"
    true
    (List.mem Sol_cli_installation.State_lock aws);
  check_bool
    "the GCP root does not (its state bucket locks itself)"
    false
    (List.mem Sol_cli_installation.State_lock gcp);
  check_bool
    "the AWS root declares the four identities the target resolves as role ARNs"
    true
    (List.mem Sol_cli_installation.Provisioning_identity aws
     && List.mem Sol_cli_installation.Cluster_access_identity aws
     && List.mem Sol_cli_installation.Deploy_identity aws
     && List.mem Sol_cli_installation.Operator_identity aws);
  check_bool
    "the GCP durable root declares no identity of its own, so GCP has none to observe"
    false
    (List.mem Sol_cli_installation.Provisioning_identity gcp
     || List.mem Sol_cli_installation.Cluster_access_identity gcp
     || List.mem Sol_cli_installation.Deploy_identity gcp
     || List.mem Sol_cli_installation.Operator_identity gcp);
  check_bool
    "both installations are observed for the durable state and the delegated zone"
    true
    (List.mem Sol_cli_installation.State_backend aws
     && List.mem Sol_cli_installation.State_backend gcp
     && List.mem Sol_cli_installation.Delegated_zone aws
     && List.mem Sol_cli_installation.Delegated_zone gcp)
;;

let test_unobservable_is_never_established () =
  let probes =
    [ Sol_cli_installation.Inspect
        { prerequisite = Sol_cli_installation.State_backend
        ; argv = [ "aws"; "s3api"; "head-bucket" ]
        ; classify = (fun _ -> Sol_cli_installation.Established)
        }
    ]
  in
  match
    Sol_cli_installation.observe
      ~run:(fun _ -> Sol_cli_installation.Unobservable "no aws CLI in PATH")
      probes
  with
  | [ (_, verdict) ] ->
    (match verdict with
     | Sol_cli_installation.Unknown reason ->
       check_bool "the refusal says why" true (String.length reason > 0)
     | Sol_cli_installation.Established ->
       Windtrap.fail "a probe that could not run was reported Established"
     | Sol_cli_installation.Unmet reason ->
       Windtrap.fail ("expected Unknown, got Unmet: " ^ reason))
  | _ -> Windtrap.fail "expected one verdict"
;;

let test_a_refused_probe_is_unmet () =
  let probes =
    [ Sol_cli_installation.present_if_output
        Sol_cli_installation.State_backend
        [ "aws"; "s3api"; "head-bucket" ]
    ]
  in
  match
    Sol_cli_installation.observe
      ~run:(fun _ -> Sol_cli_installation.Absent "aws exited with code 254: Not Found")
      probes
  with
  | [ (_, Sol_cli_installation.Unmet reason) ] ->
    check_bool
      "the provider's own answer is carried through"
      true
      (String.length reason > 0)
  | [ (_, Sol_cli_installation.Unknown reason) ] ->
    Windtrap.fail ("a probe that ran and refused is Unmet, not UNKNOWN: " ^ reason)
  | [ (_, Sol_cli_installation.Established) ] ->
    Windtrap.fail "a refused probe was reported Established"
  | _ -> Windtrap.fail "expected one verdict"
;;

let test_observation_drives_the_verdict () =
  let probes =
    [ Sol_cli_installation.present_if_output
        Sol_cli_installation.State_backend
        [ "aws"; "s3api"; "head-bucket" ]
    ]
  in
  match
    Sol_cli_installation.observe ~run:(fun _ -> Sol_cli_installation.Observed "ok") probes
  with
  | [ (_, Sol_cli_installation.Established) ] -> ()
  | _ -> Windtrap.fail "an observed resource should be Established"
;;

let test_missing_configuration_is_unmet () =
  let bare =
    { aws_config with
      lock_table = None
    ; provisioning_identity = None
    ; cluster_access_identity = None
    ; deploy_identity = None
    ; operator_identity = None
    ; zone = Sol_cli_installation.No_zone
    }
  in
  let inspected = ref [] in
  let verdicts =
    Sol_cli_provider_capabilities.installation_probes Sol_cli_provider.Aws bare
    |> Sol_cli_installation.observe ~run:(fun argv ->
      inspected := argv :: !inspected;
      Sol_cli_installation.Observed "present")
  in
  Windtrap.equal
    Windtrap.int
    ~msg:"only the state backend is inspected"
    1
    (List.length !inspected);
  List.iter
    (fun (prerequisite, verdict) ->
       match prerequisite, verdict with
       | Sol_cli_installation.State_backend, _ ->
         check_bool "the state backend is still inspected" true true
       | _, Sol_cli_installation.Unmet reason ->
         check_bool
           (Sol_cli_installation.prerequisite_label prerequisite ^ " says what is missing")
           true
           (String.length reason > 0)
       | _, Sol_cli_installation.Unknown _ ->
         Windtrap.fail "an absent configuration value is Unmet, not UNKNOWN"
       | _, Sol_cli_installation.Established ->
         Windtrap.fail "nothing is established in an empty configuration")
    verdicts
;;

let test_all_established_fails_closed () =
  let open Sol_cli_installation in
  let ok = [ State_backend, establish; Delegated_zone, establish ] in
  check_bool "all established is Ok" true (all_established ok = Ok ());
  (match
     all_established [ State_backend, establish; State_lock, unknown "no answer" ]
   with
   | Error message ->
     check_string
       "the refusal names the prerequisite and its reason"
       "terraform state lock is UNKNOWN: no answer"
       message
   | Ok () -> Windtrap.fail "UNKNOWN must fail closed");
  match all_established [ State_backend, unmet "no bucket" ] with
  | Error message ->
    check_string
      "Unmet fails closed too"
      "terraform state backend is Unmet: no bucket"
      message
  | Ok () -> Windtrap.fail "Unmet must fail closed"
;;

let test_the_health_summary_never_promotes_an_unknown () =
  let open Sol_cli_installation in
  check_string
    "an established installation is Healthy"
    "Healthy"
    (health_summary [ State_backend, establish; Delegated_zone, establish ]);
  let unmet_summary =
    health_summary [ State_backend, establish; State_lock, unmet "no such table" ]
  in
  check_bool
    "an unmet prerequisite reads as Unmet"
    true
    (Sol_cli_string.contains ~needle:"Unmet — " unmet_summary);
  check_bool
    "and carries the provider's own reason"
    true
    (Sol_cli_string.contains ~needle:"terraform state lock: no such table" unmet_summary);
  let unknown_summary =
    health_summary [ State_backend, establish; Deploy_identity, unknown "could not look" ]
  in
  check_bool
    "an unobservable prerequisite is never Unmet"
    false
    (Sol_cli_string.contains ~needle:"Unmet" unknown_summary);
  check_bool
    "and reads as Unknown"
    true
    (Sol_cli_string.contains ~needle:"Unknown — " unknown_summary);
  check_bool "and is never Healthy" false (String.equal unknown_summary "Healthy");
  let mixed =
    health_summary
      [ State_backend, unmet "no bucket"; Deploy_identity, unknown "could not look" ]
  in
  check_bool
    "a mixed answer takes the weaker headline"
    true
    (Sol_cli_string.contains ~needle:"Unknown — " mixed);
  check_bool
    "and still names the unmet prerequisite"
    true
    (Sol_cli_string.contains ~needle:"terraform state backend: no bucket" mixed)
;;

let test_resolves_the_declared_installation () =
  let aws = resolved_or_fail aws_target in
  check_string
    "the state prefix is derived plumbing, not a declaration"
    "bootstrap/aws"
    aws.state_prefix;
  check_string "the bucket is the target's declaration" "acme-tfstate" aws.state_bucket;
  check_string "the region is the target's declaration" "us-east-1" aws.region;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the lock table is the target's declaration"
    (Some "acme-tflock")
    aws.lock_table;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the provisioning identity is the declared ARN"
    (Some "arn:aws:iam::111122223333:role/sol-provisioner")
    aws.provisioning_identity;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the delegated zone follows the served domain"
    (Some "api.acme.example")
    (Sol_cli_installation.zone_domain aws.zone);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"an AWS installation names no project"
    None
    aws.project_id;
  let gcp = resolved_or_fail gcp_target in
  check_string "the GCP prefix is derived too" "bootstrap/gcp" gcp.state_prefix;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the GCP root declares no lock table, so none is resolved"
    None
    gcp.lock_table;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the GCP project is the target's declaration"
    (Some "sol-qualification")
    gcp.project_id;
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the GCP durable root declares no identity, so none is resolved"
    None
    gcp.deploy_identity
;;

let test_the_state_backend_is_required () =
  match Sol_cli_installation.of_target { aws_target with state_bucket = None } with
  | Ok _ -> Windtrap.fail "an installation with no state backend was resolved"
  | Error message ->
    check_bool
      "the refusal names what is missing"
      true
      (Sol_cli_string.contains ~needle:"state_bucket" message)
;;

let test_the_role_probe_names_the_role_not_the_arn () =
  let configuration = resolved_or_fail aws_target in
  match
    probe_argv
      Sol_cli_provider.Aws
      configuration
      Sol_cli_installation.Provisioning_identity
  with
  | Some argv ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"get-role takes the role name, derived from the declared ARN"
      [ "aws"; "iam"; "get-role"; "--role-name"; "sol-provisioner" ]
      argv
  | None -> Windtrap.fail "the provisioning identity has no probe"
;;

let test_the_gcp_zone_probe_uses_the_zone_name_terraform_creates () =
  let configuration = resolved_or_fail gcp_target in
  match
    probe_argv Sol_cli_provider.Gcp configuration Sol_cli_installation.Delegated_zone
  with
  | Some argv ->
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"the durable root names its zone by replacing the dots"
      [ "gcloud"
      ; "dns"
      ; "managed-zones"
      ; "describe"
      ; "qual-gcp-example-test"
      ; "--format=value(name)"
      ]
      argv
  | None -> Windtrap.fail "the delegated zone has no probe"
;;

let test_the_durable_root_is_configured_from_the_declaration () =
  let aws = resolved_or_fail aws_target in
  (match Sol_cli_provider_capabilities.installation_backend Sol_cli_provider.Aws aws with
   | Error message ->
     Windtrap.fail ("the AWS durable root's backend was refused: " ^ message)
   | Ok backend ->
     Windtrap.equal
       (Windtrap.list Windtrap.string)
       ~msg:"the durable root's own state lives under the derived prefix"
       [ "bucket=acme-tfstate"
       ; "key=bootstrap/aws/default.tfstate"
       ; "region=us-east-1"
       ; "dynamodb_table=acme-tflock"
       ; "encrypt=true"
       ]
       backend);
  (match
     Sol_cli_provider_capabilities.installation_vars
       Sol_cli_provider.Aws
       ~manage_dns_zone:true
       aws
   with
   | [ (_, "us-east-1")
     ; (_, "acme-tfstate")
     ; (_, "acme-tflock")
     ; ("manage_dns_zone", "true")
     ; ("base_domain", "api.acme.example")
     ; ("parent_zone_id", "")
     ] -> ()
   | vars ->
     Windtrap.fail
       ("the AWS durable root's variables are not the declared ones: "
        ^ String.concat "," (List.map fst vars)));
  let gcp = resolved_or_fail gcp_target in
  (match Sol_cli_provider_capabilities.installation_backend Sol_cli_provider.Gcp gcp with
   | Error message ->
     Windtrap.fail ("the GCP durable root's backend was refused: " ^ message)
   | Ok backend ->
     Windtrap.equal
       (Windtrap.list Windtrap.string)
       ~msg:"the GCP backend is a prefix, not a key"
       [ "bucket=sol-qualification-tfstate"; "prefix=bootstrap/gcp" ]
       backend);
  let no_zone =
    Sol_cli_provider_capabilities.installation_vars
      Sol_cli_provider.Aws
      ~manage_dns_zone:false
      aws
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"a root that does not own the zone is told so"
    (Some "false")
    (List.assoc_opt "manage_dns_zone" no_zone)
;;

let test_the_durable_root_refuses_an_incomplete_declaration () =
  let aws = resolved_or_fail aws_target in
  (match
     Sol_cli_provider_capabilities.installation_backend
       Sol_cli_provider.Aws
       { aws with lock_table = None }
   with
   | Ok _ -> Windtrap.fail "an AWS root with no lock table was configured"
   | Error message ->
     check_bool
       "the refusal names the lock table"
       true
       (Sol_cli_string.contains ~needle:"state_lock_table" message));
  let gcp = resolved_or_fail gcp_target in
  match
    Sol_cli_provider_capabilities.installation_vars
      Sol_cli_provider.Gcp
      ~manage_dns_zone:false
      { gcp with project_id = None }
  with
  | vars ->
    Windtrap.equal
      (Windtrap.option Windtrap.string)
      ~msg:"a GCP root with no project still passes what the target declared"
      (Some "")
      (List.assoc_opt "project_id" vars)
;;

let test_the_durable_root_policy_refuses_recreation () =
  let open Sol_cli_terraform_plan in
  let change address action =
    { address; resource_type = "aws_s3_bucket"; mode = "managed"; action }
  in
  let policy = Sol_cli_installation_stage.durable_root_policy in
  Windtrap.equal
    Windtrap.int
    ~msg:"a metadata-only change is permitted"
    0
    (List.length (violations policy [ change "aws_s3_bucket.state" Update ]));
  Windtrap.equal
    Windtrap.int
    ~msg:"a creation is permitted, so the root can gain a durable resource"
    0
    (List.length (violations policy [ change "aws_dynamodb_table.lock" Create ]));
  Windtrap.equal
    Windtrap.int
    ~msg:"a replacement is refused"
    1
    (List.length (violations policy [ change "aws_s3_bucket.state" Replace ]));
  Windtrap.equal
    Windtrap.int
    ~msg:"a destruction is refused"
    1
    (List.length
       (violations policy [ change "aws_route53_zone.qualification[0]" Delete ]))
;;

let test_resolved_configuration_has_no_authority () =
  let lines = Sol_cli_installation.resolved_configuration_to_lines aws_config in
  check_bool "the resolved configuration is inspectable" true (List.length lines >= 6);
  check_bool
    "it names derived plumbing"
    true
    (List.exists (fun line -> String.contains line 'e' && String.length line > 10) lines);
  check_bool
    "it declares no authority grant"
    false
    (List.exists
       (fun line ->
          let lowered = String.lowercase_ascii line in
          List.exists
            (fun marker ->
               String.length lowered > 0
               &&
               try
                 ignore (Str.search_forward (Str.regexp_string marker) lowered 0);
                 true
               with
               | Not_found -> false)
            [ "policy"; "grant"; "accountab"; "audit" ])
       lines)
;;

let with_ownership ownership =
  { aws_config with
    zone = Sol_cli_installation.Service_zone { domain = "api.acme.example"; ownership }
  }
;;

let test_zone_ownership_is_three_distinguishable_cases () =
  let declared = Sol_cli_installation.zone_ownership_of_declaration in
  check_bool
    "sol means the installation creates and owns the zone"
    true
    (declared (Some "sol") = Ok Sol_cli_installation.Sol_created);
  check_bool
    "user means the operator created it and Sol never removes it"
    true
    (declared (Some "user") = Ok Sol_cli_installation.User_supplied);
  check_bool
    "external means someone else publishes the zone"
    true
    (declared (Some "external") = Ok Sol_cli_installation.Externally_delegated);
  (match declared (Some "sol-created") with
   | Error message ->
     check_bool
       "an unknown value is refused rather than guessed, naming the accepted set"
       true
       (Sol_cli_string.contains ~needle:"dns_zone_ownership" message
        && Sol_cli_string.contains ~needle:"sol" message
        && Sol_cli_string.contains ~needle:"user" message
        && Sol_cli_string.contains ~needle:"external" message)
   | Ok _ -> Windtrap.fail "an unknown ownership value was accepted");
  match declared None with
  | Error message ->
    check_bool
      "an absent declaration is refused, naming the key"
      true
      (Sol_cli_string.contains ~needle:"dns_zone_ownership" message)
  | Ok _ -> Windtrap.fail "an absent ownership declaration was accepted"
;;

let test_ownership_reaches_the_resolved_configuration () =
  let lines ownership =
    String.concat
      "\n"
      (Sol_cli_installation.resolved_configuration_to_lines (with_ownership ownership))
  in
  check_bool
    "a Sol-owned zone says so"
    true
    (Sol_cli_string.contains
       ~needle:"sol-created"
       (lines Sol_cli_installation.Sol_created));
  check_bool
    "a user-supplied zone says Sol never removes it"
    true
    (Sol_cli_string.contains
       ~needle:"user-supplied (Sol never removes it)"
       (lines Sol_cli_installation.User_supplied));
  check_bool
    "an externally delegated zone says the parent is the operator's"
    true
    (Sol_cli_string.contains
       ~needle:"externally delegated"
       (lines Sol_cli_installation.Externally_delegated));
  check_bool
    "a target that serves no domain says so"
    true
    (Sol_cli_string.contains
       ~needle:"serves no domain"
       (String.concat
          "\n"
          (Sol_cli_installation.resolved_configuration_to_lines
             { aws_config with zone = Sol_cli_installation.No_zone })))
;;

let test_owns_the_zone_follows_the_declaration () =
  check_bool
    "only a Sol-created zone is the installation's to reconcile"
    true
    (Sol_cli_installation.owns_the_zone
       (with_ownership Sol_cli_installation.Sol_created).zone);
  check_bool
    "a user-supplied zone is not"
    false
    (Sol_cli_installation.owns_the_zone
       (with_ownership Sol_cli_installation.User_supplied).zone);
  check_bool
    "an externally delegated zone is not"
    false
    (Sol_cli_installation.owns_the_zone
       (with_ownership Sol_cli_installation.Externally_delegated).zone);
  check_bool
    "and neither is a target that serves no domain"
    false
    (Sol_cli_installation.owns_the_zone Sol_cli_installation.No_zone)
;;

let test_external_delegation_is_unverifiable_not_unmet () =
  let config = with_ownership Sol_cli_installation.Externally_delegated in
  List.iter
    (fun (name, provider) ->
       let run argv =
         if
           List.exists
             (fun argument -> Sol_cli_string.contains ~needle:"api.acme.example" argument)
             argv
         then Windtrap.fail (name ^ " looked the zone up at the provider")
         else Sol_cli_installation.Observed "present"
       in
       let verdict =
         Sol_cli_provider_capabilities.installation_probes provider config
         |> Sol_cli_installation.observe ~run
         |> List.find (fun (prerequisite, _) ->
           prerequisite = Sol_cli_installation.Delegated_zone)
         |> snd
       in
       match verdict with
       | Sol_cli_installation.Unknown reason ->
         check_bool
           (name ^ ": the reason names the domain and the delegation")
           true
           (Sol_cli_string.contains ~needle:"api.acme.example" reason
            && Sol_cli_string.contains ~needle:"delegation" reason)
       | Sol_cli_installation.Unmet reason ->
         Windtrap.fail
           (name ^ ": an unobservable delegation was reported Unmet: " ^ reason)
       | Sol_cli_installation.Established ->
         Windtrap.fail (name ^ ": an unobservable delegation was reported Established"))
    [ "aws", Sol_cli_provider.Aws; "gcp", Sol_cli_provider.Gcp ]
;;

let test_a_target_that_serves_no_domain_has_no_zone_prerequisite () =
  List.iter
    (fun (name, provider) ->
       let probes =
         Sol_cli_provider_capabilities.installation_probes
           provider
           { aws_config with zone = Sol_cli_installation.No_zone }
       in
       check_bool
         (name ^ ": nothing to observe about a zone that does not exist")
         false
         (List.exists
            (fun probe ->
               Sol_cli_installation.probe_prerequisite probe
               = Sol_cli_installation.Delegated_zone)
            probes))
    [ "aws", Sol_cli_provider.Aws; "gcp", Sol_cli_provider.Gcp ];
  match
    Sol_cli_installation.of_target
      { aws_target with base_domain = None; dns_zone_ownership = None }
  with
  | Ok configuration ->
    check_bool
      "a target with no domain resolves to no zone"
      true
      (configuration.zone = Sol_cli_installation.No_zone)
  | Error message -> Windtrap.fail ("of_target refused a domain-less target: " ^ message)
;;

let test_the_declaration_is_required_when_a_domain_is_declared () =
  match Sol_cli_installation.of_target { aws_target with dns_zone_ownership = None } with
  | Ok _ ->
    Windtrap.fail "a target with a domain and no ownership declaration was accepted"
  | Error message ->
    check_bool
      "the refusal names the missing declaration"
      true
      (Sol_cli_string.contains ~needle:"dns_zone_ownership" message)
;;

let await_delegation ?(expected = []) ~attempts observations =
  let remaining = ref observations in
  let runs = ref 0 in
  let reports = ref [] in
  let run _ =
    incr runs;
    match !remaining with
    | [] -> Sol_cli_installation.Observed ""
    | observation :: rest ->
      remaining := rest;
      observation
  in
  let verdict =
    Sol_cli_installation_stage.await_delegation
      ~run
      ~report:(fun line -> reports := line :: !reports)
      ~attempts
      ~interval:0.
      ~domain:"api.acme.example"
      ~expected
      ()
  in
  verdict, List.rev !reports, !runs
;;

let test_the_wait_succeeds_when_the_delegation_appears () =
  let verdict, reports, runs =
    await_delegation
      ~expected:[ "ns-1.awsdns.test"; "ns-2.awsdns.test" ]
      ~attempts:5
      [ Sol_cli_installation.Observed "ns-other.example"
      ; Sol_cli_installation.Observed "ns-1.awsdns.test\nns-2.awsdns.test"
      ]
  in
  check_bool
    "the delegation is Established once the resolver names the zone's nameservers"
    true
    (verdict = Sol_cli_installation.Established);
  check_bool "the wait stopped as soon as it succeeded" true (runs = 2);
  check_bool
    "a partial answer is reported as pending, not accepted"
    true
    (List.length reports = 1)
;;

let test_the_wait_gives_up_and_says_what_it_saw () =
  let verdict, reports, runs =
    await_delegation
      ~expected:[ "ns-1.awsdns.test" ]
      ~attempts:3
      [ Sol_cli_installation.Observed "ns-other.example"
      ; Sol_cli_installation.Observed "ns-other.example"
      ; Sol_cli_installation.Observed "ns-other.example"
      ]
  in
  (match verdict with
   | Sol_cli_installation.Unmet reason ->
     check_bool
       "giving up names what the resolver kept answering"
       true
       (Sol_cli_string.contains ~needle:"ns-other.example" reason)
   | Sol_cli_installation.Established | Sol_cli_installation.Unknown _ ->
     Windtrap.fail "a delegation that never appeared was not Unmet");
  check_bool "the wait used its whole budget" true (runs = 3);
  check_bool
    "every attempt was visible"
    true
    (List.length reports = 3
     && List.for_all
          (fun line -> Sol_cli_string.contains ~needle:"resolver answers" line)
          reports)
;;

let test_an_unqueryable_resolver_fails_closed_without_waiting () =
  let verdict, reports, runs =
    await_delegation ~attempts:5 [ Sol_cli_installation.Unobservable "dig: spawn failed" ]
  in
  (match verdict with
   | Sol_cli_installation.Unknown reason ->
     check_bool
       "the resolver's own reason is what is reported"
       true
       (Sol_cli_string.contains ~needle:"spawn failed" reason)
   | Sol_cli_installation.Established | Sol_cli_installation.Unmet _ ->
     Windtrap.fail
       "an unqueryable resolver was reported as a verdict about the delegation");
  check_bool "an unqueryable resolver is not retried" true (runs = 1);
  check_bool
    "nothing is claimed to be pending when it cannot be observed"
    true
    (reports = [])
;;

let test_the_wait_without_an_expectation_accepts_any_answer () =
  let verdict, _, runs =
    await_delegation ~attempts:2 [ Sol_cli_installation.Observed "ns-1.example" ]
  in
  check_bool
    "without the zone's nameservers, a public answer is the observable"
    true
    (verdict = Sol_cli_installation.Established);
  check_bool "one answer was enough" true (runs = 1);
  let zero_wait, _, _ = await_delegation ~attempts:0 [] in
  match zero_wait with
  | Sol_cli_installation.Unmet reason ->
    check_bool
      "asking for no wait says so instead of claiming a verdict"
      true
      (Sol_cli_string.contains ~needle:"no delegation wait was requested" reason)
  | Sol_cli_installation.Established | Sol_cli_installation.Unknown _ ->
    Windtrap.fail "a zero-attempt wait returned a verdict about the delegation"
;;

let aws_prerequisites =
  Sol_cli_provider_capabilities.installation_prerequisites Sol_cli_provider.Aws
;;

let aws_created =
  Sol_cli_provider_capabilities.installation_created_prerequisites Sol_cli_provider.Aws
;;

let uninstall_plan ?(zone_in_state = false) zone =
  Sol_cli_installation_uninstall.plan
    ~prerequisites:aws_prerequisites
    ~created:aws_created
    ~zone_in_state
    (with_ownership zone)
;;

let test_the_durable_root_does_not_create_the_identities () =
  let plan = uninstall_plan Sol_cli_installation.Sol_created in
  check_bool
    "the operator-created identities are never in the removal list"
    false
    (List.exists
       (fun prerequisite -> List.mem prerequisite plan.removes)
       [ Sol_cli_installation.Provisioning_identity
       ; Sol_cli_installation.Cluster_access_identity
       ; Sol_cli_installation.Deploy_identity
       ; Sol_cli_installation.Operator_identity
       ]);
  check_bool
    "and the result names each as retained, with the reason"
    true
    (List.for_all
       (fun label ->
          List.exists
            (fun (what, why) ->
               what = label
               && Sol_cli_string.contains
                    ~needle:"the durable root does not create it"
                    why)
            plan.retains)
       [ "provisioning identity"
       ; "cluster-access identity"
       ; "deploy identity"
       ; "operator identity"
       ])
;;

let test_the_gcp_installation_creates_only_its_state_and_zone () =
  let created =
    Sol_cli_provider_capabilities.installation_created_prerequisites Sol_cli_provider.Gcp
  in
  check_bool
    "GCP's durable root creates the state bucket and the optional zone, and no identities"
    true
    (List.sort compare created
     = List.sort
         compare
         [ Sol_cli_installation.State_backend; Sol_cli_installation.Delegated_zone ])
;;

let test_removal_is_classified_from_the_observation () =
  let removes = [ Sol_cli_installation.State_backend; Sol_cli_installation.State_lock ] in
  let observed =
    [ Sol_cli_installation.State_backend, Sol_cli_installation.unmet "no bucket"
    ; Sol_cli_installation.State_lock, Sol_cli_installation.establish
    ]
  in
  let verification = Sol_cli_installation_uninstall.classify_removal ~removes observed in
  check_bool
    "an Unmet probe is absence, so the resource is reported removed"
    true
    (verification.removed = [ Sol_cli_installation.State_backend ]);
  check_bool
    "an Established probe is still present"
    true
    (List.map fst verification.present = [ Sol_cli_installation.State_lock ]);
  check_bool
    "absence is not established"
    false
    (Sol_cli_installation_uninstall.removal_established verification);
  let unknown =
    Sol_cli_installation_uninstall.classify_removal
      ~removes
      [ Sol_cli_installation.State_backend, Sol_cli_installation.unmet "no bucket"
      ; Sol_cli_installation.State_lock, Sol_cli_installation.unknown "aws: spawn failed"
      ]
  in
  check_bool
    "an UNKNOWN probe is neither removed nor present"
    true
    (List.map fst unknown.unknown = [ Sol_cli_installation.State_lock ]
     && unknown.present = []);
  check_bool
    "and an unobserved resource is UNKNOWN rather than absent"
    true
    (let missing = Sol_cli_installation_uninstall.classify_removal ~removes [] in
     missing.removed = [] && List.length missing.unknown = 2);
  check_bool
    "absence is established only when every removal was observed absent"
    true
    (Sol_cli_installation_uninstall.removal_established
       (Sol_cli_installation_uninstall.classify_removal
          ~removes
          [ Sol_cli_installation.State_backend, Sol_cli_installation.unmet "gone"
          ; Sol_cli_installation.State_lock, Sol_cli_installation.unmet "gone"
          ]))
;;

type stage_fakes =
  { calls : string list ref
  ; deps : Sol_cli_installation_uninstall_stage.deps
  }

let no_calls name =
  Windtrap.fail (name ^ " reached " ^ "a destructive step without a confirmation")
;;

let stage_fakes
      ?(verdicts = fun () -> [])
      ?(release = Ok ())
      ?(unmanage = Ok ())
      ?(destroy = Ok ())
      ?(retire = Ok ())
      ()
  =
  let calls = ref [] in
  let record name outcome =
    calls := name :: !calls;
    outcome
  in
  { calls
  ; deps =
      { Sol_cli_installation_uninstall_stage.release_state_backend =
          (fun () -> record "release" release)
      ; unmanage_zone = (fun () -> record "unmanage" unmanage)
      ; destroy = (fun () -> record "destroy" destroy)
      ; retire_state_backend = (fun () -> record "retire" retire)
      ; observe = (fun () -> record "observe" (verdicts ()))
      ; warn = (fun _ -> ())
      }
  }
;;

let all_absent plan =
  List.map
    (fun prerequisite ->
       prerequisite, Sol_cli_installation.unmet "the provider does not hold it")
    plan.Sol_cli_installation_uninstall.removes
;;

let successful_execution
      ?verdicts
      ~plan
      ~state_backend_in_state
      ~confirm
      ~dns_confirmation
      ()
  =
  let fakes =
    stage_fakes ~verdicts:(fun () -> Option.value verdicts ~default:(all_absent plan)) ()
  in
  let outcome =
    Sol_cli_installation_uninstall_stage.execute
      ~deps:fakes.deps
      ~plan
      ~state_backend_in_state
      ~confirm
      ~dns_confirmation
  in
  outcome, List.rev !(fakes.calls)
;;

let test_without_confirmation_nothing_is_destroyed () =
  let plan = uninstall_plan Sol_cli_installation.Sol_created in
  let outcome, calls =
    successful_execution
      ~plan
      ~state_backend_in_state:true
      ~confirm:false
      ~dns_confirmation:(Some "api.acme.example")
      ()
  in
  (match outcome with
   | Sol_cli_installation_uninstall_stage.Uninstall_refused reason ->
     check_bool
       "the refusal names --confirm"
       true
       (Sol_cli_string.contains ~needle:"--confirm" reason)
   | _ -> no_calls "an unconfirmed uninstall");
  check_bool "no step ran" true (calls = [])
;;

let test_the_dns_confirmation_must_name_the_exact_zone () =
  let plan = uninstall_plan Sol_cli_installation.Sol_created in
  List.iter
    (fun (name, confirmation) ->
       let outcome, calls =
         successful_execution
           ~plan
           ~state_backend_in_state:true
           ~confirm:true
           ~dns_confirmation:confirmation
           ()
       in
       (match outcome with
        | Sol_cli_installation_uninstall_stage.Uninstall_refused reason ->
          check_bool
            (name ^ ": the refusal names the exact zone and its confirmation flag")
            true
            (Sol_cli_string.contains ~needle:"api.acme.example" reason
             && Sol_cli_string.contains ~needle:"--confirm-dns-zone" reason)
        | _ -> no_calls (name ^ ": an unconfirmed zone removal"));
       check_bool (name ^ ": nothing ran") true (calls = []))
    [ "no confirmation", None; "the wrong zone", Some "other.acme.example" ]
;;

let test_a_user_supplied_zone_is_preserved_without_a_dns_confirmation () =
  let plan = uninstall_plan ~zone_in_state:false Sol_cli_installation.User_supplied in
  let outcome, calls =
    successful_execution
      ~plan
      ~state_backend_in_state:true
      ~confirm:true
      ~dns_confirmation:None
      ()
  in
  (match outcome with
   | Sol_cli_installation_uninstall_stage.Uninstall_succeeded removed ->
     check_bool
       "the zone is not among the removals"
       false
       (List.mem Sol_cli_installation.Delegated_zone removed)
   | _ -> Windtrap.fail "a user-supplied zone blocked an otherwise confirmed uninstall");
  check_bool
    "the zone was never taken out of state, because the state did not own it"
    false
    (List.mem "unmanage" calls)
;;

let test_preservation_happens_before_destruction () =
  let plan = uninstall_plan ~zone_in_state:true Sol_cli_installation.User_supplied in
  check_bool "the plan unmanages the zone" true plan.unmanages_the_zone;
  let outcome, calls =
    successful_execution
      ~plan
      ~state_backend_in_state:true
      ~confirm:true
      ~dns_confirmation:None
      ()
  in
  (match outcome with
   | Sol_cli_installation_uninstall_stage.Uninstall_succeeded _ -> ()
   | _ -> Windtrap.fail "the confirmed uninstall did not reach verified absence");
  let index name =
    let rec find position = function
      | [] -> Windtrap.fail ("expected " ^ name ^ ", saw " ^ String.concat ", " calls)
      | step :: rest -> if step = name then position else find (position + 1) rest
    in
    find 0 calls
  in
  check_bool
    "the zone leaves the root's state before the root is destroyed"
    true
    (index "unmanage" < index "destroy");
  check_bool
    "and the state backend is released before the destroy too"
    true
    (index "release" < index "destroy")
;;

let test_absence_is_observed_after_the_destroy () =
  let plan = uninstall_plan Sol_cli_installation.Sol_created in
  let outcome, calls =
    successful_execution
      ~plan
      ~state_backend_in_state:true
      ~confirm:true
      ~dns_confirmation:(Some "api.acme.example")
      ()
  in
  (match outcome with
   | Sol_cli_installation_uninstall_stage.Uninstall_succeeded removed ->
     check_bool
       "the removed set is the plan's removals, established by observation"
       true
       (removed = plan.removes)
   | _ -> Windtrap.fail "a fully observed uninstall was not reported successful");
  let order name =
    let rec find position = function
      | [] -> Windtrap.fail ("expected " ^ name ^ ", saw " ^ String.concat ", " calls)
      | step :: rest -> if step = name then position else find (position + 1) rest
    in
    find 0 calls
  in
  check_bool
    "the observation runs after the destroy and after the state backend is retired"
    true
    (order "destroy" < order "observe" && order "retire" < order "observe")
;;

let test_an_unobservable_result_fails_closed () =
  let plan = uninstall_plan Sol_cli_installation.Sol_created in
  let verdicts () =
    List.map
      (fun prerequisite ->
         ( prerequisite
         , if prerequisite = Sol_cli_installation.Delegated_zone
           then Sol_cli_installation.unknown "dig: spawn failed"
           else Sol_cli_installation.unmet "the provider does not hold it" ))
      plan.Sol_cli_installation_uninstall.removes
  in
  let fakes = stage_fakes ~verdicts () in
  let outcome =
    Sol_cli_installation_uninstall_stage.execute
      ~deps:fakes.deps
      ~plan
      ~state_backend_in_state:true
      ~confirm:true
      ~dns_confirmation:(Some "api.acme.example")
  in
  match outcome with
  | Sol_cli_installation_uninstall_stage.Uninstall_succeeded _ ->
    Windtrap.fail "an UNKNOWN observation was reported as successful removal"
  | Sol_cli_installation_uninstall_stage.Uninstall_failed
      { failure = Sol_cli_installation_uninstall_stage.Verification_failed _
      ; verification
      } ->
    check_bool
      "the zone is reported UNKNOWN, never removed"
      true
      (List.map fst verification.unknown = [ Sol_cli_installation.Delegated_zone ]
       && not (List.mem Sol_cli_installation.Delegated_zone verification.removed))
  | Sol_cli_installation_uninstall_stage.Uninstall_failed { failure; _ } ->
    Windtrap.fail
      ("expected a verification failure, got "
       ^ Sol_cli_installation_uninstall_stage.failure_message failure)
  | Sol_cli_installation_uninstall_stage.Uninstall_refused reason ->
    Windtrap.fail ("a confirmed uninstall was refused: " ^ reason)
;;

let test_a_failed_state_backend_retirement_still_observes () =
  let plan = uninstall_plan Sol_cli_installation.Sol_created in
  let fakes =
    stage_fakes
      ~retire:(Error "s3: access denied")
      ~verdicts:(fun () ->
        List.map
          (fun prerequisite ->
             ( prerequisite
             , if prerequisite = Sol_cli_installation.State_backend
               then Sol_cli_installation.establish
               else Sol_cli_installation.unmet "gone" ))
          plan.Sol_cli_installation_uninstall.removes)
      ()
  in
  let outcome =
    Sol_cli_installation_uninstall_stage.execute
      ~deps:fakes.deps
      ~plan
      ~state_backend_in_state:true
      ~confirm:true
      ~dns_confirmation:(Some "api.acme.example")
  in
  match outcome with
  | Sol_cli_installation_uninstall_stage.Uninstall_failed
      { failure = Sol_cli_installation_uninstall_stage.Retirement_failed _; verification }
    ->
    check_bool
      "the state backend is reported present, so absence is not claimed"
      true
      (List.map fst verification.present = [ Sol_cli_installation.State_backend ])
  | _ ->
    Windtrap.fail "a state backend that survived its retirement was reported as removed"
;;

let test_a_sol_created_zone_is_removed_with_its_own_confirmation () =
  let plan = uninstall_plan Sol_cli_installation.Sol_created in
  check_bool
    "the zone is part of what uninstall removes"
    true
    (List.mem Sol_cli_installation.Delegated_zone plan.removes);
  check_bool
    "and removing it needs a separate confirmation naming the domain"
    true
    (plan.dns_confirmation = Some "api.acme.example");
  check_bool
    "the confirmation is not satisfied by a different domain"
    false
    (Sol_cli_installation_uninstall.confirmed_dns_zone_matches
       ~confirmation:(Some "other.acme.example")
       ~domain:"api.acme.example");
  check_bool
    "nor by no confirmation at all"
    false
    (Sol_cli_installation_uninstall.confirmed_dns_zone_matches
       ~confirmation:None
       ~domain:"api.acme.example");
  check_bool
    "the exact domain does satisfy it"
    true
    (Sol_cli_installation_uninstall.confirmed_dns_zone_matches
       ~confirmation:(Some " api.acme.example ")
       ~domain:"api.acme.example")
;;

let test_a_user_supplied_zone_is_never_removed () =
  let plan = uninstall_plan Sol_cli_installation.User_supplied in
  check_bool
    "a zone the operator supplied is not in the removal list"
    false
    (List.mem Sol_cli_installation.Delegated_zone plan.removes);
  check_bool
    "the rest of the installation is still removed"
    true
    (List.mem Sol_cli_installation.State_backend plan.removes
     && List.mem Sol_cli_installation.State_lock plan.removes);
  check_bool
    "and it needs no DNS confirmation, because nothing Sol owns is going away"
    true
    (plan.dns_confirmation = None);
  check_bool
    "the result names the zone and says it is retained"
    true
    (List.exists
       (fun (what, why) ->
          what = "api.acme.example"
          && Sol_cli_string.contains ~needle:"supplied by the operator" why)
       plan.retains);
  let lines = Sol_cli_installation_uninstall.lines plan in
  check_bool
    "the report shows both what is removed and what is retained"
    true
    (List.exists
       (fun line ->
          Sol_cli_string.contains ~needle:"remove  terraform state backend" line)
       lines
     && List.exists
          (fun line -> Sol_cli_string.contains ~needle:"retain  api.acme.example" line)
          lines)
;;

let test_a_zone_the_declaration_disowns_is_taken_out_of_state_first () =
  let declared_yours =
    uninstall_plan ~zone_in_state:true Sol_cli_installation.User_supplied
  in
  check_bool
    "a zone the target says the operator supplied, which the root's state owns, is \
     unmanaged first"
    true
    declared_yours.unmanages_the_zone;
  check_bool
    "so the zone survives the destroy"
    false
    (List.mem Sol_cli_installation.Delegated_zone declared_yours.removes);
  check_bool
    "a zone that is not in the state needs no unmanaging"
    false
    (uninstall_plan ~zone_in_state:false Sol_cli_installation.User_supplied)
      .unmanages_the_zone;
  check_bool
    "and neither does a Sol-created zone, which is simply removed"
    false
    (uninstall_plan ~zone_in_state:true Sol_cli_installation.Sol_created)
      .unmanages_the_zone;
  check_bool
    "the report says the zone was taken out of state"
    true
    (List.exists
       (fun line -> Sol_cli_string.contains ~needle:"taken out of state first" line)
       (Sol_cli_installation_uninstall.lines declared_yours))
;;

let test_an_unobservable_answer_is_not_absence () =
  check_bool
    "the refusal says the observation failed rather than that the installation is gone"
    true
    (Sol_cli_string.contains
       ~needle:"does not claim the installation is gone"
       (Sol_cli_installation_uninstall.refusal_of_unobservable "aws: spawn failed"))
;;

let report_of verdicts target configuration =
  String.concat
    "\n"
    (Sol_cli_installation_onboarding.report_lines ~target ~configuration verdicts)
;;

let test_the_first_run_state_comes_from_the_verdicts () =
  let open Sol_cli_installation in
  let state = Sol_cli_installation_onboarding.state_of_verdicts in
  check_string
    "every prerequisite established is present"
    "present"
    (match
       state
         [ State_backend, Established
         ; Provisioning_identity, Established
         ; Delegated_zone, Established
         ]
     with
     | Sol_cli_installation_onboarding.Present -> "present"
     | Absent -> "absent"
     | Partial -> "partial"
     | Indeterminate -> "indeterminate");
  check_string
    "every prerequisite refused is absent"
    "absent"
    (match
       state
         [ State_backend, Unmet "no bucket"
         ; Provisioning_identity, Unmet "no role"
         ; Delegated_zone, Unmet "no zone"
         ]
     with
     | Sol_cli_installation_onboarding.Present -> "present"
     | Absent -> "absent"
     | Partial -> "partial"
     | Indeterminate -> "indeterminate");
  check_string
    "an established prerequisite beside a refused one is partial"
    "partial"
    (match
       state [ State_backend, Established; Provisioning_identity, Unmet "no role" ]
     with
     | Sol_cli_installation_onboarding.Present -> "present"
     | Absent -> "absent"
     | Partial -> "partial"
     | Indeterminate -> "indeterminate");
  check_string
    "an installation Sol could not look at is indeterminate"
    "indeterminate"
    (match
       state
         [ State_backend, Unknown "AccessDenied"
         ; Provisioning_identity, Unknown "spawn failed"
         ]
     with
     | Sol_cli_installation_onboarding.Present -> "present"
     | Absent -> "absent"
     | Partial -> "partial"
     | Indeterminate -> "indeterminate");
  check_string
    "a refused prerequisite stays decisive beside an unobservable one"
    "absent"
    (match
       state
         [ State_backend, Unmet "no bucket"
         ; Provisioning_identity, Unknown "AccessDenied"
         ; Delegated_zone, Unknown "spawn failed"
         ]
     with
     | Sol_cli_installation_onboarding.Present -> "present"
     | Absent -> "absent"
     | Partial -> "partial"
     | Indeterminate -> "indeterminate")
;;

let test_the_decision_follows_interactivity () =
  let open Sol_cli_installation_onboarding in
  let decision = decision in
  check_string
    "an established installation is never offered a setup"
    "proceed"
    (match decision ~interactive:true Present with
     | Proceed -> "proceed"
     | Offer -> "offer"
     | Refuse -> "refuse"
     | Report -> "report");
  check_string
    "an interactive run is offered the setup"
    "offer"
    (match decision ~interactive:true Absent with
     | Proceed -> "proceed"
     | Offer -> "offer"
     | Refuse -> "refuse"
     | Report -> "report");
  check_string
    "a non-interactive run is refused rather than prompted"
    "refuse"
    (match decision ~interactive:false Absent with
     | Proceed -> "proceed"
     | Offer -> "offer"
     | Refuse -> "refuse"
     | Report -> "report");
  check_string
    "a partly present installation is offered too"
    "offer"
    (match decision ~interactive:true Partial with
     | Proceed -> "proceed"
     | Offer -> "offer"
     | Refuse -> "refuse"
     | Report -> "report");
  check_string
    "an unobservable installation is reported, not offered and not refused"
    "report"
    (match decision ~interactive:true Indeterminate with
     | Proceed -> "proceed"
     | Offer -> "offer"
     | Refuse -> "refuse"
     | Report -> "report")
;;

let test_the_report_separates_work_from_the_external_action () =
  let verdicts =
    [ Sol_cli_installation.State_backend, Sol_cli_installation.Unmet "no bucket"
    ; ( Sol_cli_installation.Provisioning_identity
      , Sol_cli_installation.Unknown "AccessDenied" )
    ]
  in
  let report = report_of verdicts "prod/aws/us-east-1" aws_config in
  check_bool
    "the report names the target"
    true
    (Sol_cli_string.contains ~needle:"prod/aws/us-east-1" report);
  check_bool
    "the report lists the missing prerequisites"
    true
    (Sol_cli_string.contains ~needle:"terraform state backend" report);
  check_bool
    "the report shows the declared installation"
    true
    (Sol_cli_string.contains ~needle:"sol-state-test" report);
  check_bool
    "the automated work is named"
    true
    (Sol_cli_string.contains ~needle:"Sol does this for you:" report);
  check_bool
    "the external action is separated"
    true
    (Sol_cli_string.contains ~needle:"One action may be required from you:" report);
  check_bool
    "the DNS hand-off names the zone"
    true
    (Sol_cli_string.contains ~needle:"qual-aws.example.test" report);
  check_bool
    "an unobservable prerequisite is labelled UNKNOWN rather than missing"
    true
    (Sol_cli_string.contains ~needle:"UNKNOWN" report)
;;

let test_the_refusal_names_how_to_establish_it () =
  let verdicts =
    [ Sol_cli_installation.State_backend, Sol_cli_installation.Unmet "no bucket" ]
  in
  let refusal =
    String.concat
      "\n"
      (Sol_cli_installation_onboarding.refusal_lines
         ~target:"prod/aws/us-east-1"
         ~because:"this run is not interactive"
         verdicts)
  in
  check_bool
    "the refusal names the command that establishes the installation"
    true
    (Sol_cli_string.contains ~needle:"sol deploy prod/aws/us-east-1" refusal);
  check_bool
    "the refusal says why it will not set it up"
    true
    (Sol_cli_string.contains ~needle:"this run is not interactive" refusal)
;;

let test_an_unobservable_installation_is_never_absent () =
  let verdicts =
    [ Sol_cli_installation.State_backend, Sol_cli_installation.Unknown "AccessDenied" ]
  in
  let report =
    String.concat
      "\n"
      (Sol_cli_installation_onboarding.indeterminate_lines
         ~target:"prod/aws/us-east-1"
         verdicts)
  in
  check_bool
    "an unobservable installation is neither established nor absent"
    true
    (Sol_cli_string.contains ~needle:"neither established nor absent" report);
  check_bool
    "the report says how to observe it"
    true
    (Sol_cli_string.contains ~needle:"sol plan prod/aws/us-east-1" report);
  check_bool
    "an unobservable installation is never called absent"
    false
    (Sol_cli_string.contains ~needle:"is not installed" report)
;;

let test_the_next_stage_is_named () =
  let present =
    String.concat
      "\n"
      (Sol_cli_installation_onboarding.present_lines ~target:"prod/aws/us-east-1")
  in
  let undeclared =
    String.concat
      "\n"
      (Sol_cli_installation_onboarding.undeclared_lines
         ~target:"prod/aws/us-east-1"
         ~reason:"the installation requires the target's state_bucket")
  in
  check_bool
    "an established installation names the environment stage"
    true
    (Sol_cli_string.contains ~needle:"sol deploy prod/aws/us-east-1" present);
  check_bool
    "an undeclared installation is named with its reason"
    true
    (Sol_cli_string.contains ~needle:"state_bucket" undeclared)
;;

let test_a_refused_provider_answer_is_not_absence () =
  let absent provider message =
    (Sol_cli_provider_capabilities.capabilities_of provider)
      .installation_failure_means_absent
      message
  in
  check_bool
    "AWS's HeadBucket 404 is absence"
    true
    (absent
       Sol_cli_provider.Aws
       "An error occurred (404) when calling the HeadBucket operation: Not Found");
  check_bool
    "an IAM NoSuchEntity is absence"
    true
    (absent
       Sol_cli_provider.Aws
       "An error occurred (NoSuchEntity) when calling the GetRole operation: cannot be \
        found");
  check_bool
    "an AWS AccessDenied is not absence"
    false
    (absent
       Sol_cli_provider.Aws
       "An error occurred (AccessDenied) when calling the GetRole operation: not \
        authorized");
  check_bool
    "an AWS 403 is not absence"
    false
    (absent
       Sol_cli_provider.Aws
       "An error occurred (403) when calling the HeadBucket operation: Forbidden");
  check_bool
    "credentials Sol does not have are not absence"
    false
    (absent Sol_cli_provider.Aws "Unable to locate credentials");
  check_bool
    "a missing GCS bucket is absence"
    true
    (absent Sol_cli_provider.Gcp "HTTPError 404: The specified bucket does not exist.");
  check_bool
    "a GCP permission denial is not absence"
    false
    (absent
       Sol_cli_provider.Gcp
       "HTTPError 403: does not have storage.buckets.get access to the Google Cloud \
        Storage bucket.")
;;

let test_identity_contracts_are_declared_per_provider () =
  let contracts provider =
    Sol_cli_provider_capabilities.installation_identity_contracts provider
  in
  let aws = contracts Sol_cli_provider.Aws in
  let gcp = contracts Sol_cli_provider.Gcp in
  Windtrap.equal
    Windtrap.int
    ~msg:"AWS declares the four identities Sol resolves"
    4
    (List.length aws);
  Windtrap.equal
    Windtrap.int
    ~msg:"GCP's durable root declares no identities"
    0
    (List.length gcp);
  let declared provider prerequisite =
    contracts provider
    |> List.find_opt (fun (contract : Sol_cli_provider_capabilities.identity_contract) ->
      contract.identity = prerequisite)
    |> Option.map (fun (contract : Sol_cli_provider_capabilities.identity_contract) ->
      contract.declared_as)
  in
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the provisioning identity is declared as the provisioner role"
    (Some "aws.provisioner_role_arn")
    (declared Sol_cli_provider.Aws Sol_cli_installation.Provisioning_identity);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the deploy identity is declared as the deploy role"
    (Some "aws.deploy_role_arn")
    (declared Sol_cli_provider.Aws Sol_cli_installation.Deploy_identity);
  Windtrap.equal
    (Windtrap.option Windtrap.string)
    ~msg:"the operator identity is declared as the operator role"
    (Some "aws.operator_role_arn")
    (declared Sol_cli_provider.Aws Sol_cli_installation.Operator_identity);
  List.iter
    (fun (contract : Sol_cli_provider_capabilities.identity_contract) ->
       Windtrap.equal
         Windtrap.bool
         ~msg:
           (Printf.sprintf
              "the contract for %s names a durable-root output"
              (Sol_cli_installation.prerequisite_label contract.identity))
         true
         (String.length contract.policy_output > 0))
    aws
;;

let%test "first-run onboarding: the state comes from the observed verdicts" =
  test_the_first_run_state_comes_from_the_verdicts ()
;;

let%test "first-run onboarding: the decision follows interactivity" =
  test_the_decision_follows_interactivity ()
;;

let%test "first-run onboarding: the report separates Sol's work from the external action" =
  test_the_report_separates_work_from_the_external_action ()
;;

let%test "first-run onboarding: the refusal names how to establish the installation" =
  test_the_refusal_names_how_to_establish_it ()
;;

let%test "first-run onboarding: an unobservable installation is never called absent" =
  test_an_unobservable_installation_is_never_absent ()
;;

let%test "first-run onboarding: the next stage is named" = test_the_next_stage_is_named ()

let%test "first-run onboarding: a refused provider answer is not absence" =
  test_a_refused_provider_answer_is_not_absence ()
;;

let%test
    "identity contracts: each provider declares the contracts its durable root carries"
  =
  test_identity_contracts_are_declared_per_provider ()
;;

let%test "uninstall plan: a Sol-created zone is removed, with its own confirmation" =
  test_a_sol_created_zone_is_removed_with_its_own_confirmation ()
;;

let%test "uninstall plan: a user-supplied zone is never removed" =
  test_a_user_supplied_zone_is_never_removed ()
;;

let%test "uninstall plan: a zone the declaration disowns is taken out of state first" =
  test_a_zone_the_declaration_disowns_is_taken_out_of_state_first ()
;;

let%test
    "uninstall plan: the durable root does not create the identities, so it retains them"
  =
  test_the_durable_root_does_not_create_the_identities ()
;;

let%test "uninstall plan: GCP's durable root creates only the state bucket and the zone" =
  test_the_gcp_installation_creates_only_its_state_and_zone ()
;;

let%test "uninstall plan: an unobservable answer is not absence" =
  test_an_unobservable_answer_is_not_absence ()
;;

let%test "install removal: removal is classified from the observation" =
  test_removal_is_classified_from_the_observation ()
;;

let%test "install removal: without --confirm nothing is destroyed" =
  test_without_confirmation_nothing_is_destroyed ()
;;

let%test "install removal: the DNS confirmation must name the exact zone" =
  test_the_dns_confirmation_must_name_the_exact_zone ()
;;

let%test "install removal: a user-supplied zone is preserved without a DNS confirmation" =
  test_a_user_supplied_zone_is_preserved_without_a_dns_confirmation ()
;;

let%test "install removal: preservation happens before destruction" =
  test_preservation_happens_before_destruction ()
;;

let%test "install removal: absence is observed after the destroy" =
  test_absence_is_observed_after_the_destroy ()
;;

let%test "install removal: an unobservable result fails closed" =
  test_an_unobservable_result_fails_closed ()
;;

let%test "install removal: a failed state-backend retirement is still observed" =
  test_a_failed_state_backend_retirement_still_observes ()
;;

let%test "delegation wait: Established when the resolver names the zone's nameservers" =
  test_the_wait_succeeds_when_the_delegation_appears ()
;;

let%test "delegation wait: Unmet after the budget, saying what was seen" =
  test_the_wait_gives_up_and_says_what_it_saw ()
;;

let%test "delegation wait: an unqueryable resolver is UNKNOWN, without waiting" =
  test_an_unqueryable_resolver_fails_closed_without_waiting ()
;;

let%test "delegation wait: without an expectation, a public answer suffices" =
  test_the_wait_without_an_expectation_accepts_any_answer ()
;;

let%test "zone ownership: the three cases are distinguishable declarations" =
  test_zone_ownership_is_three_distinguishable_cases ()
;;

let%test "zone ownership: ownership reaches the resolved configuration" =
  test_ownership_reaches_the_resolved_configuration ()
;;

let%test "zone ownership: only a Sol-created zone is the installation's to reconcile" =
  test_owns_the_zone_follows_the_declaration ()
;;

let%test "zone ownership: an external delegation is UNKNOWN, never Unmet or Established" =
  test_external_delegation_is_unverifiable_not_unmet ()
;;

let%test "zone ownership: a domain-less target has no zone prerequisite" =
  test_a_target_that_serves_no_domain_has_no_zone_prerequisite ()
;;

let%test "zone ownership: a declared domain requires an ownership declaration" =
  test_the_declaration_is_required_when_a_domain_is_declared ()
;;

let%test "prerequisites: every prerequisite has exactly one probe" =
  test_probe_coverage ()
;;

let%test "prerequisites: the provider sets are not the same shape" =
  test_provider_sets_are_not_the_same_shape ()
;;

let%test "verdicts: an unobservable probe is never Established" =
  test_unobservable_is_never_established ()
;;

let%test "verdicts: an observation drives the verdict" =
  test_observation_drives_the_verdict ()
;;

let%test "verdicts: a probe that ran and refused is Unmet" =
  test_a_refused_probe_is_unmet ()
;;

let%test "verdicts: absent configuration is Unmet, not UNKNOWN" =
  test_missing_configuration_is_unmet ()
;;

let%test "verdicts: all_established fails closed" = test_all_established_fails_closed ()

let%test "verdicts: the health summary never promotes an UNKNOWN" =
  test_the_health_summary_never_promotes_an_unknown ()
;;

let%test "resolved configuration: carries plumbing and no authority" =
  test_resolved_configuration_has_no_authority ()
;;

let%test "resolved configuration: resolves the declared installation" =
  test_resolves_the_declared_installation ()
;;

let%test "resolved configuration: requires a state backend" =
  test_the_state_backend_is_required ()
;;

let%test "resolved configuration: the role probe names the role, not the ARN" =
  test_the_role_probe_names_the_role_not_the_arn ()
;;

let%test "resolved configuration: the GCP zone probe uses the zone name Terraform creates"
  =
  test_the_gcp_zone_probe_uses_the_zone_name_terraform_creates ()
;;

let%test "resolved configuration: the durable root is configured from the declaration" =
  test_the_durable_root_is_configured_from_the_declaration ()
;;

let%test "resolved configuration: an incomplete declaration is refused" =
  test_the_durable_root_refuses_an_incomplete_declaration ()
;;

let%test
    "resolved configuration: the durable root's policy refuses recreation and destruction"
  =
  test_the_durable_root_policy_refuses_recreation ()
;;

let test_await_public_delegation_short_circuits_without_a_wait () =
  let calls = ref 0 in
  let established = ref 0 in
  let result =
    Sol_cli_installation_stage.await_public_delegation
      ~configuration:aws_config
      ~run:(fun _ ->
        incr calls;
        Sol_cli_installation.Observed "ns-1.example")
      ~seconds:0
      ~report:(fun _ -> ())
      ~on_established:(fun () ->
        incr established;
        Ok ())
  in
  check_bool "a zero-second wait is Ok" true (result = Ok ());
  check_bool "the resolver was not queried" true (!calls = 0);
  check_bool "nothing was established" true (!established = 0)
;;

let test_await_public_delegation_establishes_and_reports () =
  let reports = ref [] in
  let established = ref 0 in
  let result =
    Sol_cli_installation_stage.await_public_delegation
      ~configuration:aws_config
      ~run:(fun _ -> Sol_cli_installation.Observed "ns-1.example")
      ~seconds:5
      ~report:(fun line -> reports := line :: !reports)
      ~on_established:(fun () ->
        incr established;
        Ok ())
  in
  check_bool "an answering resolver is Ok" true (result = Ok ());
  check_bool "the establishment hook ran once" true (!established = 1);
  check_bool
    "the banner is reported before the wait"
    true
    (List.exists
       (fun line -> Sol_cli_string.contains ~needle:"Waiting up to 5 seconds" line)
       !reports)
;;

let test_await_public_delegation_fails_closed () =
  let established = ref 0 in
  let result =
    Sol_cli_installation_stage.await_public_delegation
      ~configuration:aws_config
      ~run:(fun _ -> Sol_cli_installation.Unobservable "dig: spawn failed")
      ~seconds:5
      ~report:(fun _ -> ())
      ~on_established:(fun () ->
        incr established;
        Ok ())
  in
  (match result with
   | Error reason ->
     check_bool
       "the resolver's own reason travels"
       true
       (Sol_cli_string.contains ~needle:"spawn failed" reason)
   | Ok () -> Windtrap.fail "an unqueryable resolver must not be Ok");
  check_bool "no establishment on an unknown resolver" true (!established = 0)
;;

let%test "public delegation: a zero-second wait is a no-op" =
  test_await_public_delegation_short_circuits_without_a_wait ()
;;

let%test "public delegation: an answering resolver establishes and reports" =
  test_await_public_delegation_establishes_and_reports ()
;;

let%test "public delegation: an unqueryable resolver fails closed" =
  test_await_public_delegation_fails_closed ()
;;

let test_address_in_zone () =
  let zone = "api.example.com" in
  check_bool "the zone itself" true (Sol_cli_installation.address_in_zone ~zone zone);
  check_bool
    "a record under the zone"
    true
    (Sol_cli_installation.address_in_zone ~zone (zone ^ "[0]"));
  check_bool
    "a different zone"
    false
    (Sol_cli_installation.address_in_zone ~zone "other.example.com");
  check_bool
    "a name that merely starts with the zone text is not in it"
    false
    (Sol_cli_installation.address_in_zone ~zone:"a.example.com" "ab.example.com")
;;

let%test "address_in_zone: the zone or a record under it" = test_address_in_zone ()

(* BUG-211: Route53's ListHostedZonesByName is a prefix listing that returns the
   next zone in name order when the requested name has no exact match. A lookup
   must therefore select by name, never by position. *)

let test_zone_lookup_selects_by_exact_name () =
  let candidates =
    [ "/hostedzone/ZINSTALL", "qual-aws.sol-fab.dev."
    ; "/hostedzone/ZPARENT", "sol-fab.dev."
    ]
  in
  let select domain = Sol_cli_installation.select_zone_identity ~domain candidates in
  (match select "sol-fab.dev" with
   | Ok (Some identity) ->
     check_string
       "the exact zone is selected wherever it sits"
       "/hostedzone/ZPARENT"
       identity
   | _ -> Windtrap.fail "the zone named exactly for the request was not selected");
  (match select "qual-aws.sol-fab.dev" with
   | Ok (Some identity) ->
     check_string
       "the installation's own zone is selected for its own name"
       "/hostedzone/ZINSTALL"
       identity
   | _ -> Windtrap.fail "the exact installation zone was not selected");
  (match select "zzz.sol-fab.dev" with
   | Ok None -> ()
   | Ok (Some identity) ->
     Windtrap.fail
       (Printf.sprintf "BUG-211: %s was selected for a request it does not name" identity)
   | Error reason -> Windtrap.fail ("unexpected ambiguity: " ^ reason));
  (match select "SOL-FAB.DEV" with
   | Ok (Some identity) ->
     check_string "names compare case-insensitively" "/hostedzone/ZPARENT" identity
   | _ -> Windtrap.fail "a case-different exact name was not matched");
  match
    Sol_cli_installation.select_zone_identity
      ~domain:"sol-fab.dev"
      [ "/hostedzone/A", "sol-fab.dev."; "/hostedzone/B", "sol-fab.dev" ]
  with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "two exact matches must fail closed rather than guess"
;;

let%test "zone lookup: a zone is selected by its exact name, never its position" =
  test_zone_lookup_selects_by_exact_name ()
;;

let test_aws_zone_candidates_ignore_the_next_zone () =
  (* The live BUG-211 answer: the parent is not in the account, so
     ListHostedZonesByName --dns-name sol-fab.dev returned the installation's own
     zone, which sorts immediately after it. *)
  let output =
    {|{"HostedZones":[{"Id":"/hostedzone/Z0555133LN4ZIDB3U52A","Name":"qual-aws.sol-fab.dev.","Config":{"PrivateZone":false}}]}|}
  in
  match Sol_cli_provider_capabilities.aws.installation_zone_candidates output with
  | Error reason -> Windtrap.fail ("the observed Route53 answer should parse: " ^ reason)
  | Ok candidates ->
    (match Sol_cli_installation.select_zone_identity ~domain:"sol-fab.dev" candidates with
     | Ok None -> ()
     | Ok (Some identity) ->
       Windtrap.fail
         (Printf.sprintf
            "BUG-211: the installation's own zone %s was read as the parent"
            identity)
     | Error reason -> Windtrap.fail ("unexpected ambiguity: " ^ reason))
;;

let%test "AWS zone lookup: the next zone is not the parent" =
  test_aws_zone_candidates_ignore_the_next_zone ()
;;

let test_aws_zone_candidates_drop_private_zones () =
  let output =
    {|{"HostedZones":[{"Id":"/hostedzone/ZPRIVATE","Name":"sol-fab.dev.","Config":{"PrivateZone":true}}]}|}
  in
  match Sol_cli_provider_capabilities.aws.installation_zone_candidates output with
  | Ok [] -> ()
  | Ok _ -> Windtrap.fail "a private hosted zone is not the installation's public zone"
  | Error reason -> Windtrap.fail ("the answer should parse: " ^ reason)
;;

let%test "AWS zone lookup: a private zone is not the installation zone" =
  test_aws_zone_candidates_drop_private_zones ()
;;

let test_gcp_zone_candidates_select_by_dns_name () =
  (* gcloud's `=` filter is documented as not reliably exact across APIs, so a
     response can hold a zone whose dnsName merely contains the requested
     domain; only the exact dnsName may be selected. *)
  let output =
    {|[{"name":"qual-gcp-sol-fab-dev","dnsName":"qual-gcp.sol-fab.dev.","visibility":"public"}]|}
  in
  match Sol_cli_provider_capabilities.gcp.installation_zone_candidates output with
  | Error reason -> Windtrap.fail ("the Cloud DNS answer should parse: " ^ reason)
  | Ok candidates ->
    (match Sol_cli_installation.select_zone_identity ~domain:"sol-fab.dev" candidates with
     | Ok None -> ()
     | Ok (Some identity) ->
       Windtrap.fail
         (Printf.sprintf "gcloud: %s was read as a domain it does not name" identity)
     | Error reason -> Windtrap.fail ("unexpected ambiguity: " ^ reason))
;;

let%test "GCP zone lookup: only the exact dnsName may be selected" =
  test_gcp_zone_candidates_select_by_dns_name ()
;;

let test_zone_candidates_refuse_a_missing_identity () =
  let output =
    {|{"HostedZones":[{"Name":"sol-fab.dev.","Config":{"PrivateZone":false}}]}|}
  in
  match Sol_cli_provider_capabilities.aws.installation_zone_candidates output with
  | Error _ -> ()
  | Ok _ -> Windtrap.fail "a zone with no identity cannot be adopted"
;;

let%test "zone lookup: a candidate with no identity is refused" =
  test_zone_candidates_refuse_a_missing_identity ()
;;
