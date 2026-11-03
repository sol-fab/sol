(** Provider operations for Sol-managed secret authority.

    The authority is the provider store, not Kubernetes. This module is the only place
    that speaks to AWS Secrets Manager and GCP Secret Manager, so every caller shares the
    same ownership rule, the same no-value-on-argv rule, and the same redaction.

    Values travel through a private 0600 temporary file (the provider CLIs accept a file
    argument) and are never placed on a command line, in an error message, or in a log.
*)

open Result.Syntax

type observation =
  | Missing
  | Owned
  | Pending_deletion of string
  | Unowned of string

let run ?(redact = []) argv =
  Sol_cli_process.run (Sol_cli_process.cmd ~redact argv)
  |> Result.map_error (fun error ->
    Sol_cli_process.error_to_string error |> Sol_cli_process.apply_redactions redact)
;;

let provider_name secret = Sol_cli_provider_secret.reference secret

let aws_args secret args =
  [ Sol_cli_provider.to_string Sol_cli_provider.Aws ]
  @ args
  @ [ "--region"; Option.value secret.Sol_cli_provider_secret.region ~default:"" ]
;;

let gcp_args secret args =
  [ "gcloud" ]
  @ args
  @ [ "--project"; Option.value secret.Sol_cli_provider_secret.project ~default:"" ]
;;

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let json_string_field name json =
  match json_field name json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let tags_of_aws json =
  match json_field "Tags" json with
  | Some (`List tags) ->
    List.filter_map
      (function
        | `Assoc fields ->
          (match List.assoc_opt "Key" fields, List.assoc_opt "Value" fields with
           | Some (`String key), Some (`String value) -> Some (key, value)
           | _ -> None)
        | _ -> None)
      tags
  | _ -> []
;;

let labels_of_gcp json =
  match json_field "labels" json with
  | Some (`Assoc labels) ->
    List.filter_map
      (function
        | key, `String value -> Some (key, value)
        | _ -> None)
      labels
  | _ -> []
;;

(* The ownership predicate is one predicate: every label both providers carry must say
   Sol owns this authority for this environment. A same-named secret without the metadata
   is refused rather than adopted, and a secret whose metadata names another environment
   is refused even if it says "sol". *)
let ownership_mismatch secret labels =
  let expected = Sol_cli_provider_secret.ownership_labels secret in
  List.find_opt (fun (key, value) -> List.assoc_opt key labels <> Some value) expected
;;

let observation_of_json secret json =
  match json_string_field "DeletedDate" json with
  | Some date -> Pending_deletion date
  | None ->
    let labels =
      match secret.Sol_cli_provider_secret.provider with
      | Sol_cli_provider_secret.Aws -> tags_of_aws json
      | Sol_cli_provider_secret.Gcp -> labels_of_gcp json
    in
    (match ownership_mismatch secret labels with
     | Some (key, value) ->
       Unowned (Printf.sprintf "its %s label/tag is not %S" key value)
     | None -> Owned)
;;

let aws_describe secret =
  run
    (aws_args secret [ "secretsmanager"; "describe-secret"; "--secret-id"; secret.name ])
;;

let gcp_describe secret =
  run (gcp_args secret [ "secrets"; "describe"; secret.name; "--format"; "json" ])
;;

let observe secret =
  match secret.Sol_cli_provider_secret.provider with
  | Sol_cli_provider_secret.Aws ->
    (match aws_describe secret with
     | Ok output ->
       let* json =
         Sol_cli_json.decode ~what:"AWS secret description" output.Sol_cli_process.stdout
       in
       Ok (observation_of_json secret json)
     | Error message ->
       (match Sol_cli_aws.error_code message with
        | Some "ResourceNotFoundException" -> Ok Missing
        | _ ->
          Error
            (Printf.sprintf
               "could not observe AWS secret %s: %s"
               (provider_name secret)
               message)))
  | Sol_cli_provider_secret.Gcp ->
    (match gcp_describe secret with
     | Ok output ->
       let* json =
         Sol_cli_json.decode ~what:"GCP secret description" output.Sol_cli_process.stdout
       in
       Ok (observation_of_json secret json)
     | Error message ->
       if Sol_cli_gcloud.says_not_found ?project:secret.project message
       then Ok Missing
       else
         Error
           (Printf.sprintf
              "could not observe GCP secret %s: %s"
              (provider_name secret)
              message))
