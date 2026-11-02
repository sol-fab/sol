(** Move existing Kubernetes-authoritative application values to provider authority.

    The provider store becomes the only authority; a Kubernetes Secret is not mirrored
    from it. Existing values therefore need a one-way, resumable adoption:

    - provider absent, Kubernetes present -> write the existing value to the provider,
      then remove the Kubernetes key;
    - provider present, Kubernetes equal -> remove the Kubernetes key (this is also the
      recovery path after an interrupted adoption);
    - provider present, Kubernetes different -> the provider is the declared authority, so
      the Kubernetes copy is retired with a warning. This is the rotation-after-migration
      path: `sol secret set` writes the provider while an older Kubernetes copy may still
      exist.

    Every step is ordered so an interruption is recoverable rather than lossy. The provider
    write happens first, so the value exists in the durable authority before the only other
    copy is deleted. The Kubernetes delete is last and is repeated on the next deploy if it
    did not complete.

    This runs before the deploy provider precondition and before any manifest that
    references the value is applied. A unit with no legacy Secret is a no-op: a fresh target
    is served entirely from `sol secret set`. *)

open Result.Syntax

let namespace_and_secret_name (spec : Sol_cli_deployment_plan.service_spec) =
  ( Sol_cli_deployment_plan.namespace_to_string spec.namespace
  , Sol_cli_manifest.workload_secret_name
      (Sol_cli_deployment_plan.k8s_name_to_string spec.k8s_name) )
;;

(** What the two observed copies require. This is the resumable migration decision,
    separated from the effects so every state can be tested without a provider. *)
type decision =
  | Nothing
  | Adopt of string
  | Retire
  | Retire_differing

let decide ~provider_value ~legacy_value =
  match provider_value, legacy_value with
  | None, None -> Nothing
  | Some _, None -> Nothing
  | Some provider_value, Some legacy_value ->
    if String.equal provider_value legacy_value then Retire else Retire_differing
  | None, Some legacy_value -> Adopt legacy_value
;;

let reconcile_key ~ctx ~namespace ~secret_name ~key ~secret =
  let* () =
    match Sol_cli_secret_authority.observe secret with
    | Ok Sol_cli_secret_authority.Owned -> Ok ()
    | Ok Sol_cli_secret_authority.Missing ->
      (* The provider authority does not exist yet. The legacy read below decides whether
         this is a migration or a genuinely unset key; an unset key is not an error here,
         because the deploy precondition reports it with the instruction that sets it. *)
      Ok ()
    | Ok (Sol_cli_secret_authority.Pending_deletion date) ->
      Error
        (Printf.sprintf
           "the provider authority for %s is pending deletion (%s); its absence is not \
            established, so its value cannot be migrated"
           key
           date)
    | Ok (Sol_cli_secret_authority.Unowned reason) ->
      Error
        (Printf.sprintf
           "the provider secret named for %s is not Sol's (%s); refusing to migrate or \
            overwrite it"
           key
           reason)
    | Error message -> Error message
  in
  let* provider_value = Sol_cli_secret_authority.read secret in
  let* legacy_value = Sol_cli_secret.read_owned_key ~ctx ~namespace ~secret_name ~key in
  match decide ~provider_value ~legacy_value with
  | Nothing -> Ok ()
  | Retire ->
    let* _ = Sol_cli_secret.delete_unit_key ~ctx ~namespace ~secret_name ~key in
    Ok ()
  | Retire_differing ->
    (* The provider is the declared authority. A Kubernetes value that disagrees is a
       second writer from before the migration (or an unsupported direct edit); it is not
       a competing authority. Report the retirement rather than silently discarding it. *)
    Sol_cli_report.warn
      "%s/%s: the unit's Kubernetes Secret held a different value than the provider \
       authority. The provider value is authoritative; the Kubernetes copy is being \
       removed."
      namespace
      key;
    let* _ = Sol_cli_secret.delete_unit_key ~ctx ~namespace ~secret_name ~key in
    Ok ()
  | Adopt legacy_value ->
    (* Write first: after this point the durable authority holds the value, and an
       interruption leaves a duplicate rather than a loss. *)
    let* () = Sol_cli_secret_authority.write secret ~value:legacy_value in
    let* _ = Sol_cli_secret.delete_unit_key ~ctx ~namespace ~secret_name ~key in
    Ok ()
;;

(** The provider-backed keys of one unit. *)
let reconcile_spec ~ctx (spec : Sol_cli_deployment_plan.service_spec) =
  let namespace, secret_name = namespace_and_secret_name spec in
  spec.secret_sources
  |> List.filter_map (fun (key, source) ->
    match source with
    | Sol_cli_manifest.Provider { secret } -> Some (key, secret)
    | Sol_managed | External _ | Target_kafka _ -> None)
  |> Sol_cli_result.map_list (fun (key, secret) ->
    reconcile_key ~ctx ~namespace ~secret_name ~key ~secret)
  |> Result.map ignore
;;
