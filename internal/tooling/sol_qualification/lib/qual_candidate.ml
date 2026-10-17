open Result.Syntax
module Data = Sol_cli_database_contract_data
module Process = Sol_cli_process

type expected =
  { revision : string
  ; bundle_digest : string
  ; definition_digest : string
  ; specimen_digest : string
  ; requested_target : string
  ; target : string
  }

type t =
  { definition : Data.definition
  ; specimen : Data.specimen
  ; expected : expected
  ; provider : Sol_cli_provider.t
  ; install : string
  ; workspace : string
  }

let definition v = v.definition
let specimen v = v.specimen
let expected v = v.expected
let provider v = v.provider

(* The verified inputs, retained so a launcher executes the candidate that was
   verified instead of a path a caller supplies later. *)
let install v = v.install
let workspace v = v.workspace

(* Only this constructor issues a verified binding. Saved JSON, including a
   self-consistently rehashed declaration, is not a verified candidate receipt.
   [repository] is trusted executable code, just like the local recorder producer;
   this does not authenticate an untrusted repository or release evidence. *)
let verify ~repository ~candidate ~install ~workspace ~(expected : expected) =
  let* target =
    Sol_cli_config.parse_target expected.target
    |> Result.map_error Sol_cli_config.error_to_string
  in
  let program =
    Filename.concat repository "internal/qualification/database-contract-binding.py"
  in
  let* output =
    match
      Process.run
        (Process.cmd
           ~timeout_s:90.
           [ "python3"
           ; program
           ; "--candidate"
           ; candidate
           ; "--install"
           ; install
           ; "--workspace"
           ; workspace
           ; "--target"
           ; expected.requested_target
           ])
    with
    | Ok output -> Ok output.Process.stdout
    | Error (Process.Non_zero f) ->
      Error (Printf.sprintf "candidate contract verification exited %d" f.exit_code)
    | Error (Process.Timeout _) -> Error "candidate contract verification timed out"
    | Error (Process.Spawn_failed _) ->
      Error "candidate contract verification could not start"
  in
  let* json =
    try Ok (Yojson.Safe.from_string output) with
    | Yojson.Json_error _ -> Error "malformed verified binding"
  in
  let* json = Data.canonical json in
  let get name =
    Sol_cli_json.require ~what:"verified binding" [ name ] (fun x -> Some x)
  in
  let text name =
    Sol_cli_json.require ~what:"verified binding" [ name ] Sol_cli_json.string
  in
  let* candidate = get "candidate" json in
  let* revision = text "revision" candidate in
  let* bundle = text "bundle_sha256" candidate in
  let* d = get "definition" json in
  let* definition = Data.read_definition d in
  let* s = get "specimen" json in
  let* specimen = Data.read_specimen s in
  if
    revision <> expected.revision
    || bundle <> expected.bundle_digest
    || definition.revision <> revision
    || specimen.revision <> revision
    || definition.digest <> expected.definition_digest
    || specimen.definition_digest <> definition.digest
    || specimen.digest <> expected.specimen_digest
    || specimen.requested_target <> expected.requested_target
    || specimen.target <> expected.target
  then Error "verified candidate contract differs from the expected assessment binding"
  else
    Ok { definition; specimen; expected; provider = target.provider; install; workspace }
;;
