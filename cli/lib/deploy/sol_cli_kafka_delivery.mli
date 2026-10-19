(** The deploy's one writer for a managed Kafka consumer projection.

    External Kafka keeps its existing ESO delivery, and local Kafka is deliberately
    plaintext, so neither is written here. For a managed binding this reads the
    authoritative credential from the provider and the chart-owned CA from Kubernetes,
    then writes both required keys atomically to `<target>-kafka-creds` in each
    namespace that declares a Kafka consumer. Failure reports namespaces already
    updated; retrying reconciles the remainder. *)

val run
  :  ctx:Sol_cli_kube_destination.context
  -> target:Sol_cli_config.target
  -> kafka:Sol_cli_resource_binding.kafka
  -> services:Sol_cli_deployment_plan.service_spec list
  -> (unit, string) result