;;

let create secret =
  let labels = Sol_cli_provider_secret.ownership_labels secret in
  let already_exists message =
    Sol_cli_string.contains ~needle:"ALREADY_EXISTS" message
    || Sol_cli_string.contains ~needle:"already exists" message
  in
  match secret.Sol_cli_provider_secret.provider with
  | Sol_cli_provider_secret.Aws ->
    let tags =
      List.concat_map
        (fun (key, value) -> [ "--tags"; "Key=" ^ key ^ ",Value=" ^ value ])
        labels
    in
    (match
       run
         (aws_args
            secret
            ([ "secretsmanager"; "create-secret"; "--name"; secret.name ] @ tags))
     with
     | Ok _ -> Ok ()
     | Error message ->
       (match Sol_cli_aws.error_code message with
        (* A concurrent creator won the race. [ensure] re-observes and applies the same
           ownership predicate, so this is neither a failure nor an adoption. *)
        | Some "ResourceExistsException" -> Ok ()
        | _ ->
          Error
            (Printf.sprintf
               "could not create AWS secret %s: %s"
               (provider_name secret)
               message)))
  | Sol_cli_provider_secret.Gcp ->
    let labels_arg =
      String.concat "," (List.map (fun (key, value) -> key ^ "=" ^ value) labels)
    in
    (match
       run
         (gcp_args
            secret
            [ "secrets"
            ; "create"
            ; secret.name
            ; "--replication-policy=automatic"
            ; "--labels=" ^ labels_arg
            ])
     with
     | Ok _ -> Ok ()
     | Error message ->
       if already_exists message
       then Ok ()
       else
         Error
           (Printf.sprintf
              "could not create GCP secret %s: %s"
              (provider_name secret)
              message))
;;

(** Create the container when absent and verify Sol owns it when present. An authority
    pending provider deletion is not "absent": recreating it would adopt a name whose
    previous value may still be readable or recoverable. *)
let ensure secret =
  match observe secret with
  | Error _ as error -> error
  | Ok Owned -> Ok ()
  | Ok (Pending_deletion date) ->
    Error
      (Printf.sprintf
         "authority %s is scheduled for provider deletion (%s); recreate it only after \
          the deletion has completed and its absence is established"
         (provider_name secret)
         date)
  | Ok (Unowned reason) ->
    Error
      (Printf.sprintf
         "refusing to use %s as Sol secret authority: %s. A same-named secret is not \
          evidence of Sol ownership."
         (provider_name secret)
         reason)
  | Ok Missing ->
    Result.bind (create secret) (fun () ->
      match observe secret with
      | Ok Owned -> Ok ()
      | Ok _ ->
        Error
          (Printf.sprintf
             "created %s but could not observe Sol ownership afterwards"
             (provider_name secret))
      | Error message -> Error message)
;;

