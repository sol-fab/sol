type builder =
  { label : string
  ; identifying_resources : string list
  ; build : string -> (Sol_cli_cluster.t, string) result
  }

let substrate_addresses = function
  | Sol_cli_provider.Aws -> [ "module.eks.aws_eks_cluster" ]
  | Sol_cli_provider.Gcp -> [ "google_container_cluster.main" ]
  | Sol_cli_provider.Byo -> []
;;

(* The Terraform type of the substrate resource. State selection must require both the
   address prefix and this type, so a similarly-prefixed object cannot be read as the
   cluster whose identity scopes a destructive decision. *)
let substrate_kind = function
  | Sol_cli_provider.Aws -> "aws_eks_cluster"
  | Sol_cli_provider.Gcp -> "google_container_cluster"
  | Sol_cli_provider.Byo -> ""
;;

let byo_no_root =
  "the byo driver owns no cloud Terraform root: it is bring-your-own infrastructure, so \
   Sol has no provider lifecycle to run for it (DEC-051)"
;;

let builder provider ~(target : Sol_cli_config.target) =
  let region = target.region in
  let of_json of_outputs_json cluster text = Result.map cluster (of_outputs_json text) in
  match provider with
  | Sol_cli_provider.Aws ->
    { label = Sol_cli_aws_cluster.label
    ; identifying_resources = substrate_addresses provider
    ; build =
        of_json
          Sol_cli_aws_cluster.of_outputs_json
          (Sol_cli_aws_cluster.cluster
             ~region
             ~provisioner_role_arn:
               (Sol_cli_config.provider_field target "provisioner_role_arn")
             ~deploy_role_arn:(Sol_cli_config.provider_field target "deploy_role_arn"))
    }
  | Sol_cli_provider.Gcp ->
    { label = Sol_cli_gcp_cluster.label
    ; identifying_resources = substrate_addresses provider
    ; build =
        of_json Sol_cli_gcp_cluster.of_outputs_json (Sol_cli_gcp_cluster.cluster ~region)
    }
  | Sol_cli_provider.Byo ->
    { label = "byo"; identifying_resources = []; build = (fun _ -> Error byo_no_root) }
;;

type resolution_failure =
  | Outputs_unreadable of string
  | State_unreadable of string
  | No_root of string

let resolution_failure_to_string = function
  | Outputs_unreadable message | State_unreadable message | No_root message -> message
;;

let state_holds_any ~chdir prefixes =
  match Sol_cli_terraform.state_addresses ~chdir () with
  | Ok addresses ->
    Ok
      (List.exists
         (fun address ->
            List.exists (fun prefix -> String.starts_with ~prefix address) prefixes)
         addresses)
  | Error (Sol_cli_process.Non_zero result) ->
    Error
      (State_unreadable
         (Printf.sprintf
            "terraform state list failed with exit %d%s"
            result.exit_code
            (let detail = String.trim result.stderr in
             if detail = "" then "" else ": " ^ detail)))
  | Error error ->
    Error
      (State_unreadable
         ("could not read the Terraform state listing: "
          ^ Sol_cli_process.error_to_string error))
;;

