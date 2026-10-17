type ownership =
  | Direct
  | Direct_not_recoverable of string
  | In_cluster of string
  | Synthetic of string
  | External_by_contract of string

type entry =
  { address : string
  ; resource_class : string
  ; observed_as : string
  ; ownership : ownership
  ; identity : string
  ; import_identity : string
  }

type type_rule =
  { terraform_type : string
  ; ownership : ownership
  }

let entry address ownership ~resource_class ~observed_as ~identity ~import_identity =
  { address; resource_class; observed_as; ownership; identity; import_identity }
;;

let direct = Direct
let not_recoverable reason = Direct_not_recoverable reason

let in_cluster =
  In_cluster
    "Terraform declares it, but the object lives inside the cluster: its absence follows \
     from the cluster's, and it has no provider identity of its own to recover"
;;

let synthetic =
  Synthetic
    "Terraform-internal bookkeeping: it creates no provider object, so there is nothing \
     outside the state to recover"
;;

let external_by_contract =
  External_by_contract
    "durable or external by contract: it outlives the target and is not this target's \
     residue to reclaim"
;;

let composite_identity =
  "the provider addresses this resource through a composite identity Sol has not \
   established, so Terraform ownership cannot be restored by guesswork -- the boundary \
   is reported rather than crossed"
;;

let arn_needs_account =
  "the policy's import identity is its ARN, which needs the account id the target does \
   not carry"
;;

let ownership_kind = function
  | Direct -> "Direct"
  | Direct_not_recoverable _ -> "Direct_not_recoverable"
  | In_cluster _ -> "In_cluster"
  | Synthetic _ -> "Synthetic"
  | External_by_contract _ -> "External_by_contract"
;;

let ownership_reason = function
  | Direct ->
    "Terraform declares it and can destroy it, so a provider copy the state never \
     adopted can be brought back under Terraform ownership through its import identity"
  | Direct_not_recoverable reason -> reason
  | In_cluster reason -> reason
  | Synthetic reason -> reason
  | External_by_contract reason -> reason
;;

let is_direct (entry : entry) =
  match entry.ownership with
  | Direct -> true
  | Direct_not_recoverable _ | In_cluster _ | Synthetic _ | External_by_contract _ ->
    false
;;

let recoverable (entry : entry) =
  match entry.ownership with
  | Direct -> entry.import_identity <> "" && entry.observed_as <> ""
  | Direct_not_recoverable _ | In_cluster _ | Synthetic _ | External_by_contract _ ->
    false
;;

let inside_the_instance =
  Direct_not_recoverable
    "it lives inside the Cloud SQL instance Terraform declares, so the instance's \
     absence removes it and no separate adoption is needed"
;;

let inside_the_control_plane =
  Direct_not_recoverable
    "an add-on runs inside the control plane, so it is removed with the cluster, and the \
     inventory has no separate class for it"
;;

let part_of_the_bucket =
  Direct_not_recoverable
    "a lifecycle configuration is part of the bucket it belongs to and cannot outlive it"
;;

let type_rules =
  [ { terraform_type = "kubernetes_"; ownership = in_cluster }
  ; { terraform_type = "helm_"; ownership = in_cluster }
  ; { terraform_type = "terraform_data"; ownership = synthetic }
  ; { terraform_type = "random_"; ownership = synthetic }
  ; { terraform_type = "null_resource"; ownership = synthetic }
  ]
;;

