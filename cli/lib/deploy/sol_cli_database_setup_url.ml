(** The DDL and DML connection URLs, derived from the master connection the provisioning
    layer reports.

    **Query parameters are preserved, deliberately.** 2d adds
    [sslmode=verify-full&sslrootcert=...] to the master URL, and every consumer has to
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

(** Add the parameters every consumer carries once TLS is required: full verification
    against the provider's CA, which the deploy has mounted at [ca_cert_path]. Both are
    needed — [sslmode=require] would encrypt without checking the server's identity, which
    is the gap this closes, and [sslmode=verify-full] without [sslrootcert] would verify
    against the client image's own trust store, which does not carry the managed
    provider's CA. Set on the master URL, so every derived URL carries them: this rebuilds
    the URI rather than appending text, keeping whatever the provider already put in the
    query string. *)
let with_tls ~ca_cert_path url =
  let uri = Uri.of_string url in
  let without =
    List.filter
      (fun (key, _) -> not (List.mem key [ "sslmode"; "sslrootcert" ]))
      (Uri.query uri)
  in
  let query =
    [ "sslmode", [ "verify-full" ]; "sslrootcert", [ ca_cert_path ] ] @ without
  in
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
