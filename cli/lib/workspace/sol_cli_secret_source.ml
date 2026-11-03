(** The model's credential vocabulary: where a value comes from, and which access class a
    consumer is entitled to.

    This module is deliberately neutral — it depends on nothing and it renders nothing. The
    deployment model and the renderers both consume it, so the type is owned by the model
    rather than by whichever module happened to need it first. A renderer re-exporting it is
    fine; a renderer *defining* it is what this replaces. *)

(** Where a value comes from.

    [Sol_managed] means Sol holds the authoritative value in the unit's Kubernetes Secret
    and the operator writes it with `sol secret set`. [Provider] is the same authority on a
    managed AWS/GCP target, but the value lives in the provider store and is delivered to
    the workload as a mounted file, never mirrored into a Kubernetes Secret. [External]
    names a store and a remote path, which a delivery controller resolves. [Target_kafka]
    names the Secret the deploy writes from the target's resolved Kafka authority, so it is
    resource-owned and not an application secret. *)
type t =
  | Sol_managed
  | Provider of { secret : Sol_cli_provider_secret.t }
  | External of
      { store : string
      ; key : string
      }
  | Target_kafka of { secret : string }

(** Which access class a consumer receives. Derived from the consumer's role — a migration Job
    is [Ddl], a workload is [Dml] — and never declared by the user (ADR 0007).

    [Provisioning] is the administrative credential: the provisioning path holds it, and it is
    never delivered to a consumer. *)
type credential_class =
  | Provisioning
  | Ddl
  | Dml
