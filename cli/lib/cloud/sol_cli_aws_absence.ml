open Sol_cli_absence
open Result.Syntax

type parent =
  { parent_class : string
  ; parent_identity : string
  }

type check =
  { resource_class : string
  ; identity : string
  ; attribution : attribution
  ; argv : string list
  ; attributable : string -> bool
  ; tagged_with : (string -> string list) option
  ; checked_as : string
  ; parent : parent option
  }

let check
      ?(attributable = fun _ -> true)
      ?tagged_with
      ?checked_as
      ?parent
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
  ; parent
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

type scope =
  { account : string
  ; region : string
  ; caller : string
  }

let account_of_arn value =
  match String.split_on_char ':' value with
  | _ :: _ :: _ :: _ :: account :: _
    when String.length account = 12
         && String.for_all (fun c -> c >= '0' && c <= '9') account -> Some account
  | _ -> None
;;

let account_of_registry = function
  | None -> None
  | Some registry ->
    (match String.index_opt registry '.' with
     | None -> None
     | Some index ->
       let account = String.sub registry 0 index in
       if
         String.length account = 12
         && String.for_all (fun c -> c >= '0' && c <= '9') account
       then Some account
       else None)
;;

let unique values = List.sort_uniq String.compare values

let declared_accounts (target : Sol_cli_config.target) =
  let keys =
    [ "cluster_access_role_arn"
    ; "provisioner_role_arn"
    ; "operator_role_arn"
    ; "reconciler_role_arn"
    ]
  in
  keys
  |> List.filter_map (fun key ->
    Option.bind (Sol_cli_config.provider_field target key) account_of_arn)
  |> unique
;;

let expected_account (target : Sol_cli_config.target) =
  match declared_accounts target with
  | [ account ] -> Ok account
  | [] ->
    (match account_of_registry target.registry with
     | Some account -> Ok account
     | None ->
       Error
         "the target declares no authoritative AWS account identity: no \
          cluster_access_role_arn, provisioner_role_arn, operator_role_arn or \
          reconciler_role_arn names an account, and its registry names none either. An \
          inventory cannot prove which account it read, so it cannot establish absence.")
  | accounts ->
    Error
      (Printf.sprintf
         "the target's declared AWS identities name more than one account (%s), so the \
          account this inventory would read is ambiguous and absence cannot be \
          established"
         (String.concat ", " accounts))
;;

let run_checked argv =
  let command = "aws " ^ String.concat " " argv in
  match Sol_cli_process.run (Sol_cli_process.cmd ("aws" :: argv)) with
  | Ok { Sol_cli_process.stdout; _ } -> Ok (String.trim stdout)
  | Error (Sol_cli_process.Non_zero r) ->
    Error (Printf.sprintf "%s exited %d: %s" command r.exit_code (String.trim r.stderr))
  | Error error ->
    Error
      (Printf.sprintf
         "%s could not run: %s"
         command
         (Sol_cli_process.error_to_string error))
;;

let establish_scope (target : Sol_cli_config.target) =
  let* account = expected_account target in
  let* caller =
    run_checked [ "sts"; "get-caller-identity"; "--query"; "Account"; "--output"; "text" ]
  in
  if not (String.equal caller account)
  then
    Error
      (Printf.sprintf
         "the caller is AWS account %S, not the target's declared account %S, so the \
          inventory cannot say which account it would be reading"
         caller
         account)
  else Ok { account; region = target.region; caller }
;;

let scope_checked_with scope value =
  Printf.sprintf
    "%s (account %s, region %s, caller %s)"
    value
    scope.account
    scope.region
    scope.caller
;;

let parent_is_absent ~observations = function
  | None -> false
  | Some { parent_class; parent_identity } ->
    List.exists
      (function
        | Absent { resource_class; identity; _ } ->
          String.equal resource_class parent_class
          && String.equal identity parent_identity
        | _ -> false)
      observations
;;

let run ~scope ~observations ~check =
  let checked_as = scope_checked_with scope check.checked_as in
  let unobservable reason =
    Unobservable
      { resource_class = check.resource_class
      ; reason = String.trim reason
      ; checked_with = checked_as
      }
  in
  let observed found =
    match found with
    | [] ->
      Absent
        { resource_class = check.resource_class
        ; identity = check.identity
        ; attribution = check.attribution
        ; checked_with = checked_as
        }
    | found ->
      Present
        { resource_class = check.resource_class
        ; identity = check.identity
        ; found
        ; attribution = check.attribution
        ; checked_with = checked_as
        }
  in
  match run_argv check.argv with
  | Error (`NotFound reason) | Error (`Failed reason) ->
    if parent_is_absent ~observations check.parent
    then
      Absent
        { resource_class = check.resource_class
        ; identity = check.identity
        ; attribution = check.attribution
        ; checked_with =
            Printf.sprintf
              "%s (its parent %s %s is positively absent, so it cannot exist; the \
               provider said: %s)"
              checked_as
              (match check.parent with
               | None -> ""
               | Some parent -> parent.parent_class)
              (match check.parent with
               | None -> ""
               | Some parent -> parent.parent_identity)
              (String.trim reason)
        }
    else unobservable reason
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
      ~parent:{ parent_class = "EKS cluster"; parent_identity = cluster_name }
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

let class_names =
  [ "EKS cluster"
  ; "EKS node group"
  ; "RDS instance"
  ; "RDS subnet group"
  ; "security group"
  ; "VPC"
  ; "subnet"
  ; "IAM role"
  ; "IAM policy"
  ; "S3 bucket"
  ; "CloudWatch dashboard"
  ; "EKS control-plane log group"
  ; "load balancer"
  ; "EBS volume"
  ; "ECR repository"
  ]
;;

let ecr_observation ~scope ~observations ~region ~registry =
  match registry with
  | Some prefix ->
    run
      ~scope
      ~observations
      ~check:
        (check
           ~resource_class:"ECR repository"
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
    Not_attributable
      { resource_class = "ECR repository"
      ; reason =
          "the target declares no registry, so Sol cannot say which repositories under \
           this account belong to it -- reported rather than guessed"
      }
;;

let run_checks ~scope checks =
  let rec go observations = function
    | [] -> List.rev observations
    | check :: rest ->
      let observation = run ~scope ~observations ~check in
      go (observation :: observations) rest
  in
  go [] checks
;;

let scope_failure reason =
  Unobservable
    { resource_class = Sol_cli_absence.scope_class
    ; reason
    ; checked_with = "aws sts get-caller-identity --query Account --output text"
    }
;;

let observations (target : Sol_cli_config.target) ~cluster_name =
  match establish_scope target with
  | Error reason -> [ scope_failure reason ] @ durable_observations ~target
  | Ok scope ->
    let observations = run_checks ~scope (checks ~region:target.region ~cluster_name) in
    let ecr =
      ecr_observation
        ~scope
        ~observations
        ~region:target.region
        ~registry:(registry_prefix target)
    in
    observations @ [ ecr ] @ durable_observations ~target
;;

let substrate_absence (target : Sol_cli_config.target) ~cluster_name =
  match establish_scope target with
  | Error reason ->
    (match scope_failure reason with
     | Unobservable u -> Unobservable { u with resource_class = "EKS cluster" }
     | observation -> observation)
  | Ok scope ->
    run ~scope ~observations:[] ~check:(cluster_check ~region:target.region ~cluster_name)
;;

let unresolved = Sol_cli_absence.unresolved