let gcp ~cluster_name ~project_id =
  let project =
    match project_id with
    | Some project when not (Sol_cli_string.is_blank project) ->
      Some (String.trim project)
    | Some _ | None -> None
  in
  let service_account account =
    match project with
    | Some project ->
      let email = account ^ "@" ^ project ^ ".iam.gserviceaccount.com" in
      email, "projects/" ^ project ^ "/serviceAccounts/" ^ email
    | None -> "", ""
  in
  let provisioner_observed, provisioner_import =
    service_account (cluster_name ^ "-provisioner")
  in
  let loki_observed, loki_import = service_account (cluster_name ^ "-loki") in
  let thanos_observed, thanos_import = service_account (cluster_name ^ "-thanos") in
  let cert_manager_observed, cert_manager_import =
    service_account (cluster_name ^ "-cert-manager")
  in
  let underscored =
    String.map
      (function
        | '-' -> '_'
        | c -> c)
      cluster_name
  in
  [ entry
      "google_compute_network.main"
      direct
      ~resource_class:"VPC network"
      ~observed_as:cluster_name
      ~identity:"the target's own VPC, named after the cluster"
      ~import_identity:cluster_name
  ; entry
      "google_compute_subnetwork.main"
      direct
      ~resource_class:"subnetwork"
      ~observed_as:(cluster_name ^ "-nodes")
      ~identity:(cluster_name ^ "-nodes")
      ~import_identity:(cluster_name ^ "-nodes")
  ; entry
      "google_compute_router.main"
      direct
      ~resource_class:"Cloud Router"
      ~observed_as:(cluster_name ^ "-router")
      ~identity:(cluster_name ^ "-router")
      ~import_identity:(cluster_name ^ "-router")
  ; entry
      "google_compute_router_nat.main"
      direct
      ~resource_class:"Cloud NAT"
      ~observed_as:(cluster_name ^ "-nat")
      ~identity:(cluster_name ^ "-nat")
      ~import_identity:(cluster_name ^ "-router/" ^ cluster_name ^ "-nat")
  ; entry
      "google_container_cluster.main"
      direct
      ~resource_class:"GKE cluster"
      ~observed_as:cluster_name
      ~identity:cluster_name
      ~import_identity:cluster_name
  ; entry
      "google_container_node_pool.main"
      direct
      ~resource_class:"GKE node pool"
      ~observed_as:(cluster_name ^ "-nodes")
      ~identity:(cluster_name ^ "-nodes")
      ~import_identity:(cluster_name ^ "/" ^ cluster_name ^ "-nodes")
  ; entry
      "google_artifact_registry_repository.images"
      direct
      ~resource_class:"Artifact Registry repository"
      ~observed_as:cluster_name
      ~identity:cluster_name
      ~import_identity:cluster_name
    (* The cluster root declares the Cloud SQL instance with `count = var.create_database ? 1 : 0`,
     so its Terraform address is indexed. The address must be the one `terraform import` can
     resolve against the configuration and the one a state read reports; a bare address for a
     counted resource fails with "Configuration for import target does not exist" and would
     leave the instance unadoptable (#1476). *)
  ; entry
      "google_sql_database_instance.postgres[0]"
      direct
      ~resource_class:"Cloud SQL instance"
      ~observed_as:(cluster_name ^ "-postgres")
      ~identity:(cluster_name ^ "-postgres")
      ~import_identity:(cluster_name ^ "-postgres")
  ; entry
      "google_sql_database.app"
      inside_the_instance
      ~resource_class:""
      ~observed_as:""
      ~identity:"the application database inside the instance"
      ~import_identity:("app/" ^ cluster_name ^ "-postgres")
  ; entry
      "google_sql_user.postgres"
      inside_the_instance
      ~resource_class:""
      ~observed_as:""
      ~identity:"the application database's owner role"
      ~import_identity:("postgres/" ^ cluster_name ^ "-postgres")
  ; entry
      "google_compute_global_address.sql_peering"
      direct
      ~resource_class:"reserved global address"
      ~observed_as:(cluster_name ^ "-sql-peering")
      ~identity:(cluster_name ^ "-sql-peering")
      ~import_identity:(cluster_name ^ "-sql-peering")
  ; entry
      "google_service_account.provisioner"
      direct
      ~resource_class:"service account"
      ~observed_as:provisioner_observed
      ~identity:(cluster_name ^ "-provisioner")
      ~import_identity:provisioner_import
  ; entry
      "google_service_account.loki[0]"
      direct
      ~resource_class:"service account"
      ~observed_as:loki_observed
      ~identity:(cluster_name ^ "-loki")
      ~import_identity:loki_import
  ; entry
      "google_service_account.thanos[0]"
      direct
      ~resource_class:"service account"
      ~observed_as:thanos_observed
      ~identity:(cluster_name ^ "-thanos")
      ~import_identity:thanos_import
  ; entry
      "google_service_account.cert_manager"
      direct
      ~resource_class:"service account"
      ~observed_as:cert_manager_observed
      ~identity:(cluster_name ^ "-cert-manager")
      ~import_identity:cert_manager_import
  ; entry
      "google_project_iam_custom_role.provisioner_cluster_access"
      direct
      ~resource_class:"custom role"
      ~observed_as:("sol_" ^ underscored ^ "_cluster_access")
      ~identity:("sol_" ^ underscored ^ "_cluster_access")
      ~import_identity:("projects/-/roles/sol_" ^ underscored ^ "_cluster_access")
  ; entry
      "google_project_iam_custom_role.cert_manager_dns_records"
      direct
      ~resource_class:"custom role"
      ~observed_as:("sol_" ^ underscored ^ "_cert_manager_dns_records")
      ~identity:("sol_" ^ underscored ^ "_cert_manager_dns_records")
      ~import_identity:
        ("projects/-/roles/sol_" ^ underscored ^ "_cert_manager_dns_records")
  ; entry
      "google_project_iam_custom_role.cert_manager_dns_discovery"
      direct
      ~resource_class:"custom role"
      ~observed_as:("sol_" ^ underscored ^ "_cert_manager_dns_discovery")
      ~identity:("sol_" ^ underscored ^ "_cert_manager_dns_discovery")
      ~import_identity:
        ("projects/-/roles/sol_" ^ underscored ^ "_cert_manager_dns_discovery")
  ; entry
      "google_storage_bucket.loki"
      external_by_contract
      ~resource_class:"storage bucket"
      ~observed_as:(cluster_name ^ "-loki-logs")
      ~identity:(cluster_name ^ "-loki-logs")
      ~import_identity:(cluster_name ^ "-loki-logs")
  ; entry
      "google_storage_bucket.thanos"
      external_by_contract
      ~resource_class:"storage bucket"
      ~observed_as:(cluster_name ^ "-thanos-metrics")
      ~identity:(cluster_name ^ "-thanos-metrics")
      ~import_identity:(cluster_name ^ "-thanos-metrics")
  ; entry
      "google_service_networking_connection.sql"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:cluster_name
      ~identity:"the Cloud SQL peering on the target's own VPC"
      ~import_identity:""
  ; entry
      "google_dns_managed_zone.main"
      external_by_contract
      ~resource_class:""
      ~observed_as:""
      ~identity:"the target's base domain delegation"
      ~import_identity:""
  ; entry
      "google_artifact_registry_repository_iam_member.gke_pull"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"the registry pull grant"
      ~import_identity:""
  ; entry
      "google_project_iam_member.provisioner_cluster_access"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"the provisioner's cluster-access grant"
      ~import_identity:""
  ; entry
      "google_service_account_iam_member.provisioner_impersonators"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"who may impersonate the provisioner"
      ~import_identity:""
  ; entry
      "google_storage_bucket_iam_member.loki"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"Loki's bucket grant"
      ~import_identity:""
  ; entry
      "google_storage_bucket_iam_member.thanos"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"Thanos's bucket grant"
      ~import_identity:""
  ; entry
      "google_service_account_iam_member.loki_workload_identity"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"Loki's workload identity binding"
      ~import_identity:""
  ; entry
      "google_service_account_iam_member.thanos_workload_identity"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"Thanos's workload identity binding"
      ~import_identity:""
  ; entry
      "google_service_account_iam_member.cert_manager_workload_identity"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"cert-manager's workload identity binding"
      ~import_identity:""
  ; entry
      "google_dns_managed_zone_iam_member.cert_manager_dns_records"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"cert-manager's DNS record grant"
      ~import_identity:""
  ; entry
      "google_project_iam_member.cert_manager_dns_discovery"
      (not_recoverable composite_identity)
      ~resource_class:""
      ~observed_as:""
      ~identity:"cert-manager's DNS discovery grant"
      ~import_identity:""
  ]
;;

let aws ~cluster_name =
  [ entry
      "aws_db_instance.postgres[0]"
      direct
      ~resource_class:"RDS instance"
      ~observed_as:(cluster_name ^ "-postgres")
      ~identity:(cluster_name ^ "-postgres")
      ~import_identity:(cluster_name ^ "-postgres")
  ; entry
      "aws_db_subnet_group.main[0]"
      direct
      ~resource_class:"RDS subnet group"
      ~observed_as:(cluster_name ^ "-postgres")
      ~identity:(cluster_name ^ "-postgres")
      ~import_identity:(cluster_name ^ "-postgres")
  ; entry
      "aws_security_group.rds[0]"
      direct
      ~resource_class:"security group"
      ~observed_as:(cluster_name ^ "-rds")
      ~identity:(cluster_name ^ "-rds")
      ~import_identity:(cluster_name ^ "-rds")
  ; entry
      "aws_eks_addon.ebs_csi_driver"
      inside_the_control_plane
      ~resource_class:""
      ~observed_as:""
      ~identity:(cluster_name ^ ":aws-ebs-csi-driver")
      ~import_identity:(cluster_name ^ ":aws-ebs-csi-driver")
  ; entry
      "aws_s3_bucket_lifecycle_configuration.loki"
      part_of_the_bucket
      ~resource_class:""
      ~observed_as:""
      ~identity:(cluster_name ^ "-loki-logs lifecycle configuration")
      ~import_identity:(cluster_name ^ "-loki-logs")
  ; entry
      "aws_iam_policy.cert_manager"
      (not_recoverable arn_needs_account)
      ~resource_class:"IAM policy"
      ~observed_as:(cluster_name ^ "-cert-manager")
      ~identity:(cluster_name ^ "-cert-manager")
      ~import_identity:""
  ; entry
      "aws_iam_policy.grafana_cloudwatch"
      (not_recoverable arn_needs_account)
      ~resource_class:"IAM policy"
      ~observed_as:(cluster_name ^ "-grafana-cloudwatch")
      ~identity:(cluster_name ^ "-grafana-cloudwatch")
      ~import_identity:""
  ; entry
      "aws_iam_policy.loki_s3"
      (not_recoverable arn_needs_account)
      ~resource_class:"IAM policy"
      ~observed_as:(cluster_name ^ "-loki-s3")
      ~identity:(cluster_name ^ "-loki-s3")
      ~import_identity:""
  ; entry
      "aws_iam_policy.thanos_s3"
      (not_recoverable arn_needs_account)
      ~resource_class:"IAM policy"
      ~observed_as:(cluster_name ^ "-thanos-s3")
      ~identity:(cluster_name ^ "-thanos-s3")
      ~import_identity:""
  ; entry
      "aws_ecr_repository.services"
      (not_recoverable
         "the repository name carries the workspace layout, which the target does not \
          declare")
      ~resource_class:"ECR repository"
      ~observed_as:""
      ~identity:"the target's registry path"
      ~import_identity:""
  ; entry
      "aws_ecr_lifecycle_policy.services"
      (not_recoverable
         "it is addressed through the repository it belongs to, whose name depends on \
          the workspace layout")
      ~resource_class:""
      ~observed_as:""
      ~identity:"the target's registry lifecycle"
      ~import_identity:""
  ; entry
      "aws_cloudwatch_dashboard.managed_resource"
      (not_recoverable
         "the dashboard name carries a per-resource key Sol cannot reconstruct from the \
          target alone")
      ~resource_class:"CloudWatch dashboard"
      ~observed_as:""
      ~identity:(cluster_name ^ "-*")
      ~import_identity:""
  ; entry
      "aws_s3_bucket.loki"
      external_by_contract
      ~resource_class:"S3 bucket"
      ~observed_as:(cluster_name ^ "-loki-logs")
      ~identity:(cluster_name ^ "-loki-logs")
      ~import_identity:(cluster_name ^ "-loki-logs")
  ; entry
      "aws_s3_bucket.thanos"
      external_by_contract
      ~resource_class:"S3 bucket"
      ~observed_as:(cluster_name ^ "-thanos-metrics")
      ~identity:(cluster_name ^ "-thanos-metrics")
      ~import_identity:(cluster_name ^ "-thanos-metrics")
  ; entry
      "aws_route53_zone.main"
      external_by_contract
      ~resource_class:""
      ~observed_as:""
      ~identity:"the target's base domain delegation"
      ~import_identity:""
  ]
;;
