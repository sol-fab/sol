(** Fresh verification through the existing installed-candidate binding owner.
    This is an offline MECHANISM input, never release-qualification authority.
    Local executable code and the caller's expected assessment binding are trusted.
    There is deliberately no constructor from saved/self-hashed JSON. *)
type expected =
  { revision : string
  ; bundle_digest : string
  ; definition_digest : string
  ; specimen_digest : string
  ; requested_target : string
  ; target : string
  }

type t

val verify
  :  repository:string
  -> candidate:string
  -> install:string
  -> workspace:string
  -> expected:expected
  -> (t, string) result

val definition : t -> Sol_cli_database_contract_data.definition
val specimen : t -> Sol_cli_database_contract_data.specimen
val expected : t -> expected
val provider : t -> Sol_cli_provider.t
