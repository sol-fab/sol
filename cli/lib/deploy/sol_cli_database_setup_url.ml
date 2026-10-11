(** The DDL and DML connection URLs, derived from the master connection the provisioning
    layer reports.

    **Query parameters are preserved, deliberately.** 2d adds
    [sslmode=...&sslrootcert=...] to the master URL, and every consumer has to
    carry the same parameters, so this parses and rebuilds rather than replacing text: a
    string substitution of user and password would drop the query string, and 2d would
    break silently rather than loudly.

    **The credentials are substituted unencoded, because the generator is hex**
    ({!Sol_cli_database_setup_password}). [0-9a-f] needs no escaping in userinfo. If that
    generator is ever changed — base64 was considered and rejected partly for this reason —
    this substitution must gain percent-encoding at the same time. *)

let with_credentials ~user ~password url =
  let uri = Uri.of_string url in
  Uri.with_userinfo uri (Some (user ^ ":" ^ password)) |> Uri.to_string
;;

(** Add the parameters every consumer carries once TLS is required: the provider's mode
    ([sslmode]) and the anchor it verifies against ([sslrootcert], mounted at
    [ca_cert_path]).

    **The mode is an argument, not a constant.** The contract — encrypted transport with
    authenticated server identity — is provider-neutral; the mechanism is not. AWS verifies
    the host against its pinned CA, GCP establishes identity with the instance's own CA over
    a private address. Both are explicit modes, so nothing here is opportunistic and nothing
    can be downgraded. Hardcoding [verify-full] here would have made one provider's mechanism
    the framework's contract.

    The anchor is still needed either way: a mode without [sslrootcert] would verify against
    the client image's own trust store, which does not carry the managed provider's CA. Set
    on the master URL, so every derived URL carries them: this rebuilds the URI rather than
    appending text, keeping whatever the provider already put in the query string. *)
let with_tls ~sslmode ~ca_cert_path url =
  let uri = Uri.of_string url in
  let without =
    List.filter
      (fun (key, _) -> not (List.mem key [ "sslmode"; "sslrootcert" ]))
      (Uri.query uri)
  in
  let query = [ "sslmode", [ sslmode ]; "sslrootcert", [ ca_cert_path ] ] @ without in
  Uri.with_query uri query |> Uri.to_string
;;

(** What the migration Job consumes. *)
let ddl ~password master_url =
  with_credentials ~user:Sol_cli_database_setup.ddl_role ~password master_url
;;

(** What each consuming unit consumes. *)
let dml ~password master_url =
  with_credentials ~user:Sol_cli_database_setup.dml_role ~password master_url
;;
