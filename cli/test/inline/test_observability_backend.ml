let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

module U = Sol_cli_observability_backend

let test_backend_of_string_valid () =
  check_bool "local" true (U.backend_of_string "local" = Some U.Local);
  check_bool
    "self_hosted_durable"
    true
    (U.backend_of_string "self_hosted_durable" = Some U.Self_hosted_durable);
  check_bool "external" true (U.backend_of_string "external" = Some U.External)
;;

let test_backend_of_string_invalid () =
  check_bool "unknown string -> None" true (U.backend_of_string "bogus" = None)
;;

let test_backend_to_string_roundtrip () =
  List.iter
    (fun b ->
       check_bool "roundtrip" true (U.backend_of_string (U.backend_to_string b) = Some b))
    [ U.Local; U.Self_hosted_durable; U.External ]
;;

let%test "backend_of_string: valid values" = test_backend_of_string_valid ()
let%test "backend_of_string: invalid value" = test_backend_of_string_invalid ()
let%test "backend_of_string: roundtrip" = test_backend_to_string_roundtrip ()

let test_external_validation () =
  let valid =
    U.validate_external
      ~logs_url:(Some "https://logs.example.com/loki/api/v1/push")
      ~metrics_url:(Some "https://metrics.example.com/api/prom/push")
      ~traces_url:(Some "https://otlp.example.com/v1/traces")
  in
  check_bool "complete external backend" true (Result.is_ok valid);
  check_bool
    "missing logs refuses"
    true
    (Result.is_error
       (U.validate_external
          ~logs_url:None
          ~metrics_url:(Some "https://metrics.example.com/api/prom/push")
          ~traces_url:None));
  check_bool
    "invalid metrics refuses"
    true
    (Result.is_error
       (U.validate_external
          ~logs_url:(Some "https://logs.example.com/loki/api/v1/push")
          ~metrics_url:(Some "not-a-url")
          ~traces_url:None));
  check_bool
    "empty traces disables tracing"
    true
    (Result.is_ok
       (U.validate_external
          ~logs_url:(Some "https://logs.example.com/loki/api/v1/push")
          ~metrics_url:(Some "https://metrics.example.com/api/prom/push")
          ~traces_url:(Some "")));
  check_bool
    "invalid traces refuses"
    true
    (Result.is_error
       (U.validate_external
          ~logs_url:(Some "https://logs.example.com/loki/api/v1/push")
          ~metrics_url:(Some "https://metrics.example.com/api/prom/push")
          ~traces_url:(Some "ftp://traces")))
;;

let%test "external observability validation" = test_external_validation ()

let test_unknown_backend_is_refused () =
  let target : Sol_cli_config.target =
    { Sol_cli_config.name = "dev/aws/us-east-1"
    ; env = "dev"
    ; provider = Sol_cli_provider.Aws
    ; region = "us-east-1"
    ; registry = None
    ; base_domain = None
    ; cluster_issuer = None
    ; letsencrypt_email = None
    ; cluster_name = None
    ; kube_context = None
    ; kubeconfig = None
    ; terraform_var_file = None
    ; observability_backend = Some "datadog"
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
    ; state_bucket = None
    ; cluster_endpoint_cidr = None
    ; dns_zone_ownership = None
    ; node_failure_headroom_nodes = None
    ; profile = None
    ; shape = None
    ; provider_fields = []
    ; secret_authorities = []
    }
  in
  check_bool "unknown backend refused" true (Result.is_error (U.validate_target target))
;;

let%test "unknown observability backend refused" = test_unknown_backend_is_refused ()

let test_export_terraform_secrets () =
  let target : Sol_cli_config.target =
    { Sol_cli_config.name = "dev/aws/us-east-1"
    ; env = "dev"
    ; provider = Sol_cli_provider.Aws
    ; region = "us-east-1"
    ; registry = None
    ; base_domain = None
    ; cluster_issuer = None
    ; letsencrypt_email = None
    ; cluster_name = None
    ; kube_context = None
    ; kubeconfig = None
    ; terraform_var_file = None
    ; observability_backend = Some "external"
    ; observability_logs_url = Some "https://logs.example.com/loki/api/v1/push"
    ; observability_logs_username = Some "123"
    ; observability_logs_password_env = Some "SOL_TEST_LOKI_PASSWORD"
    ; observability_metrics_url = Some "https://metrics.example.com/api/prom/push"
    ; observability_metrics_username = Some "456"
    ; observability_metrics_password_env = Some "SOL_TEST_PROM_PASSWORD"
    ; observability_traces_url = None
    ; destroy_retention = None
    ; alert_receiver_type = None
    ; alert_receiver_url = None
    ; alert_owner = None
    ; alert_runbook_url = None
    ; state_bucket = None
    ; cluster_endpoint_cidr = None
    ; dns_zone_ownership = None
    ; node_failure_headroom_nodes = None
    ; profile = None
    ; shape = None
    ; provider_fields = []
    ; secret_authorities = []
    }
  in
  Unix.putenv "SOL_TEST_LOKI_PASSWORD" "loki-secret";
  Unix.putenv "SOL_TEST_PROM_PASSWORD" "prom-secret";
  match U.export_terraform_secrets target with
  | Error message -> Windtrap.fail message
  | Ok () ->
    check_bool
      "logs password exported as TF_VAR"
      true
      (Sys.getenv_opt "TF_VAR_external_loki_password" = Some "loki-secret");
    check_bool
      "metrics password exported as TF_VAR"
      true
      (Sys.getenv_opt "TF_VAR_external_prometheus_password" = Some "prom-secret")
;;

let%test "external credentials export as Terraform env" = test_export_terraform_secrets ()
