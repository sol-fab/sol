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

let run ~check =
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
    let candidates = List.filter check.attributable candidates in
    (match check.tagged_with with
     | None -> observed candidates
     | Some tag_argv ->
       let rec resolve acc = function
         | [] -> Ok (List.rev acc)
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

let cluster_tag_named cluster_name =
  Printf.sprintf "Name=tag:kubernetes.io/cluster/%s,Values=owned,shared" cluster_name
;;

let ec2_tagged_argv ~region ~tag ~subcommand ~query =
  [ "ec2"
  ; subcommand
  ; "--region"
  ; region
  ; "--filters"
  ; tag
  ; "--query"
  ; query
  ; "--output"
  ; "text"
  ]
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
             created,              and Sol writes it itself"
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
  ; cluster_tagged
      ~cluster_name
      "VPC"
      (ec2_tagged_argv
         ~region
         ~tag:(cluster_tag_named cluster_name)
         ~subcommand:"describe-vpcs"
         ~query:"Vpcs[].VpcId")
  ; cluster_tagged
      ~cluster_name
      "subnet"
      (ec2_tagged_argv
         ~region
         ~tag:(cluster_tag_named cluster_name)
         ~subcommand:"describe-subnets"
         ~query:"Subnets[].SubnetId")
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
  ; cluster_tagged
      ~cluster_name
      "EBS volume"
      (ec2_tagged_argv
         ~region
         ~tag:(cluster_tag_named cluster_name)
         ~subcommand:"describe-volumes"
         ~query:"Volumes[].VolumeId")
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

let ecr_probe ~region ~registry =
  let resource_class = "ECR repository" in
  match registry with
  | Some prefix ->
    Ok
      (check
         ~resource_class
         ~identity:(prefix ^ "/*")
         ~attribution:
           (Named_for_target
              (Printf.sprintf
                 "the target's own registry path: the cluster root names its \
                  repositories under %s, which the target declares"
                 prefix))
         ~attributable:(fun line -> Sol_cli_string.contains ~needle:(prefix ^ "/") line)
         [ "ecr"
         ; "describe-repositories"
         ; "--region"
         ; region
         ; "--query"
         ; "repositories[].repositoryName"
         ; "--output"
         ; "text"
         ])
  | None ->
    Error
      ( resource_class
      , "the target declares no registry, so Sol cannot say which repositories under \
         this account belong to it -- reported rather than guessed" )
;;

let authorization_checks ~env =
  let policy_name = "sol-" ^ env ^ "-workload-boundary" in
  let role_name = "sol-" ^ env ^ "-authorization" in
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
  ]
;;

let strict_authorization_observation ~check =
  match run ~check with
  | Unobservable u ->
    Unobservable
      { u with
        resource_class = Sol_cli_absence.scope_class
      ; reason = check.resource_class ^ ": " ^ u.reason
      }
  | observation -> observation
;;

(* Both execution and advertised coverage consume this same probe sequence. An
   unavailable ownership identity remains an explicit observation, not a missing probe. *)
let probes ~region ~cluster_name ~registry =
  List.map (fun check -> Ok check) (checks ~region ~cluster_name)
  @ [ ecr_probe ~region ~registry ]
;;

let observed_classes () =
  probes ~region:"coverage" ~cluster_name:"coverage" ~registry:(Some "coverage")
  @ List.map (fun check -> Ok check) (authorization_checks ~env:"coverage")
  |> List.filter_map (function
    | Ok check -> Some check.resource_class
    | Error _ -> None)
;;

let observations (target : Sol_cli_config.target) ~cluster_name =
  match scope_binding target with
  | Error reason -> Sol_cli_absence.scope_failure ~reason
  | Ok () ->
    let observations =
      List.map
        (function
          | Ok check -> run ~check
          | Error (resource_class, reason) -> Not_attributable { resource_class; reason })
        (probes ~region:target.region ~cluster_name ~registry:(registry_prefix target))
    in
    let observations =
      if Sol_cli_provider_capabilities.authorization_trust target = None
      then observations
      else
        observations
        @ List.map
            (fun check -> strict_authorization_observation ~check)
            (authorization_checks ~env:target.env)
    in
    observations @ durable_observations ~target
;;

let substrate_absence (target : Sol_cli_config.target) ~cluster_name =
  match scope_binding target with
  | Error reason ->
    (match Sol_cli_absence.scope_failure ~reason with
     | [ observation ] -> observation
     | _ -> assert false)
  | Ok () -> run ~check:(cluster_check ~region:target.region ~cluster_name)
;;

let unresolved = Sol_cli_absence.unresolved
