(** Independent, offline Kubernetes read boundary. No Sol renderer or executor. *)
type resource =
  | Deployment
  | Configmap

type query = private
  { resource : resource
  ; namespace : string
  ; name : string
  ; requirement : string
  ; subject : string
  ; target : Qual_domain.kube_target
  }

(** The reader executes an exact namespaced read, or a native typed list restricted
    by metadata.name. It supplies observed context/timing, not just requested role.
    I3 injects fixture readers; no live/process transport is installed. *)
type command_result =
  | Exited of
      { code : int
      ; stdout : string
      ; stderr : string
      }
  | Timed_out of string
  | Signaled of int * string
  | Spawn_failed of string

type reply =
  { context : Qual_domain.read_context
  ; result : command_result
  }

type observation =
  | Deployment_read of Qual_domain.deployment Qual_domain.kube_read
  | Configmap_read of Qual_domain.ca_configmap Qual_domain.kube_read

val queries : Qual_domain.ca_requirement -> query * query
val classify : query -> reply -> observation

(** Safe projections omit certificate values, arbitrary env/annotations and raw
    stdout. Only these projections, including safe underlying error diagnostics,
    enter the evidence recorder. Decoding never evaluates the CA predicate. *)
val encode : observation -> Yojson.Safe.t

val decode : Qual_evidence.captured -> (observation, string) result