let of_root provider ~target ~chdir =
  match provider with
  | Sol_cli_provider.Byo -> Error (No_root byo_no_root)
  | Sol_cli_provider.Aws | Sol_cli_provider.Gcp ->
    let { label; identifying_resources; build } = builder provider ~target in
    let cluster_of_outputs text = Result.map Option.some (build text) in
    (match Sol_cli_terraform.output_json ~chdir () with
     | Ok result ->
       (match Yojson.Safe.from_string result.stdout with
        | `Assoc _ ->
          (match state_holds_any ~chdir identifying_resources with
           | Error failure -> Error failure
           | Ok false -> Ok None
           | Ok true ->
             cluster_of_outputs result.stdout
             |> Result.map_error (fun message -> Outputs_unreadable message))
        | _ ->
          cluster_of_outputs result.stdout
          |> Result.map_error (fun message -> Outputs_unreadable message)
        | exception Yojson.Json_error message ->
          Error
            (Outputs_unreadable
               (Printf.sprintf "invalid %s Terraform output JSON: %s" label message)))
     | Error (Sol_cli_process.Non_zero result) ->
       Error
         (Outputs_unreadable
            (Printf.sprintf
               "terraform output failed with exit %d%s"
               result.exit_code
               (let detail = String.trim result.stderr in
                if detail = "" then "" else ": " ^ detail)))
     | Error e ->
       Error
         (Outputs_unreadable
            (Printf.sprintf
               "could not read %s Terraform outputs: %s"
               label
               (Sol_cli_process.error_to_string e))))
;;

(** The provisioning configuration's [postgres_url], read through the same provider reader
    that builds the cluster. It is separate from {!of_root} because the cluster value
    projection drops fields a consumer does not need, and the database setup step needs
    exactly this one; parsing it here keeps the provider dispatch out of the deploy command
    and the [postgres_url] contract in one place per provider.

    [None] means the output is null — the root created no database (it is conditional on
    [has_postgres]). An unreadable output is an error, not [None]: those are different
    outcomes and the caller fails closed on both, but only one of them means "no database". *)
let postgres_url_of_outputs provider text =
  match provider with
  | Sol_cli_provider.Byo -> Error (No_root byo_no_root)
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_cluster.of_outputs_json text
    |> Result.map (fun (outputs : Sol_cli_aws_cluster.aws_outputs) ->
      outputs.postgres_url)
    |> Result.map_error (fun message -> Outputs_unreadable message)
  | Sol_cli_provider.Gcp ->
    Sol_cli_gcp_cluster.of_outputs_json text
    |> Result.map (fun (outputs : Sol_cli_gcp_cluster.gcp_outputs) ->
      outputs.postgres_url)
    |> Result.map_error (fun message -> Outputs_unreadable message)
;;

(** The same provider dispatch for {!postgres_ca_cert}: the trust anchor the provider's
    {!postgres_sslmode} verifies against, whose shape differs by provider (AWS a committed bundle, GCP the instance's server
    CA). Kept beside {!postgres_url_of_outputs} and separate from {!of_root} for the same
    reason: one contract per provider, in one place. *)
let postgres_ca_cert_of_outputs provider text =
  match provider with
  | Sol_cli_provider.Byo -> Error (No_root byo_no_root)
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_cluster.of_outputs_json text
    |> Result.map (fun (outputs : Sol_cli_aws_cluster.aws_outputs) ->
      outputs.postgres_ca_cert)
    |> Result.map_error (fun message -> Outputs_unreadable message)
  | Sol_cli_provider.Gcp ->
    Sol_cli_gcp_cluster.of_outputs_json text
    |> Result.map (fun (outputs : Sol_cli_gcp_cluster.gcp_outputs) ->
      outputs.postgres_ca_cert)
    |> Result.map_error (fun message -> Outputs_unreadable message)
;;

(** The TLS mode this provider's database connection uses.

    The contract is **encrypted transport with authenticated server identity**, and each
    provider satisfies it by its own mechanism. AWS verifies the host against a pinned RDS CA
    with a committed bundle — [verify-full]. GCP's connection is a private IP inside the VPC
    with no name to match, and its trust anchor is the *per-instance* CA, which the instance
    alone holds: the identity is established by the CA, so [verify-ca] is the mechanism that
    expresses it. Both are explicit modes; neither permits opportunistic encryption or a
    downgrade, and [verify-full] is stronger than GCP's case requires rather than the
    property itself.

    Declared here, beside {!postgres_url_of_outputs} and {!postgres_ca_cert_of_outputs},
    because it is the same kind of fact: what this provider's connection contract is. It is
    never a user-facing field — a target does not choose its mode, its provider has one — and
    it travels to consumers in the delivered URL, so no client hardcodes either value. *)
let postgres_sslmode provider =
  match provider with
  | Sol_cli_provider.Byo -> Error (No_root byo_no_root)
  | Sol_cli_provider.Aws -> Ok "verify-full"
  | Sol_cli_provider.Gcp -> Ok "verify-ca"
;;

let destruction provider context =
  match provider with
  | Sol_cli_provider.Aws -> Sol_cli_aws_destruction.destruction context
  | Sol_cli_provider.Gcp -> Sol_cli_gcp_destruction.destruction context
  | Sol_cli_provider.Byo ->
    { Sol_cli_destruction.prepare =
        (fun ~retention:_ ~cluster_name:_ ~state:_ ->
          Sol_cli_cloud_lifecycle.Nothing_to_prepare)
    ; retention =
        (fun ~retention:_ ~pre_destroy:_ ~preparation:_ ->
          Sol_cli_destroy_verification.Retention_not_required byo_no_root)
    ; residue =
        (fun
          ?previously_attributed:_
          ?authorization_identities:_
          ~pre_destroy:_
          ~cluster:_
          ()
         ->
          [])
    ; before_substrate_destroy = (fun () -> ())
    }
;;

let observations
      ?(previously_attributed = [])
      ?(pre_destroy = Sol_cli_cloud_destroy.State_empty)
      ?(authorization_identities = [])
      provider
      target
      ~cluster_name
  =
  match provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_absence.observations
      ~previously_attributed
      ~pre_destroy
      ~authorization_identities
      target
      ~cluster_name
  | Sol_cli_provider.Gcp ->
    Sol_cli_gcp_absence.observations
      ~previously_attributed
      ~authorization_identities
      target
      ~cluster_name
  | Sol_cli_provider.Byo -> []
;;

let substrate_absence provider target ~cluster_name =
  match provider with
  | Sol_cli_provider.Aws -> Sol_cli_aws_absence.substrate_absence target ~cluster_name
  | Sol_cli_provider.Gcp -> Sol_cli_gcp_absence.substrate_absence target ~cluster_name
  | Sol_cli_provider.Byo ->
    Sol_cli_absence.Unobservable
      { resource_class = "the substrate"
      ; reason = byo_no_root
      ; checked_with = "(not run: the byo driver owns no provider root)"
      }
;;

let resource_identity provider ~cluster_name ~project_id =
  match provider with
  | Sol_cli_provider.Aws -> Sol_cli_resource_identity.aws ~cluster_name
  | Sol_cli_provider.Gcp -> Sol_cli_resource_identity.gcp ~cluster_name ~project_id
  | Sol_cli_provider.Byo -> []
;;

let credentials provider ~operation ~leaves_target_standing =
  match provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_cluster.credentials ~operation ~leaves_target_standing
  | Sol_cli_provider.Gcp ->
    Sol_cli_gcp_cluster.credentials ~operation ~leaves_target_standing
  | Sol_cli_provider.Byo -> Error byo_no_root
;;

let authorization_state_identities provider ~target state =
  match provider with
  | Sol_cli_provider.Aws ->
    Sol_cli_aws_absence.authorization_state_identities ~target state
  | Sol_cli_provider.Gcp ->
    Sol_cli_gcp_absence.authorization_state_identities ~target state
  | Sol_cli_provider.Byo -> []
;;
