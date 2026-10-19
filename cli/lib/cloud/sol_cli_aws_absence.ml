open Sol_cli_absence

type check =
  { resource_class : string
  ; identity : string
  ; attribution : attribution
  ; argv : string list
  ; attributable : string -> bool
  ; tagged_with : (string -> string list) option
  ; checked_as : string
  }

let check
      ?(attributable = fun _ -> true)
      ?tagged_with
      ?checked_as
      ~resource_class
      ~identity
      ~attribution
      argv
  =
  { resource_class
  ; identity
  ; attribution
  ; argv
  ; attributable
  ; tagged_with
  ; checked_as = Option.value checked_as ~default:("aws " ^ String.concat " " argv)
  }
;;

let not_found =
  Sol_cli_absence.not_found
    ~needles:[ "notfound"; "not found"; "does not exist"; "no such" ]
;;

let run_argv argv =
  match Sol_cli_process.run (Sol_cli_process.cmd ("aws" :: argv)) with
  | Ok { Sol_cli_process.stdout; _ } -> Ok (lines stdout)
  | Error (Sol_cli_process.Non_zero r) when not_found r.stderr ->
    Error (`NotFound r.stderr)
  | Error (Sol_cli_process.Non_zero r) -> Error (`Failed r.stderr)
  | Error _ -> Error (`Failed "the aws CLI is unavailable")
;;

let account_of_role_arn arn =
  match String.split_on_char ':' arn with
  | "arn" :: "aws" :: "iam" :: "" :: account :: _ when account <> "" -> Some account
  | _ -> None
;;

let declared_account target =
  let keys =
    [ "provisioner_role_arn"
    ; "deploy_role_arn"
    ; "cluster_access_role_arn"
    ; "operator_role_arn"
    ]
  in
  let accounts =
    keys
    |> List.filter_map (fun key ->
      Option.bind (Sol_cli_config.provider_field target key) account_of_role_arn)
    |> List.sort_uniq String.compare
  in
  match accounts with
  | [ account ] -> Ok account
  | [] ->
    Error
      "the target declares no AWS role ARN (provisioner_role_arn, deploy_role_arn, \
       cluster_access_role_arn or operator_role_arn), so the inventory cannot establish \
       which AWS account it would list. An unbounded account is not evidence of absence"
  | accounts ->
    Error
      (Printf.sprintf
         "the target's AWS role ARNs name different accounts (%s), so the inventory \
          cannot establish which account it would list"
         (String.concat ", " accounts))
;;

(* The account is not ambient. Every destructive absence claim must be tied to the account
   the target declares, and the active caller must be in that account. A mismatch or an
   unreadable caller identity is unknown, never absence. *)
let scope_binding target =
  let open Result.Syntax in
  let* expected = declared_account target in
  match
    run_argv [ "sts"; "get-caller-identity"; "--query"; "Account"; "--output"; "text" ]
  with
  | Ok [ actual ] ->
    let actual = String.trim actual in
    if String.equal actual expected
    then Ok ()
    else
      Error
        (Printf.sprintf
           "the active AWS caller is account %s, but the target's role ARNs name %s; the \
            inventory would not be listing the target's account"
           actual
           expected)
  | Ok _ -> Error "aws sts get-caller-identity returned no account"
  | Error (`NotFound reason) | Error (`Failed reason) ->
    Error ("could not establish the active AWS account: " ^ String.trim reason)
;;

let prior_for class_name prior =
  List.assoc_opt class_name prior |> Option.value ~default:[]
;;

let run ?(previously_attributed = []) ~check () =
  let unobservable reason =
    Unobservable
      { resource_class = check.resource_class
      ; reason = String.trim reason
      ; checked_with = check.checked_as
      }
  in
  let observed found =
    match found with
    | [] ->
      Absent
        { resource_class = check.resource_class
        ; identity = check.identity
        ; attribution = check.attribution
        ; checked_with = check.checked_as
        }
    | found ->
      Present
        { resource_class = check.resource_class
        ; identity = check.identity
        ; found
        ; attribution = check.attribution
        ; checked_with = check.checked_as
        }
  in
  (* The top-level probes are enumerations. A failed enumeration is unknown, even when
     the provider's message contains "not found": the subject may be the account, region,
     caller or filter, not the resource. Only a successful empty listing establishes
     absence. *)
  match run_argv check.argv with
  | Error (`NotFound reason) | Error (`Failed reason) -> unobservable reason
  | Ok candidates ->
    let prior = prior_for check.resource_class previously_attributed in
    let attributed = List.filter check.attributable candidates in
    let prior_matches = List.filter (fun line -> List.mem line prior) candidates in
    let candidates =
      List.sort_uniq String.compare (List.rev_append attributed prior_matches)
    in
    (match check.tagged_with with
     | None -> observed candidates
     | Some tag_argv ->
       let rec resolve acc = function
         | [] -> Ok (List.rev acc)
         | line :: rest when List.mem line prior -> resolve (line :: acc) rest
         | line :: rest ->
           (match run_argv (tag_argv line) with
            | Ok [] -> resolve acc rest
            | Ok (_ :: _) -> resolve (line :: acc) rest
            | Error (`NotFound reason) -> Error (`Failed reason)
            | Error (`Failed reason) -> Error (`Failed reason))
       in
       (match resolve [] candidates with
        | Ok found -> observed found
        | Error (`Failed reason) -> unobservable reason
        | Error (`NotFound reason) -> unobservable reason))
;;

let named_for_cluster cluster_name =
  Printf.sprintf
    "the target's own cluster name: the target's roots name the resources they create \
     after %s"
    cluster_name
;;

(* The cluster root names ECR repositories `<workspace>/<service>` from the
   `workspace_name` variable. The current working directory is not the identity
   that provisioned them: teardown may run from another directory, and the
   workspace may have been renamed. The pre-destroy Terraform state is the
   authoritative record of the repositories this target created. The target's
   declared registry is an explicit fallback; the current workspace name is not. *)
let ecr_repositories_of_state state =
  Sol_cli_cloud_destroy.resources state
  |> List.filter_map (fun (resource : Sol_cli_cloud_destroy.resource) ->
    if String.equal resource.kind "aws_ecr_repository" then resource.name else None)
  |> List.sort_uniq String.compare
;;

let registry_prefix (target : Sol_cli_config.target) =
  match target.registry with
  | None -> None
  | Some registry ->
    (match String.index_opt registry '/' with
     | None -> None
     | Some index ->
       let prefix =
         String.sub registry (index + 1) (String.length registry - index - 1)
       in
       if prefix = "" then None else Some prefix)
;;

let cluster_tagged ?tagged_with ?checked_as ~cluster_name class_name argv =
  check
    ?tagged_with
    ?checked_as
    ~resource_class:class_name
    ~identity:(Printf.sprintf "tagged kubernetes.io/cluster/%s" cluster_name)
    ~attribution:
      (Within_target
         (Printf.sprintf
            "the target's own cluster tag: %s marks what this cluster's controllers \
             created, and Sol writes it itself"
            cluster_name))
    ~attributable:(fun line -> line <> "")
    argv
;;

let cluster_owned_tag ~region ~cluster_name resource_id =
  [ "ec2"
  ; "describe-tags"
  ; "--region"
  ; region
  ; "--filters"
  ; "Name=resource-id,Values=" ^ resource_id
  ; "--query"
  ; Printf.sprintf
      "Tags[?(Key=='kubernetes.io/cluster/%s' && (Value=='' || Value=='owned' || \
       Value=='shared')) || (Key=='Name' && (Value=='%s' || starts_with(Value, '%s-')))]"
      cluster_name
      cluster_name
      cluster_name
  ; "--output"
  ; "text"
  ]
;;

let cluster_owned ?checked_as ~region ~cluster_name ~resource_class ~identity argv =
  check
    ?checked_as
    ~tagged_with:(fun resource_id -> cluster_owned_tag ~region ~cluster_name resource_id)
    ~resource_class
    ~identity
    ~attribution:
      (Within_target
         (Printf.sprintf
            "the target's own cluster tag or a provisioned Name naming %s: %s marks what \
             this cluster's controllers created, and Sol writes it itself"
            cluster_name
            cluster_name))
    ~attributable:(fun line -> line <> "")
    argv
;;

let cluster_check ~region ~cluster_name =
  check
    ~resource_class:"EKS cluster"
    ~identity:cluster_name
    ~attribution:(Named_for_target (named_for_cluster cluster_name))
    ~attributable:(fun line -> Sol_cli_string.contains ~needle:cluster_name line)
    [ "eks"
    ; "list-clusters"
    ; "--region"
    ; region
    ; "--query"
    ; "clusters[]"
    ; "--output"
    ; "text"
    ]
;;

let checks ~region ~cluster_name =
  let prefixed_class ~resource_class ~prefix argv =
    check
      ~resource_class
      ~identity:(prefix ^ "*")
      ~attribution:(Named_for_target (named_for_cluster cluster_name))
      ~attributable:(fun line -> Sol_cli_string.contains ~needle:prefix line)
      argv
  in
  [ cluster_check ~region ~cluster_name
  ; check
      ~resource_class:"EKS node group"
      ~identity:cluster_name
      ~attribution:(Within_target "an EKS node group of the target's own cluster")
      ~attributable:(fun line -> line <> "")
      [ "eks"
      ; "list-nodegroups"
      ; "--cluster-name"
      ; cluster_name
      ; "--region"
      ; region
      ; "--query"
      ; "nodegroups[]"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"RDS instance"
      ~prefix:(cluster_name ^ "-postgres")
      [ "rds"
      ; "describe-db-instances"
      ; "--region"
      ; region
      ; "--query"
      ; "DBInstances[].DBInstanceIdentifier"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"RDS subnet group"
      ~prefix:(cluster_name ^ "-postgres")
      [ "rds"
      ; "describe-db-subnet-groups"
      ; "--region"
      ; region
      ; "--query"
      ; "DBSubnetGroups[].DBSubnetGroupName"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"security group"
      ~prefix:(cluster_name ^ "-rds")
      [ "ec2"
      ; "describe-security-groups"
      ; "--region"
      ; region
      ; "--query"
      ; "SecurityGroups[].GroupName"
      ; "--output"
      ; "text"
      ]
  ; (* The EKS module creates its cluster, node, and remote-access security
       groups independently of the managed node group. If the cluster's state
       is lost they can remain as orphaned EC2 resources; the RDS security
       group check above does not see them. *)
    check
      ~resource_class:"EKS security group"
      ~identity:
        (Printf.sprintf
           "%s-cluster-*, %s-node-*, %s-remote-access-*"
           cluster_name
           cluster_name
           cluster_name)
      ~attribution:(Named_for_target (named_for_cluster cluster_name))
      ~attributable:(fun line ->
        List.exists
          (fun prefix -> String.starts_with ~prefix line)
          [ cluster_name ^ "-cluster-"
          ; cluster_name ^ "-node-"
          ; cluster_name ^ "-remote-access-"
          ])
      [ "ec2"
      ; "describe-security-groups"
      ; "--region"
      ; region
      ; "--query"
      ; "SecurityGroups[].GroupName"
      ; "--output"
      ; "text"
      ]
  ; cluster_owned
      ~region
      ~cluster_name
      ~resource_class:"VPC"
      ~identity:
        (Printf.sprintf
           "tagged kubernetes.io/cluster/%s or named %s"
           cluster_name
           cluster_name)
      ~checked_as:
        (Printf.sprintf
           "aws ec2 describe-vpcs --region %s, then aws ec2 describe-tags --region %s \
            --filters Name=resource-id,Values=<vpc id> for each VPC it returns"
           region
           region)
      [ "ec2"
      ; "describe-vpcs"
      ; "--region"
      ; region
      ; "--query"
      ; "Vpcs[].VpcId"
      ; "--output"
      ; "text"
      ]
  ; cluster_owned
      ~region
      ~cluster_name
      ~resource_class:"subnet"
      ~identity:
        (Printf.sprintf
           "tagged kubernetes.io/cluster/%s or named %s-*"
           cluster_name
           cluster_name)
      ~checked_as:
        (Printf.sprintf
           "aws ec2 describe-subnets --region %s, then aws ec2 describe-tags --region %s \
            --filters Name=resource-id,Values=<subnet id> for each subnet it returns"
           region
           region)
      [ "ec2"
      ; "describe-subnets"
      ; "--region"
      ; region
      ; "--query"
      ; "Subnets[].SubnetId"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"IAM role"
      ~prefix:(cluster_name ^ "-")
      [ "iam"; "list-roles"; "--query"; "Roles[].RoleName"; "--output"; "text" ]
  ; prefixed_class
      ~resource_class:"IAM policy"
      ~prefix:(cluster_name ^ "-")
      [ "iam"
      ; "list-policies"
      ; "--scope"
      ; "Local"
      ; "--query"
      ; "Policies[].PolicyName"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"S3 bucket"
      ~prefix:(cluster_name ^ "-")
      [ "s3api"; "list-buckets"; "--query"; "Buckets[].Name"; "--output"; "text" ]
  ; prefixed_class
      ~resource_class:"CloudWatch dashboard"
      ~prefix:(cluster_name ^ "-")
      [ "cloudwatch"
      ; "list-dashboards"
      ; "--region"
      ; region
      ; "--query"
      ; "DashboardEntries[].DashboardName"
      ; "--output"
      ; "text"
      ]
  ; prefixed_class
      ~resource_class:"EKS control-plane log group"
      ~prefix:("/aws/eks/" ^ cluster_name)
      [ "logs"
      ; "describe-log-groups"
      ; "--region"
      ; region
      ; "--query"
      ; "logGroups[].logGroupName"
      ; "--output"
      ; "text"
      ]
  ; cluster_tagged
      ~cluster_name
      "load balancer"
      ~tagged_with:(fun arn ->
        [ "elbv2"
        ; "describe-tags"
        ; "--region"
        ; region
        ; "--resource-arns"
        ; arn
        ; "--query"
        ; Printf.sprintf
            "TagDescriptions[].Tags[?Key==`kubernetes.io/cluster/%s`].Value"
            cluster_name
        ; "--output"
        ; "text"
        ])
      ~checked_as:
        (Printf.sprintf
           "aws elbv2 describe-load-balancers --region %s, then aws elbv2 describe-tags \
            --region %s --resource-arns <load balancer arn> for each load balancer it \
            returns"
           region
           region)
      [ "elbv2"
      ; "describe-load-balancers"
      ; "--region"
      ; region
      ; "--query"
      ; "LoadBalancers[].LoadBalancerArn"
      ; "--output"
      ; "text"
      ]
  ; cluster_owned
      ~region
      ~cluster_name
      ~resource_class:"EBS volume"
      ~identity:
        (Printf.sprintf
           "tagged kubernetes.io/cluster/%s or named %s-*"
           cluster_name
           cluster_name)
      ~checked_as:
        (Printf.sprintf
           "aws ec2 describe-volumes --region %s, then aws ec2 describe-tags --region %s \
            --filters Name=resource-id,Values=<volume id> for each volume it returns"
           region
           region)
      [ "ec2"
      ; "describe-volumes"
      ; "--region"
      ; region
      ; "--query"
      ; "Volumes[].VolumeId"
      ; "--output"
      ; "text"
      ]
  ; (* An elastic IP is not a child of the VPC: releasing it is a separate
       provider action, so a VPC-absent observation does not prove it gone. The
       VPC module names the NAT EIPs <cluster>-<az>, and the Name fallback is
       fail-closed. *)
    cluster_owned
      ~region
      ~cluster_name
      ~resource_class:"elastic IP"
      ~identity:
        (Printf.sprintf
           "tagged kubernetes.io/cluster/%s or named %s-*"
           cluster_name
           cluster_name)
      ~checked_as:
        (Printf.sprintf
           "aws ec2 describe-addresses --region %s, then aws ec2 describe-tags --region \
            %s --filters Name=resource-id,Values=<allocation id> for each address it \
            returns"
           region
           region)
      [ "ec2"
      ; "describe-addresses"
      ; "--region"
      ; region
      ; "--query"
      ; "Addresses[].AllocationId"
      ; "--output"
      ; "text"
      ]
  ]
;;

let durable_observations ~(target : Sol_cli_config.target) =
  [ Sol_cli_absence.durable_state_bucket ~identity:"(the durable backend for this target)"
  ; External
      { resource_class = "Route 53 hosted zone"
      ; identity = Option.value target.base_domain ~default:"(the target's base domain)"
      ; reason =
          "a delegation zone is published by the operator and outlives the target, so \
           its presence is the contract, not residue"
      }
  ]
;;

let ecr_probe ~region ~repositories ~prefix =
  match repositories, prefix with
  | _ :: _, _ ->
    Ok
      (check
         ~resource_class:"ECR repository"
         ~identity:(String.concat ", " repositories)
         ~attribution:
           (Named_for_target
              "the pre-destroy Terraform state names the ECR repositories this target \
               created")
         ~attributable:(fun line -> List.mem line repositories)
         [ "ecr"
         ; "describe-repositories"
         ; "--region"
         ; region
         ; "--query"
         ; "repositories[].repositoryName"
         ; "--output"
         ; "text"
         ])
  | [], Some prefix ->
    Ok
      (check
         ~resource_class:"ECR repository"
         ~identity:(prefix ^ "/*")
         ~attribution:
           (Named_for_target
              (Printf.sprintf
                 "the target's declared registry names its workspace prefix %s, and the \
                  cluster root names its repositories %s/<service>"
                 prefix
                 prefix))
         ~attributable:(fun line ->
           String.equal line prefix || String.starts_with ~prefix:(prefix ^ "/") line)
         [ "ecr"
         ; "describe-repositories"
         ; "--region"
         ; region
         ; "--query"
         ; "repositories[].repositoryName"
         ; "--output"
         ; "text"
         ])
  | [], None ->
    Error
      ( "ECR repository"
      , "the pre-destroy Terraform state names no ECR repositories and the target \
         declares no registry, so Sol cannot distinguish \"this target created none\" \
         from \"the ownership record was lost\"; reported rather than guessed" )
;;

let authorization_checks ~environment =
  let policy_name = "sol-" ^ environment ^ "-workload-boundary" in
  let role_name = "sol-" ^ environment ^ "-authorization" in
  [ check
      ~resource_class:"authorization IAM policy"
      ~identity:policy_name
      ~attribution:
        (Named_for_target
           "the target's environment names the authorization workload boundary")
      ~attributable:(fun line -> line = policy_name)
      [ "iam"
      ; "list-policies"
      ; "--scope"
      ; "Local"
      ; "--query"
      ; "Policies[].PolicyName"
      ; "--output"
      ; "text"
      ]
  ; check
      ~resource_class:"authorization IAM role"
      ~identity:role_name
      ~attribution:
        (Named_for_target
           "the target's environment names the authorization reconciler role")
      ~attributable:(fun line -> line = role_name)
      [ "iam"; "list-roles"; "--query"; "Roles[].RoleName"; "--output"; "text" ]
  ; (* The authorization root creates one role per grant unit at
       /sol/<environment>/ and names it sol-<environment>-<unit>. They are not
       children of the reconciler role or the boundary policy, so the two
       exact-name checks above do not see them. The path filter keeps other
       environments' roles out even when their unit names overlap. *)
    check
      ~resource_class:"authorization workload role"
      ~identity:(Printf.sprintf "sol-%s-* under /sol/%s/" environment environment)
      ~attribution:
        (Named_for_target
           (Printf.sprintf
              "the target's environment names the workload role prefix sol-%s- at \
               /sol/%s/"
              environment
              environment))
      ~attributable:(fun line ->
        String.starts_with ~prefix:("sol-" ^ environment ^ "-") line)
      [ "iam"
      ; "list-roles"
      ; "--query"
      ; Printf.sprintf "Roles[?Path=='/sol/%s/'].RoleName" environment
      ; "--output"
      ; "text"
      ]
  ]
;;

let strict_authorization_observation ~check =
  match run ~check () with
  | Unobservable u ->
    Unobservable
      { u with
        resource_class = Sol_cli_absence.scope_class
      ; reason = check.resource_class ^ ": " ^ u.reason
      }
  | observation -> observation
;;

let filter_to_prior prior observation =
  match observation with
  | Present present ->
    let prior = List.map String.trim (prior_for present.resource_class prior) in
    let found =
      List.filter (fun item -> List.mem (String.trim item) prior) present.found
    in
    if found = []
    then
      Absent
        { resource_class = present.resource_class
        ; identity = present.identity
        ; attribution = present.attribution
        ; checked_with = present.checked_with
        }
    else Present { present with found }
  | observation -> observation
;;

let oidc_provider_urls pre_destroy =
  Sol_cli_cloud_destroy.resources pre_destroy
  |> List.filter_map (fun (resource : Sol_cli_cloud_destroy.resource) ->
    if String.equal resource.kind "aws_iam_openid_connect_provider"
    then resource.url
    else None)
  |> List.sort_uniq String.compare
;;

let oidc_url_suffix url =
  let prefix = "https://" in
  if String.starts_with ~prefix url
  then String.sub url (String.length prefix) (String.length url - String.length prefix)
  else url
;;

let oidc_provider_observation
      ?(previously_attributed = [])
      ~region
      ~cluster_name
      ~pre_destroy
      ~resource_class
      ()
  =
  let urls =
    match oidc_provider_urls pre_destroy with
    | _ :: _ as urls -> Ok urls
    | [] ->
      (match
         run_argv
           [ "eks"
           ; "describe-cluster"
           ; "--region"
           ; region
           ; "--name"
           ; cluster_name
           ; "--query"
           ; "cluster.identity.oidc.issuer"
           ; "--output"
           ; "text"
           ]
       with
       | Ok [ url ] when String.trim url <> "" -> Ok [ String.trim url ]
       | Ok _ -> Error "neither the state nor the cluster records an OIDC issuer"
       | Error (`NotFound _) ->
         (* An IAM OIDC provider outlives its EKS cluster. Empty Terraform state
            and an absent cluster do not establish that no provider was created;
            without an issuer or a prior identity it is unknown, not absence. *)
         Error
           "neither the state nor the cluster records an OIDC issuer, and an IAM OIDC \
            provider can outlive the cluster"
       | Error (`Failed reason) ->
         Error ("the cluster's OIDC issuer could not be read: " ^ String.trim reason))
  in
  match urls with
  | Error reason -> Not_attributable { resource_class; reason }
  | Ok urls ->
    run
      ~previously_attributed
      ~check:
        (check
           ~resource_class
           ~identity:(String.concat ", " urls)
           ~attribution:
             (Named_for_target
                "the target's own cluster issuer names the OIDC provider the cluster \
                 root created")
           ~attributable:(fun line ->
             List.exists
               (fun url -> String.ends_with ~suffix:(oidc_url_suffix url) line)
               urls)
           [ "iam"
           ; "list-open-id-connect-providers"
           ; "--query"
           ; "OpenIDConnectProviderList[].Arn"
           ; "--output"
           ; "text"
           ])
      ()
;;

(* DescribeSecret is the documented current read; ListSecrets can lag recent
   changes. Pending deletion is still present, and only this exact-name read's
   ResourceNotFoundException establishes absence. No secret value is requested. *)
let kafka_secret_observation ~region ~cluster_name ~resource_class () =
  let identity = Sol_cli_resource_binding.kafka_authority_name ~cluster_name in
  let argv =
    [ "aws"
    ; "secretsmanager"
    ; "describe-secret"
    ; "--secret-id"
    ; identity
    ; "--region"
    ; region
    ; "--query"
    ; "Name"
    ; "--output"
    ; "text"
    ]
  in
  let checked_with = String.concat " " argv in
  let attribution = Named_for_target (named_for_cluster cluster_name) in
  let unknown reason = Unobservable { resource_class; reason; checked_with } in
  match Sol_cli_process.run (Sol_cli_process.cmd argv) with
  | Ok output when String.trim output.stdout = identity && String.trim output.stderr = ""
    ->
    Present { resource_class; identity; attribution; checked_with; found = [ identity ] }
  | Ok _ -> unknown "DescribeSecret did not return the requested Kafka authority identity"
  | Error (Sol_cli_process.Non_zero result)
    when Sol_cli_string.contains ~needle:"(ResourceNotFoundException)" result.stderr ->
    Absent { resource_class; identity; attribution; checked_with }
  | Error (Sol_cli_process.Non_zero result) -> unknown (String.trim result.stderr)
  | Error _ -> unknown "the aws CLI is unavailable"
;;

(* Constructing probes performs no provider reads. Execution and coverage use
   this same sequence; an unattributable result does not advertise a query. *)
let probes
      ~previously_attributed
      ~authorization_identities
      ~pre_destroy
      ~region
      ~cluster_name
      ~registry
      ~environment
  =
  List.map
    (fun check ->
       Some check.resource_class, fun () -> run ~previously_attributed ~check ())
    (checks ~region ~cluster_name)
  @ [ (match
         ecr_probe
           ~region
           ~repositories:(ecr_repositories_of_state pre_destroy)
           ~prefix:registry
       with
       | Ok check -> Some check.resource_class, fun () -> run ~check ()
       | Error (resource_class, reason) ->
         None, fun () -> Not_attributable { resource_class; reason })
    ; (let resource_class = "Kafka credential secret" in
       Some resource_class, kafka_secret_observation ~region ~cluster_name ~resource_class)
    ; (let resource_class = "OIDC provider" in
       ( Some resource_class
       , oidc_provider_observation
           ~previously_attributed
           ~region
           ~cluster_name
           ~pre_destroy
           ~resource_class ))
    ]
  @ List.map
      (fun check ->
         ( Some check.resource_class
         , fun () ->
             strict_authorization_observation ~check
             |> filter_to_prior authorization_identities ))
      (authorization_checks ~environment)
;;

let observed_classes () =
  probes
    ~previously_attributed:[]
    ~authorization_identities:[]
    ~pre_destroy:Sol_cli_cloud_destroy.State_empty
    ~region:"coverage"
    ~cluster_name:"coverage"
    ~registry:(Some "coverage")
    ~environment:"coverage"
  |> List.filter_map fst
;;

let observations
      ?(previously_attributed = [])
      ?(pre_destroy = Sol_cli_cloud_destroy.State_empty)
      ?(authorization_identities = [])
      (target : Sol_cli_config.target)
      ~cluster_name
  =
  match scope_binding target with
  | Error reason -> Sol_cli_absence.scope_failure ~reason
  | Ok () ->
    (* Authorization resources outlive removal of the current trust declaration.
       Observe them unconditionally, retaining the exact prior-state filter. *)
    List.map
      (fun (_, observe) -> observe ())
      (probes
         ~previously_attributed
         ~authorization_identities
         ~pre_destroy
         ~region:target.region
         ~cluster_name
         ~registry:(registry_prefix target)
         ~environment:target.env)
    @ durable_observations ~target
;;

let substrate_absence (target : Sol_cli_config.target) ~cluster_name =
  match scope_binding target with
  | Error reason ->
    (match Sol_cli_absence.scope_failure ~reason with
     | [ observation ] -> observation
     | _ -> assert false)
  | Ok () -> run ~check:(cluster_check ~region:target.region ~cluster_name) ()
;;

let unresolved = Sol_cli_absence.unresolved

let authorization_state_identities
      ~(target : Sol_cli_config.target)
      (state : Sol_cli_cloud_destroy.state_read)
  =
  let resources = Sol_cli_cloud_destroy.resources state in
  let names kind =
    resources
    |> List.filter_map (fun (resource : Sol_cli_cloud_destroy.resource) ->
      if String.equal resource.kind kind then resource.name else None)
    |> List.sort_uniq String.compare
  in
  let reconciler = "sol-" ^ target.env ^ "-authorization" in
  let roles = names "aws_iam_role" in
  [ "authorization IAM role", List.filter (String.equal reconciler) roles
  ; ( "authorization workload role"
    , List.filter (fun name -> not (String.equal reconciler name)) roles )
  ; "authorization IAM policy", names "aws_iam_policy"
  ]
;;

let kafka_storage ~region ~namespace observation =
  let open Result.Syntax in
  let read argv =
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           (("aws" :: argv) @ [ "--region"; region; "--output"; "json" ]))
    with
    | Ok output when String.trim output.stderr = "" ->
      Sol_cli_json.decode ~what:"Kafka storage metadata" output.stdout
    | Ok output -> Error (String.trim output.stderr)
    | Error (Sol_cli_process.Non_zero output) -> Error (String.trim output.stderr)
    | Error _ -> Error "the aws CLI is unavailable"
  in
  let require what key convert value = Sol_cli_json.require ~what [ key ] convert value in
  let is_kafka identity =
    let* json = read [ "ec2"; "describe-volumes"; "--volume-ids"; identity ] in
    let* volumes = require "a volume response" "Volumes" Sol_cli_json.list json in
    let* volume =
      match volumes with
      | [ volume ] -> Ok volume
      | _ -> Error "the volume read did not return exactly its requested identity"
    in
    let* actual = require "a volume" "VolumeId" Sol_cli_json.string volume in
    let* () =
      if actual = identity
      then Ok ()
      else Error "volume metadata disagrees with its requested identity"
    in
    let* tags =
      Sol_cli_json.optional ~what:"a volume" [ "Tags" ] Sol_cli_json.list volume
    in
    let* tags =
      Sol_cli_result.map_list
        (fun tag ->
           let* key = require "a volume tag" "Key" Sol_cli_json.string tag in
           let* value = require "a volume tag" "Value" Sol_cli_json.string tag in
           Ok (key, value))
        (Option.value tags ~default:[])
    in
    match List.assoc_opt "kubernetes.io/created-for/pvc/namespace" tags with
    | Some claim when String.trim claim <> "" -> Ok (claim = namespace)
    | _ ->
      let* attachments =
        Sol_cli_json.optional ~what:"a volume" [ "Attachments" ] Sol_cli_json.list volume
      in
      let* boots =
        Sol_cli_result.map_list
          (fun attachment ->
             let* instance_id =
               require "a volume attachment" "InstanceId" Sol_cli_json.string attachment
             in
             let* json =
               read [ "ec2"; "describe-instances"; "--instance-ids"; instance_id ]
             in
             let* reservations =
               require "an instance response" "Reservations" Sol_cli_json.list json
             in
             let* groups =
               Sol_cli_result.map_list
                 (require "a reservation" "Instances" Sol_cli_json.list)
                 reservations
             in
             let* instance =
               match List.concat groups with
               | [ instance ] -> Ok instance
               | _ ->
                 Error "the instance read did not return exactly its requested identity"
             in
             let* actual =
               require "an instance" "InstanceId" Sol_cli_json.string instance
             in
             let* () =
               if actual = instance_id
               then Ok ()
               else Error "instance metadata disagrees with its requested identity"
             in
             let* root =
               require "an instance" "RootDeviceName" Sol_cli_json.string instance
             in
             let* mappings =
               require "an instance" "BlockDeviceMappings" Sol_cli_json.list instance
             in
             let* matches =
               Sol_cli_result.map_list
                 (fun mapping ->
                    let* device =
                      require "a block mapping" "DeviceName" Sol_cli_json.string mapping
                    in
                    if device <> root
                    then Ok false
                    else
                      let* volume =
                        Sol_cli_json.require
                          ~what:"a root block mapping"
                          [ "Ebs"; "VolumeId" ]
                          Sol_cli_json.string
                          mapping
                      in
                      Ok (volume = identity))
                 mappings
             in
             Ok (List.exists Fun.id matches))
          (Option.value attachments ~default:[])
      in
      if List.exists Fun.id boots
      then Ok false
      else
        Error
          "a target volume has neither attributable CSI namespace metadata nor a \
           confirmed node boot mapping; Kafka initialization is unresolved"
  in
  Sol_cli_kafka_authority.scope_storage observation ~is_kafka
;;

(* Reuse is a provider fact, not a Terraform-state inference. describe-secret is
   the documented current read; VersionIdsToStages identifies an active version
   without requesting the credential value. Pending deletion is not reusable
   authority, and an unreadable secret is unknown rather than absent. *)
let kafka_authority ~region ~cluster_name =
  let identity = Sol_cli_resource_binding.kafka_authority_name ~cluster_name in
  let checked_with =
    Printf.sprintf
      "aws secretsmanager describe-secret --secret-id %s --region %s"
      identity
      region
  in
  let unknown reason =
    Sol_cli_kafka_authority.Authority_unobservable
      (Printf.sprintf "%s (%s)" reason checked_with)
  in
  let argv =
    [ "aws"
    ; "secretsmanager"
    ; "describe-secret"
    ; "--secret-id"
    ; identity
    ; "--region"
    ; region
    ; "--query"
    ; "{deleted:DeletedDate,stages:VersionIdsToStages}"
    ; "--output"
    ; "json"
    ]
  in
  match Sol_cli_process.run (Sol_cli_process.cmd argv) with
  | Error (Sol_cli_process.Non_zero result)
    when Sol_cli_string.contains ~needle:"(ResourceNotFoundException)" result.stderr ->
    Sol_cli_kafka_authority.Authority_missing "the provider secret does not exist"
  | Error (Sol_cli_process.Non_zero result) -> unknown (String.trim result.stderr)
  | Error _ -> unknown "the aws CLI is unavailable"
  | Ok result when String.trim result.stderr <> "" -> unknown (String.trim result.stderr)
  | Ok result ->
    (match
       Sol_cli_json.decode_sensitive ~what:"the Kafka authority observation" result.stdout
     with
     | Error message -> unknown message
     | Ok json ->
       let stages =
         match Sol_cli_json.field [ "stages" ] json with
         | `Assoc fields -> Ok (List.map snd fields)
         | `Null -> Ok []
         | _ -> Error "the authority observation has no version-stage map"
       in
       (match stages with
        | Error message -> unknown message
        | Ok stages ->
          if Sol_cli_json.field [ "deleted" ] json <> `Null
          then
            Sol_cli_kafka_authority.Authority_missing
              "the provider secret is pending deletion"
          else if
            List.exists
              (function
                | `List values ->
                  List.exists
                    (function
                      | `String "AWSCURRENT" -> true
                      | _ -> false)
                    values
                | _ -> false)
              stages
          then Sol_cli_kafka_authority.Authority_current
          else
            Sol_cli_kafka_authority.Authority_missing
              "the provider secret has no active version"))
;;

(** Retrieve the authoritative Kafka credential for delivery. The value travels on stdout
    to the caller and never in an argv, plan, release record or diagnostic. *)
let kafka_credential ~region ~cluster_name =
  let identity = Sol_cli_resource_binding.kafka_authority_name ~cluster_name in
  let argv =
    [ "aws"
    ; "secretsmanager"
    ; "get-secret-value"
    ; "--secret-id"
    ; identity
    ; "--region"
    ; region
    ; "--query"
    ; "SecretString"
    ; "--output"
    ; "text"
    ]
  in
  match Sol_cli_process.run (Sol_cli_process.cmd argv) with
  | Ok result when String.trim result.stderr = "" ->
    let value = String.trim result.stdout in
    if value = "" then Error "the provider secret has no value" else Ok value
  | Ok result -> Error (String.trim result.stderr)
  | Error (Sol_cli_process.Non_zero result) -> Error (String.trim result.stderr)
  | Error _ -> Error "the aws CLI is unavailable"
;;
