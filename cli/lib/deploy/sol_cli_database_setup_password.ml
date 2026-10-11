(** Passwords for the DDL and DML role credentials.

    Sol is the sole password authority (ADR 0007): it generates these, writes them, and
    hands them to the setup Job. Nothing else invents a credential. *)

(** 32 bytes, hex-encoded, from [/dev/urandom].

    **Do not replace this with [Random.self_init] or any [Random]-based generator.**
    [/dev/urandom] is cryptographic; the OCaml [Random] module is not, and a predictable
    database password is the kind of defect that never announces itself.

    Hex rather than base64 because of where the value lands: inside a URL
    ([POSTGRES_URL] carries it), in a shell, and in PostgreSQL. Base64 introduces [+]
    and [/], which need URL-encoding in the first of those, and [0-9a-f] needs nothing
    anywhere.

    32 bytes is more than a database password needs. That is deliberate. *)
let generate () =
  let raw_bytes = 32 in
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let raw = really_input_string ic raw_bytes in
       let hex = Buffer.create (raw_bytes * 2) in
       String.iter
         (fun c -> Buffer.add_string hex (Printf.sprintf "%02x" (Char.code c)))
         raw;
       Buffer.contents hex)
;;