let read secret =
  match secret.Sol_cli_provider_secret.provider with
  | Sol_cli_provider_secret.Aws ->
    (match
       run
         (aws_args
            secret
            [ "secretsmanager"
            ; "get-secret-value"
            ; "--secret-id"
            ; secret.name
            ; "--output"
            ; "json"
            ])
     with
     | Ok output ->
       let* json =
         (* The response carries the value; a parse diagnostic must not quote it. *)
         Sol_cli_json.decode_sensitive
           ~what:"AWS secret value"
           output.Sol_cli_process.stdout
       in
       (match json_field "SecretString" json with
        | Some (`String value) -> Ok (Some value)
        | Some _ | None ->
          Error
            (Printf.sprintf
               "AWS secret %s has no SecretString; key/value or binary secrets are \
                not                 supported authority"
               (provider_name secret)))
     | Error message ->
       (match Sol_cli_aws.error_code message with
        | Some "ResourceNotFoundException" -> Ok None
        | _ ->
          Error
            (Printf.sprintf
               "could not read AWS secret %s: %s"
               (provider_name secret)
               message)))
  | Sol_cli_provider_secret.Gcp ->
    (match
       gcp_args
         secret
         [ "secrets"; "versions"; "access"; "latest"; "--secret"; secret.name ]
       |> run
     with
     | Ok output -> Ok (Some output.Sol_cli_process.stdout)
     | Error message ->
       if
         Sol_cli_gcloud.says_not_found ?project:secret.project message
         || Sol_cli_string.contains ~needle:"NOT_FOUND" message
       then Ok None
       else
         Error
           (Printf.sprintf
              "could not read GCP secret %s: %s"
              (provider_name secret)
              message))
;;

(** A new provider version. AWS and GCP both keep the previous version addressable according
    to their own retention rules, which is what makes an interrupted rotation recoverable.
    The value is written to a 0600 file and handed to the provider CLI by path. *)
let write secret ~value =
  let* () = ensure secret in
  let redact = [ value ] in
  (* [with_temp_file] creates the file 0600 and removes it on return. *)
  Sol_cli_fs.with_temp_file ~prefix:"sol-secret-value-" ~suffix:".txt" value (fun path ->
    match secret.Sol_cli_provider_secret.provider with
    | Sol_cli_provider_secret.Aws ->
      run
        ~redact
        (aws_args
           secret
           [ "secretsmanager"
           ; "put-secret-value"
           ; "--secret-id"
           ; secret.name
           ; "--secret-string"
           ; "file://" ^ path
           ])
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun message ->
        Printf.sprintf "could not write AWS secret %s: %s" (provider_name secret) message)
    | Sol_cli_provider_secret.Gcp ->
      run
        ~redact
        (gcp_args
           secret
           [ "secrets"; "versions"; "add"; secret.name; "--data-file=" ^ path ])
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun message ->
        Printf.sprintf "could not write GCP secret %s: %s" (provider_name secret) message))
  |> Result.join
;;

(** Explicit deletion. This is the operator's `sol secret delete`, not an ordinary deploy:
    a target teardown has its own inventory. The provider's asynchronous deletion is a
    request, not absence; callers must not report the two as the same. *)
let delete_result result =
  match result with
  | Ok present -> Ok present
  | Error "absent" -> Ok false
  | Error message -> Error message
;;

let delete_named ~provider ~name ~region ~project =
  let secret : Sol_cli_provider_secret.t =
    { provider
    ; environment = ""
    ; target = ""
    ; name
    ; project
    ; region
    ; identity = name
    ; kind = Sol_cli_provider_secret.Application
    ; resource_name = name
    }
  in
  delete_result
  @@
  match provider with
  | Sol_cli_provider_secret.Aws ->
    run
      (aws_args
         secret
         [ "secretsmanager"
         ; "delete-secret"
         ; "--secret-id"
         ; name
         ; "--force-delete-without-recovery"
         ])
    |> Result.map (fun _ -> true)
    |> Result.map_error (fun message ->
      match Sol_cli_aws.error_code message with
      | Some "ResourceNotFoundException" -> "absent"
      | _ ->
        Printf.sprintf "could not delete AWS secret %s: %s" (provider_name secret) message)
  | Sol_cli_provider_secret.Gcp ->
    run (gcp_args secret [ "secrets"; "delete"; name; "--quiet" ])
    |> Result.map (fun _ -> true)
    |> Result.map_error (fun message ->
      if Sol_cli_gcloud.says_not_found ?project:secret.project message
      then "absent"
      else
        Printf.sprintf "could not delete GCP secret %s: %s" (provider_name secret) message)
;;

let delete secret =
  delete_named
    ~provider:secret.Sol_cli_provider_secret.provider
    ~name:secret.name
    ~region:secret.region
    ~project:secret.project
;;

(** Whether the container exists and Sol owns it. This is the deploy precondition: an
    absent or unowned authority fails closed instead of letting a workload start without
    the value it declared. *)
let verify_present secret =
  match observe secret with
  | Error _ as error -> error
  | Ok Owned -> Ok ()
  | Ok Missing ->
    Error
      (Printf.sprintf
         "the provider secret authority for %s does not exist. Set it with `sol secret \
          set`; Sol will not generate a replacement."
         (provider_name secret))
  | Ok (Pending_deletion date) ->
    Error
      (Printf.sprintf
         "the provider secret authority for %s is pending deletion (%s); restore it \
          before deploying"
         (provider_name secret)
         date)
  | Ok (Unowned reason) ->
    Error
      (Printf.sprintf
         "the provider secret authority for %s is not Sol's (%s); refusing to use it"
         (provider_name secret)
         reason)
;;

(** The target's provider scope, or [None] when the target does not have a managed
    provider secret store (a local shape, or a provider with no implemented authority). *)
let scope_of_target (target : Sol_cli_config.target) =
  let project = Sol_cli_config.provider_field target "project_id" in
  let scope_target = Sol_cli_kubernetes_name.sanitize_name target.name in
  match target.provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_provider_secret.scope
      ~provider:Sol_cli_provider_secret.Aws
      ~environment:target.env
      ~target:scope_target
      ~project:None
      ~region:(Some target.region)
  | Sol_cli_provider.Gcp ->
    Sol_cli_provider_secret.scope
      ~provider:Sol_cli_provider_secret.Gcp
      ~environment:target.env
      ~target:scope_target
      ~project
      ~region:None
  | Sol_cli_provider.Byo ->
    Error
      (Printf.sprintf
         "target %s is externally managed and has no Sol provider secret authority"
         target.name)
;;

(** Whether this target's ordinary Sol-managed application values live in the provider
    store. The platform shape is the decision: a deliberate [local] target keeps the
    Kubernetes-Secret workflow, and a durable managed target does not. *)
let provider_backed_target (target : Sol_cli_config.target) =
  match target.shape with
  | Some Sol_cli_profile.Durable ->
    (match target.provider with
     | Sol_cli_provider.Aws | Gcp -> true
     | Sol_cli_provider.Byo -> false)
  | Some Sol_cli_profile.Local | None -> false
;;

let provider_backed (config : Sol_cli_config.t) = provider_backed_target config.target

let split_unit_address address =
  match String.split_on_char '/' address with
  | [ domain; unit ] -> Ok (domain, unit)
  | _ -> Error (Printf.sprintf "secret unit %S is not a domain/unit address" address)
;;

let application_of_target ~(target : Sol_cli_config.target) ~domain ~unit ~key =
  let* scope = scope_of_target target in
  (* Names are provider resources, so the unit uses the one Kubernetes spelling every
     other provider object derives from the declaration. A source name and a k8s name
     are the same address in two spellings, not two authorities. *)
  let* unit =
    Sol_cli_kubernetes_name.k8s_name_of_source unit
    |> Result.map Sol_cli_kubernetes_name.k8s_name_to_string
    |> Result.map_error (fun message ->
      Printf.sprintf "unit %S has no provider-safe name: %s" unit message)
  in
  Sol_cli_provider_secret.application ~scope ~domain ~unit ~key
;;

let application ~(config : Sol_cli_config.t) ~unit_address ~key =
  let* domain, unit = split_unit_address unit_address in
  application_of_target ~target:config.target ~domain ~unit ~key
;;

let database ~(config : Sol_cli_config.t) ~part =
  let* scope = scope_of_target config.target in
  Sol_cli_provider_secret.database ~scope ~part
;;

(** The deploy precondition for one provider-backed key: the container is Sol's and the
    current version is readable and non-empty. A secret whose authority is temporarily
    unavailable fails the deploy closed rather than starting a workload that will fail at
    mount time. The value itself is never reported. *)
let verify_has_value secret =
  let* () = verify_present secret in
  match read secret with
  | Error _ as error -> error
  | Ok (Some value) when not (Sol_cli_string.is_blank value) -> Ok ()
  | Ok _ ->
    Error
      (Printf.sprintf
         "the provider secret authority for %s has no readable version. Set it with `sol \
          secret set`; Sol will not generate a replacement."
         (provider_name secret))
;;

let observation_to_string = function
  | Missing -> "missing"
  | Owned -> "present"
  | Pending_deletion date -> "pending provider deletion (" ^ date ^ ")"
  | Unowned reason -> "not Sol-owned (" ^ reason ^ ")"
;;

(** The authority containers Sol owns for a target environment. Kubernetes objects are
    removed by the release/ownership path; provider secrets live outside it, so destroy
    must enumerate the provider store rather than reconstruct the declared set (a removed
    unit can still have an authority). Only application authority is listed here: database
    authority is removed by its own lifecycle. *)
type inventory_entry =
  { entry_name : string
  ; entry_provider : Sol_cli_provider_secret.provider
  }

let aws_inventory ~environment ~target json =
  let entries =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "SecretList" fields with
       | Some (`List entries) -> entries
       | _ -> [])
    | _ -> []
  in
  entries
  |> List.filter_map (fun entry ->
    let tags = tags_of_aws entry in
    match
      ( List.assoc_opt "sol-environment" tags
      , List.assoc_opt "sol-target" tags
      , List.assoc_opt "sol-authority" tags
      , json_string_field "Name" entry )
    with
    | Some found, Some found_target, Some authority, Some name
      when String.equal found environment
           && String.equal found_target target
           && (String.equal authority "application" || String.equal authority "database")
      -> Some { entry_name = name; entry_provider = Sol_cli_provider_secret.Aws }
    | _ -> None)
;;

let gcp_inventory json =
  let entries =
    match json with
    | `List entries -> entries
    | _ -> []
  in
  entries
  |> List.filter_map (function
    | `Assoc fields ->
      (match json_string_field "name" (`Assoc fields) with
       | Some name ->
         let short =
           match String.rindex_opt name '/' with
           | Some index -> String.sub name (index + 1) (String.length name - index - 1)
           | None -> name
         in
         Some { entry_name = short; entry_provider = Sol_cli_provider_secret.Gcp }
       | None -> None)
    | _ -> None)
;;

let list_authorities (target : Sol_cli_config.target) =
  let* scope = scope_of_target target in
  match scope.provider with
  | Sol_cli_provider_secret.Aws ->
    let region = Option.value scope.region ~default:"" in
    (match
       run
         [ Sol_cli_provider.to_string Sol_cli_provider.Aws
         ; "secretsmanager"
         ; "list-secrets"
         ; "--region"
         ; region
         ; "--filters"
         ; "Key=tag-key,Values=sol-managed-by"
         ; "Key=tag-value,Values=sol"
         ; "--output"
         ; "json"
         ]
     with
     | Error message -> Error ("could not list AWS secret authorities: " ^ message)
     | Ok output ->
       let* json =
         Sol_cli_json.decode ~what:"AWS secret inventory" output.Sol_cli_process.stdout
       in
       Ok (aws_inventory ~environment:scope.environment ~target:scope.target json))
  | Sol_cli_provider_secret.Gcp ->
    let project = Option.value scope.project ~default:"" in
    let filter =
      Printf.sprintf
        "labels.sol-managed-by=sol AND labels.sol-environment=%s AND          \
         labels.sol-authority=application"
        scope.environment
    in
    (match
       run
         [ "gcloud"
         ; "secrets"
         ; "list"
         ; "--project"
         ; project
         ; "--filter"
         ; filter
         ; "--format"
         ; "json"
         ]
     with
     | Error message -> Error ("could not list GCP secret authorities: " ^ message)
     | Ok output ->
       let* json =
         Sol_cli_json.decode ~what:"GCP secret inventory" output.Sol_cli_process.stdout
       in
       Ok (gcp_inventory json))
;;

(** Delete every authority this target owns -- application values and the database
    password record -- and establish that the provider store no longer lists one. The list
    is the evidence: a successful delete call is a request, not absence. *)
let destroy_authorities ~(target : Sol_cli_config.target) =
  if not (provider_backed_target target)
  then Ok ()
  else
    let* scope = scope_of_target target in
    let* entries = list_authorities target in
    let* () =
      entries
      |> Sol_cli_result.map_list (fun (entry : inventory_entry) ->
        let* deleted =
          delete_named
            ~provider:entry.entry_provider
            ~name:entry.entry_name
            ~region:scope.region
            ~project:scope.project
        in
        if deleted
        then Ok ()
        else
          Error
            (Printf.sprintf
               "the provider reported %s absent while the inventory still listed it"
               entry.entry_name))
      |> Result.map ignore
    in
    let* remaining = list_authorities target in
    match remaining with
    | [] -> Ok ()
    | entries ->
      Error
        (Printf.sprintf
           "provider secret authorities still exist after destroy: %s"
           (String.concat ", " (List.map (fun e -> e.entry_name) entries)))
;;
