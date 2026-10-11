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

(** What the migration Job consumes. *)
let ddl ~password master_url =
  with_credentials ~user:Sol_cli_database_setup.ddl_role ~password master_url
;;

(** What each consuming unit consumes. *)
let dml ~password master_url =
  with_credentials ~user:Sol_cli_database_setup.dml_role ~password master_url
;;
