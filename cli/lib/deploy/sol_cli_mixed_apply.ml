(** The component order for a mixed-target apply.

    The serverless component is applied first. A Kubernetes failure after that leaves
    the serverless component applied; this module returns that fact explicitly rather
    than implying a rollback or atomicity. Both components are called exactly once. *)

type 'error outcome =
  | Complete
  | Failed_serverless of 'error
  | Partial of 'error

let run ~apply_serverless ~apply_kubernetes =
  match apply_serverless () with
  | Error error -> Failed_serverless error
  | Ok () ->
    (match apply_kubernetes () with
     | Ok () -> Complete
     | Error error -> Partial error)
;;
