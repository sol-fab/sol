(* Typed release authority (schema v2). See the interface for the trust boundary.

   This module deliberately owns no MECHANISM evidence. It parses untrusted
   representations, verifies repository-owned contract and on-disk evidence, and
   evaluates a pure decision over verified records. *)

open Result.Syntax

type error =
  { stage : string
  ; diagnostic : string
  }

type provider =
  | Aws
  | Gcp

type evidence_class =
  | Mechanism
  | Behavioral

type boundary =
  | Artifact_gate
  | Migration_gate

type phase = Qual_lifecycle.phase

type candidate =
  { version : string
  ; revision : string
  ; bundle_sha256 : string
  ; runner_image : string
  }

type evaluator =
  { revision : string
  ; source_revision : string option
  ; binary_sha256 : string
  }

type attempt =
  { id : string
  ; target : string
  ; cluster : string
  ; provider : provider
  ; claim : string
  ; issuer : string
  ; candidate_revision : string
  }

type selection =
  { languages : string list
  ; primitives : string list
  }

type source =
  { path : string
  ; raw_sha256 : string
  }

type evidence =
  { path : string
  ; sha256 : string
  ; class_ : evidence_class
  }

type claim_family =
  { family : string
  ; evidence_class : evidence_class
  ; ids : (provider * string) list
  ; test : string
  }

type exception_ =
  { family : string
  ; provider : provider
  ; reason : string
  ; test : string
  }

type contract =
  { id : string
  ; revision : string
  ; providers : provider list
  ; phases : phase list
  ; attempt_claim : string
  ; attempt_issuer : string
  ; selection : selection
  ; claims : claim_family list
  ; exceptions : exception_ list
  ; source : source option
  ; digest : string
  }

type claim_status =
  | Claim_pass
  | Claim_fail
  | Claim_blocked
  | Claim_not_run
  | Claim_excluded

type claim =
  { id : string
  ; status : claim_status
  ; observations : string list
  ; reason : string option
  }

type observation =
  { id : string
  ; evidence : evidence list
  }

type permission_mechanism =
  | Direct_identity
  | Group_mapping
  | Service_account

type permission =
  { deploy_identity : string
  ; mechanism : permission_mechanism
  ; subject : string
  ; observations : string list
  }

type record_boundary =
  { kind : boundary
  ; observations : string list
  }

type verification =
  | Unverified
  | Verified

type record =
  { provider : provider
  ; candidate : candidate
  ; harness_revision : string
  ; evaluator : evaluator
  ; attempt : attempt
  ; contract_id : string
  ; contract_digest : string
  ; selection : selection
  ; phases : (phase * evidence list) list
  ; observations : observation list
  ; claims : claim list
  ; boundary : record_boundary
  ; permission : permission
  ; verification : verification
  ; raw_sha256 : string option
  ; content_sha256 : string
  }

type record_binding =
  { provider : provider
  ; attempt : string
  ; record_sha256 : string
  ; record_content_sha256 : string
  ; boundary : boundary
  ; deploy_identity : string
  ; permission_mechanism : permission_mechanism
  }

type claim_binding =
  { family : string
  ; evidence_class : evidence_class
  ; providers : (provider * string option) list
  }

type exception_view =
  { family : string
  ; provider : provider
  ; reason : string
  ; test : string
  }

type verdict =
  | Pass of
      { contract_id : string
      ; contract_digest : string
      ; contract_source : source option
      ; candidate : candidate
      ; harness_revision : string
      ; selection : selection
      ; evaluator : evaluator
      ; records : record_binding list
      ; claims : claim_binding list
      ; exceptions : exception_view list
      }
  | Refused of string list

let evaluator_revision = "sol-qual-release/v2"
let canonical_contract_path = "internal/qualification/qualification-contract.json"

(* The reviewed pin for the canonical contract bytes. A contract edit must
   update this digest in the same reviewed change; promotion and the producer
   then use a binary whose pin matches the contract revision they name. *)
let canonical_contract_sha256 =
  "28565d85ed826d27a69c8da0f8254765eaffecd291bbfe7b53faa5b1dc7f098c"
;;

let max_record_bytes = 8 * 1024 * 1024
let max_contract_bytes = 1024 * 1024
let error stage diagnostic = Error { stage; diagnostic }
let fail stage format = Printf.ksprintf (fun diagnostic -> error stage diagnostic) format
let sha256 text = Qual_domain.sha256 text
let nonempty value = String.trim value <> ""

let hex length text =
  String.length text = length
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       text
;;

let starts_with prefix text =
  let prefix_length = String.length prefix in
  String.length text >= prefix_length && String.sub text 0 prefix_length = prefix
;;

let digest_image reference =
  let length = String.length reference in
  length > 72
  && String.sub reference (length - 72) 8 = "@sha256:"
  && hex 64 (String.sub reference (length - 64) 64)
;;

let rec canonical = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, canonical value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical values)
  | value -> value
;;

let canonical_string json = Yojson.Safe.to_string (canonical json)
let semantic_digest json = sha256 (canonical_string json)

let rec reject_duplicate_keys = function
  | `Assoc fields ->
    let keys = List.map fst fields |> List.sort String.compare in
    let rec adjacent = function
      | left :: (right :: _ as rest) ->
        if left = right
        then error "encoding" (Printf.sprintf "duplicate JSON key %S" left)
        else adjacent rest
      | _ -> Ok ()
    in
    let* () = adjacent keys in
    let rec values = function
      | [] -> Ok ()
      | (_, value) :: rest ->
        let* () = reject_duplicate_keys value in
        values rest
    in
    values fields
  | `List values ->
    let rec loop = function
      | [] -> Ok ()
      | value :: rest ->
        let* () = reject_duplicate_keys value in
        loop rest
    in
    loop values
  | _ -> Ok ()
;;

let field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let required_string ~stage key json =
  match field key json with
  | Some (`String value) when nonempty value -> Ok value
  | Some (`String _) -> fail stage "%s must not be empty" key
  | _ -> fail stage "missing string %S" key
;;

let optional_string ~stage key json =
  match field key json with
  | None | Some `Null -> Ok None
  | Some (`String value) when nonempty value -> Ok (Some value)
  | Some (`String _) -> fail stage "%s must not be empty" key
  | _ -> fail stage "%s must be a string" key
;;

let required_int ~stage key json =
  match field key json with
  | Some (`Int value) -> Ok value
  | _ -> fail stage "missing integer %S" key
;;

let json_strings ~stage ~what json =
  match json with
  | `List values ->
    let rec loop seen acc = function
      | [] -> Ok (List.sort String.compare (List.rev acc))
      | `String value :: rest when nonempty value ->
        if List.mem value seen
        then fail stage "%s repeats %S" what value
        else loop (value :: seen) (value :: acc) rest
      | _ -> fail stage "%s must be a non-empty list of strings" what
    in
    (match loop [] [] values with
     | Ok [] -> fail stage "%s must not be empty" what
     | result -> result)
  | _ -> fail stage "%s must be a list of strings" what
;;

let provider_of_string ~stage = function
  | "aws" -> Ok Aws
  | "gcp" -> Ok Gcp
  | value -> fail stage "unknown provider %S" value
;;

let string_of_provider = function
  | Aws -> "aws"
  | Gcp -> "gcp"
;;

let provider_json provider = `String (string_of_provider provider)

let evidence_class_of_string ~stage = function
  | "mechanism" -> Ok Mechanism
  | "behavioral" -> Ok Behavioral
  | value -> fail stage "unknown evidence class %S" value
;;

let string_of_evidence_class = function
  | Mechanism -> "mechanism"
  | Behavioral -> "behavioral"
;;

let evidence_class_json class_ = `String (string_of_evidence_class class_)

let satisfies ~required actual =
  match required, actual with
  | Mechanism, Mechanism -> true
  | Mechanism, Behavioral -> true
  | Behavioral, Behavioral -> true
  | Behavioral, Mechanism -> false
;;

let relative_path path =
  nonempty path
  && Filename.is_relative path
  && (not (String.contains path '\\'))
  && (not (String.contains path '\000'))
  &&
  match String.split_on_char '/' path with
  | [] -> false
  | parts -> List.for_all (fun part -> part <> "" && part <> "." && part <> "..") parts
;;

let candidate_of_json ~stage json =
  let* version = required_string ~stage "version" json in
  let* revision = required_string ~stage "revision" json in
  let* bundle_sha256 = required_string ~stage "bundle_sha256" json in
  let* runner_image = required_string ~stage "runner_image" json in
  if not (hex 40 revision)
  then fail stage "candidate revision is not a 40-hex commit"
  else if not (hex 64 bundle_sha256)
  then fail stage "candidate bundle_sha256 is not a sha256"
  else if not (digest_image runner_image)
  then fail stage "candidate runner_image is not an <image>@sha256:<64 hex> reference"
  else Ok { version; revision; bundle_sha256; runner_image }
;;

let candidate_json (candidate : candidate) =
  `Assoc
    [ "version", `String candidate.version
    ; "revision", `String candidate.revision
    ; "bundle_sha256", `String candidate.bundle_sha256
    ; "runner_image", `String candidate.runner_image
    ]
;;

let evaluator ~revision ~source_revision ~binary_sha256 =
  if not (nonempty revision)
  then fail "evaluator" "the evaluator revision is empty"
  else if not (hex 64 binary_sha256)
  then fail "evaluator" "the evaluator binary digest is not a sha256"
  else (
    match source_revision with
    | Some source_revision when not (hex 40 source_revision) ->
      fail "evaluator" "the evaluator source revision is not a 40-hex commit"
    | _ -> Ok { revision; source_revision; binary_sha256 })
;;

let evaluator_of_json ~stage json =
  let* revision = required_string ~stage "revision" json in
  let* source_revision = optional_string ~stage "source_revision" json in
  let* binary_sha256 = required_string ~stage "binary_sha256" json in
  evaluator ~revision ~source_revision ~binary_sha256
  |> Result.map_error (fun _ -> { stage; diagnostic = "invalid evaluator identity" })
;;

let evaluator_json (evaluator : evaluator) =
  `Assoc
    [ "revision", `String evaluator.revision
    ; ( "source_revision"
      , match evaluator.source_revision with
        | None -> `Null
        | Some revision -> `String revision )
    ; "binary_sha256", `String evaluator.binary_sha256
    ]
;;

let selection_of_json ~stage json =
  let collect name =
    match field name json with
    | Some value -> json_strings ~stage ~what:name value
    | None -> fail stage "selection has no %s" name
  in
  let* languages = collect "languages" in
  let* primitives = collect "primitives" in
  Ok { languages; primitives }
;;

let selection_json (selection : selection) =
  `Assoc
    [ "languages", `List (List.map (fun value -> `String value) selection.languages)
    ; "primitives", `List (List.map (fun value -> `String value) selection.primitives)
    ]
;;

let covers ~required actual = List.for_all (fun value -> List.mem value actual) required

let same_strings left right =
  List.sort String.compare left = List.sort String.compare right
;;

let claim_status_of_string ~stage = function
  | "pass" -> Ok Claim_pass
  | "fail" -> Ok Claim_fail
  | "blocked" -> Ok Claim_blocked
  | "not_run" -> Ok Claim_not_run
  | "excluded" -> Ok Claim_excluded
  | value -> fail stage "unknown claim status %S" value
;;

let string_of_claim_status = function
  | Claim_pass -> "pass"
  | Claim_fail -> "fail"
  | Claim_blocked -> "blocked"
  | Claim_not_run -> "not_run"
  | Claim_excluded -> "excluded"
;;

let boundary_of_string ~stage = function
  | "artifact-gate" -> Ok Artifact_gate
  | "migration-gate" -> Ok Migration_gate
  | value -> fail stage "unknown provider boundary %S" value
;;

let string_of_boundary = function
  | Artifact_gate -> "artifact-gate"
  | Migration_gate -> "migration-gate"
;;

let permission_mechanism_of_string ~stage = function
  | "direct" -> Ok Direct_identity
  | "group" -> Ok Group_mapping
  | "service-account" -> Ok Service_account
  | value -> fail stage "unknown permission mechanism %S" value
;;

let string_of_permission_mechanism = function
  | Direct_identity -> "direct"
  | Group_mapping -> "group"
  | Service_account -> "service-account"
;;

let claim_ids_for (contract : contract) provider : string list =
  contract.claims
  |> List.concat_map (fun claim ->
    claim.ids
    |> List.filter_map (fun (candidate, id) ->
      if candidate = provider then Some id else None))
  |> List.sort String.compare
;;

let exception_for (contract : contract) ~family ~provider : exception_ option =
  List.find_opt
    (fun (declared : exception_) ->
       declared.family = family && declared.provider = provider)
    (contract.exceptions : exception_ list)
;;

let claim_family_for (contract : contract) ~provider ~id : claim_family option =
  List.find_opt
    (fun (claim : claim_family) ->
       List.exists
         (fun (candidate, claim_id) -> candidate = provider && claim_id = id)
         claim.ids)
    (contract.claims : claim_family list)
;;

(* Contract parsing ------------------------------------------------------- *)

let contract_semantic_json (contract : contract) =
  `Assoc
    [ "schema", `Int 2
    ; "id", `String contract.id
    ; "revision", `String contract.revision
    ; "providers", `List (List.map provider_json contract.providers)
    ; ( "phases"
      , `List
          (List.map
             (fun (phase : Qual_lifecycle.phase) ->
                `String (Qual_lifecycle.string_of_phase phase))
             contract.phases) )
    ; ( "attempt_requirements"
      , `Assoc
          [ "claim", `String contract.attempt_claim
          ; "issuer", `String contract.attempt_issuer
          ] )
    ; "selection", selection_json contract.selection
    ; ( "claims"
      , `List
          (List.map
             (fun (claim : claim_family) ->
                `Assoc
                  [ "family", `String claim.family
                  ; "evidence_class", evidence_class_json claim.evidence_class
                  ; ( "ids"
                    , `Assoc
                        (List.map
                           (fun (provider, id) -> string_of_provider provider, `String id)
                           claim.ids) )
                  ; "test", `String claim.test
                  ])
             contract.claims) )
    ; ( "exceptions"
      , `List
          (List.map
             (fun (declared : exception_) ->
                `Assoc
                  [ "family", `String declared.family
                  ; "provider", provider_json declared.provider
                  ; "reason", `String declared.reason
                  ; "test", `String declared.test
                  ])
             contract.exceptions) )
    ]
;;

let contract_to_yojson (contract : contract) = contract_semantic_json contract
let contract_id (contract : contract) = contract.id
let contract_digest (contract : contract) = contract.digest
let contract_source (contract : contract) = contract.source
let contract_claim_ids (contract : contract) provider = claim_ids_for contract provider

let contract_of_json_internal ?source:contract_source json =
  let* () = reject_duplicate_keys json in
  let stage = "contract" in
  let* schema = required_int ~stage "schema" json in
  if schema <> 2
  then fail stage "unsupported qualification contract schema %d" schema
  else
    let* id = required_string ~stage "id" json in
    let* revision = required_string ~stage "revision" json in
    let* provider_values =
      match field "providers" json with
      | Some (`List (values : Yojson.Safe.t list)) ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | `String value :: rest ->
            let* provider = provider_of_string ~stage value in
            loop (provider :: acc) rest
          | _ -> fail stage "contract providers must be strings"
        in
        loop [] values
      | _ -> fail stage "missing provider list"
    in
    let* () =
      if same_strings [ "aws"; "gcp" ] (List.map string_of_provider provider_values)
      then Ok ()
      else fail stage "a cross-provider release contract must name exactly aws and gcp"
    in
    let providers = [ Aws; Gcp ] in
    let* phase_values =
      match field "phases" json with
      | Some (`List values) ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | `String name :: rest ->
            let* phase =
              Qual_lifecycle.phase_of_string name
              |> Result.map_error (fun diagnostic -> { stage; diagnostic })
            in
            loop (phase :: acc) rest
          | _ -> fail stage "contract phases must be strings"
        in
        loop [] values
      | _ -> fail stage "missing contract phases"
    in
    let* () =
      if List.length phase_values <> List.length (List.sort_uniq compare phase_values)
      then fail stage "contract phases repeat a phase"
      else if
        same_strings
          (List.map Qual_lifecycle.string_of_phase phase_values)
          (List.map Qual_lifecycle.string_of_phase Qual_lifecycle.required_phases)
      then Ok ()
      else
        fail
          stage
          "contract phases %s do not equal the lifecycle authority %s"
          (String.concat "," (List.map Qual_lifecycle.string_of_phase phase_values))
          (String.concat
             ","
             (List.map Qual_lifecycle.string_of_phase Qual_lifecycle.required_phases))
    in
    let phases = Qual_lifecycle.required_phases in
    let* attempt_requirement_values =
      match field "attempt_requirements" json with
      | Some (`Assoc fields) -> Ok fields
      | _ -> fail stage "missing attempt requirements"
    in
    let* attempt_claim =
      required_string ~stage "claim" (`Assoc attempt_requirement_values)
    in
    let* attempt_issuer =
      required_string ~stage "issuer" (`Assoc attempt_requirement_values)
    in
    let* selection =
      match field "selection" json with
      | Some selection -> selection_of_json ~stage selection
      | None -> fail stage "missing contract selection"
    in
    let* claim_values =
      match field "claims" json with
      | Some (`List values) when values <> [] -> Ok values
      | _ -> fail stage "the contract names no claims"
    in
    let* claims =
      let rec loop seen seen_ids acc = function
        | [] -> Ok (List.rev acc)
        | value :: rest ->
          let* family = required_string ~stage "family" value in
          if List.mem family seen
          then fail stage "the contract repeats claim family %S" family
          else
            let* evidence_class = required_string ~stage "evidence_class" value in
            let* evidence_class = evidence_class_of_string ~stage evidence_class in
            let* test = required_string ~stage "test" value in
            if not (relative_path test)
            then fail stage "claim family %S has a non-repository test reference" family
            else
              let* ids_json =
                match field "ids" value with
                | Some (`Assoc fields) -> Ok fields
                | _ -> fail stage "claim family %S has no provider id map" family
              in
              let* ids, seen_ids =
                let rec ids_loop known seen_ids acc = function
                  | [] -> Ok (List.rev acc, seen_ids)
                  | (key, `String id) :: rest ->
                    let* provider = provider_of_string ~stage key in
                    if not (nonempty id)
                    then fail stage "claim family %S has an empty id" family
                    else if List.mem (provider, id) known
                    then fail stage "claim family %S repeats id %S" family id
                    else if List.mem (provider, id) seen_ids
                    then fail stage "claim id %S is used by more than one family" id
                    else
                      ids_loop
                        known
                        ((provider, id) :: seen_ids)
                        ((provider, id) :: acc)
                        rest
                  | (key, _) :: _ ->
                    fail stage "claim family %S has a non-string id for %S" family key
                in
                ids_loop [] seen_ids [] ids_json
              in
              let* () =
                if
                  List.exists (fun (provider, _) -> not (List.mem provider providers)) ids
                then
                  fail
                    stage
                    "claim family %S names a provider outside the contract"
                    family
                else Ok ()
              in
              let ids = List.sort (fun (left, _) (right, _) -> compare left right) ids in
              if ids = []
              then fail stage "claim family %S names no provider" family
              else
                loop
                  (family :: seen)
                  seen_ids
                  ({ family; evidence_class; ids; test } :: acc)
                  rest
      in
      loop [] [] [] claim_values
    in
    let* exception_values =
      match field "exceptions" json with
      | None -> Ok []
      | Some (`List values) -> Ok values
      | _ -> fail stage "contract exceptions must be a list"
    in
    let* exceptions =
      let rec loop seen acc = function
        | [] -> Ok (List.rev acc)
        | value :: rest ->
          let* family = required_string ~stage "family" value in
          let* provider_name = required_string ~stage "provider" value in
          let* provider = provider_of_string ~stage provider_name in
          let* reason = required_string ~stage "reason" value in
          let* test = required_string ~stage "test" value in
          if not (relative_path test)
          then fail stage "an exception has a non-repository test reference"
          else if List.mem (family, provider) seen
          then
            fail stage "the contract repeats the exception for %s/%s" family provider_name
          else
            let* claim =
              match
                List.find_opt (fun (claim : claim_family) -> claim.family = family) claims
              with
              | Some claim -> Ok claim
              | None -> fail stage "an exception names unknown claim family %S" family
            in
            if List.mem_assoc provider claim.ids
            then
              fail
                stage
                "the contract maps a %s id for %S and also declares an exception"
                provider_name
                family
            else
              loop
                ((family, provider) :: seen)
                (({ family; provider; reason; test } : exception_) :: acc)
                rest
      in
      loop [] [] exception_values
    in
    let provisional =
      { id
      ; revision
      ; providers
      ; phases
      ; attempt_claim
      ; attempt_issuer
      ; selection
      ; claims
      ; exceptions
      ; source = contract_source
      ; digest = ""
      }
    in
    let* () =
      let rec check = function
        | [] -> Ok ()
        | claim :: rest ->
          let* () =
            List.fold_left
              (fun state provider ->
                 let* () = state in
                 if List.mem_assoc provider claim.ids
                 then Ok ()
                 else if exception_for provisional ~family:claim.family ~provider <> None
                 then Ok ()
                 else
                   fail
                     stage
                     "claim family %S neither maps %s nor declares an exception"
                     claim.family
                     (string_of_provider provider))
              (Ok ())
              providers
          in
          check rest
      in
      check claims
    in
    let* () =
      List.fold_left
        (fun state provider ->
           let* () = state in
           if claim_ids_for provisional provider = []
           then
             fail
               stage
               "the contract maps no claim id to %s; an exception-only provider is \
                unsatisfiable"
               (string_of_provider provider)
           else Ok ())
        (Ok ())
        providers
    in
    let digest = semantic_digest (contract_semantic_json provisional) in
    Ok { provisional with digest }
;;

(* Record parsing --------------------------------------------------------- *)

let evidence_of_json ~stage json =
  let* path = required_string ~stage "path" json in
  let* sha256 = required_string ~stage "sha256" json in
  let* class_ = required_string ~stage "class" json in
  let* class_ = evidence_class_of_string ~stage class_ in
  if not (relative_path path)
  then fail stage "evidence path %S is not a contained relative path" path
  else if not (hex 64 sha256)
  then fail stage "evidence path %S has no raw-byte sha256" path
  else Ok { path; sha256; class_ }
;;

let evidence_json (evidence : evidence) =
  `Assoc
    [ "path", `String evidence.path
    ; "sha256", `String evidence.sha256
    ; "class", evidence_class_json evidence.class_
    ]
;;

let observation_of_json ~stage json =
  let* id = required_string ~stage "id" json in
  let* evidence =
    match field "evidence" json with
    | Some (`List values) when values <> [] ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | value :: rest ->
          let* value = evidence_of_json ~stage value in
          loop (value :: acc) rest
      in
      loop [] values
    | _ -> fail stage "observation %S has no evidence" id
  in
  Ok { id; evidence }
;;

let observation_json (observation : observation) =
  `Assoc
    [ "id", `String observation.id
    ; "evidence", `List (List.map evidence_json observation.evidence)
    ]
;;

let claim_of_json ~stage json =
  let* id = required_string ~stage "id" json in
  let* status = required_string ~stage "status" json in
  let* status = claim_status_of_string ~stage status in
  let* reason = optional_string ~stage "reason" json in
  let* observations =
    match field "observations" json with
    | None -> Ok []
    | Some (`List values) ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | `String value :: rest when nonempty value ->
          if List.mem value acc
          then fail stage "claim %S repeats observation %S" id value
          else loop (value :: acc) rest
        | _ -> fail stage "claim %S observations must be strings" id
      in
      loop [] values
    | _ -> fail stage "claim %S observations must be a list" id
  in
  match status with
  | Claim_pass | Claim_excluded | Claim_fail | Claim_blocked | Claim_not_run ->
    Ok { id; status; observations; reason }
;;

let claim_json (claim : claim) =
  `Assoc
    ([ "id", `String claim.id
     ; "status", `String (string_of_claim_status claim.status)
     ; "observations", `List (List.map (fun value -> `String value) claim.observations)
     ]
     @
     match claim.reason with
     | None -> []
     | Some reason -> [ "reason", `String reason ])
;;

let contract_of_json json = contract_of_json_internal json

let record_of_json ~(contract : contract) json =
  let* () = reject_duplicate_keys json in
  let stage = "record" in
  let* schema = required_int ~stage "schema" json in
  if schema <> 2
  then fail stage "unsupported provider record schema %d" schema
  else
    let* provider_name = required_string ~stage "provider" json in
    let* provider = provider_of_string ~stage provider_name in
    let* candidate_json_value =
      match field "candidate" json with
      | Some value -> Ok value
      | None -> fail stage "missing candidate"
    in
    let* candidate = candidate_of_json ~stage candidate_json_value in
    let* harness_revision = required_string ~stage "harness_revision" json in
    if not (hex 40 harness_revision)
    then fail stage "harness_revision is not a 40-hex commit"
    else
      let* evaluator =
        match field "evaluator" json with
        | Some value -> evaluator_of_json ~stage value
        | None -> fail stage "missing evaluator identity"
      in
      let* attempt_json =
        match field "attempt" json with
        | Some value -> Ok value
        | None -> fail stage "missing attempt provenance"
      in
      let* attempt_id = required_string ~stage "id" attempt_json in
      let* target = required_string ~stage "target" attempt_json in
      let* cluster = required_string ~stage "cluster" attempt_json in
      let* attempt_provider_name = required_string ~stage "provider" attempt_json in
      let* attempt_provider = provider_of_string ~stage attempt_provider_name in
      let* claim = required_string ~stage "claim" attempt_json in
      let* issuer = required_string ~stage "issuer" attempt_json in
      let* candidate_revision =
        required_string ~stage "candidate_revision" attempt_json
      in
      if attempt_provider <> provider
      then
        fail
          stage
          "attempt provider %S does not match record provider %S"
          attempt_provider_name
          provider_name
      else if not (hex 40 candidate_revision)
      then fail stage "attempt candidate_revision is not a 40-hex commit"
      else if candidate_revision <> candidate.revision
      then fail stage "attempt candidate revision does not match the record candidate"
      else
        let* contract_json =
          match field "contract" json with
          | Some value -> Ok value
          | None -> fail stage "missing contract binding"
        in
        let* contract_id = required_string ~stage "id" contract_json in
        let* contract_digest = required_string ~stage "digest" contract_json in
        if contract_id <> contract.id
        then fail stage "record names contract %S, not %S" contract_id contract.id
        else if contract_digest <> contract.digest
        then
          fail stage "record names a different contract digest than the loaded contract"
        else
          let* selection =
            match field "selection" json with
            | Some value -> selection_of_json ~stage value
            | None -> fail stage "missing selection"
          in
          let* phases =
            match field "phases" json with
            | Some (`List values) when values <> [] ->
              let rec loop seen acc = function
                | [] -> Ok (List.rev acc)
                | value :: rest ->
                  let* name = required_string ~stage "name" value in
                  let* phase =
                    Qual_lifecycle.phase_of_string name
                    |> Result.map_error (fun diagnostic -> { stage; diagnostic })
                  in
                  if List.mem phase seen
                  then fail stage "record repeats phase %S" name
                  else
                    let* evidence =
                      match field "evidence" value with
                      | Some (`List values) when values <> [] ->
                        let rec collect acc = function
                          | [] -> Ok (List.rev acc)
                          | value :: rest ->
                            let* value = evidence_of_json ~stage value in
                            collect (value :: acc) rest
                        in
                        collect [] values
                      | _ -> fail stage "phase %S has no evidence" name
                    in
                    loop (phase :: seen) ((phase, evidence) :: acc) rest
              in
              loop [] [] values
            | _ -> fail stage "record has no phases"
          in
          let* observations =
            match field "observations" json with
            | Some (`List values) when values <> [] ->
              let rec loop seen acc = function
                | [] -> Ok (List.rev acc)
                | value :: rest ->
                  let* observation = observation_of_json ~stage value in
                  if List.mem observation.id seen
                  then fail stage "record repeats observation %S" observation.id
                  else loop (observation.id :: seen) (observation :: acc) rest
              in
              loop [] [] values
            | _ -> fail stage "record has no observations"
          in
          let* claims =
            match field "claims" json with
            | Some (`List values) when values <> [] ->
              let rec loop seen acc = function
                | [] -> Ok (List.rev acc)
                | value :: rest ->
                  let* claim = claim_of_json ~stage value in
                  if List.mem claim.id seen
                  then fail stage "record repeats claim %S" claim.id
                  else loop (claim.id :: seen) (claim :: acc) rest
              in
              loop [] [] values
            | _ -> fail stage "record has no claims"
          in
          let* boundary_json =
            match field "boundary" json with
            | Some value -> Ok value
            | None -> fail stage "missing typed provider boundary"
          in
          let* boundary_name = required_string ~stage "kind" boundary_json in
          let* boundary_kind = boundary_of_string ~stage boundary_name in
          let* boundary_observations =
            match field "observations" boundary_json with
            | Some (`List values) ->
              let rec loop acc = function
                | [] -> Ok (List.rev acc)
                | `String value :: rest when nonempty value ->
                  if List.mem value acc
                  then fail stage "boundary repeats observation %S" value
                  else loop (value :: acc) rest
                | _ -> fail stage "boundary observations must be strings"
              in
              loop [] values
            | _ -> fail stage "boundary names no observations"
          in
          let* permission_json =
            match field "permission_binding" json with
            | Some value -> Ok value
            | None -> fail stage "missing permission binding"
          in
          let* deploy_identity =
            required_string ~stage "deploy_identity" permission_json
          in
          let* mechanism_name = required_string ~stage "mechanism" permission_json in
          let* mechanism = permission_mechanism_of_string ~stage mechanism_name in
          let* subject = required_string ~stage "subject" permission_json in
          if mechanism = Group_mapping && subject = deploy_identity
          then
            fail
              stage
              "a group permission binding must name how the deploy identity receives the \
               group"
          else
            let* permission_observations =
              match field "observations" permission_json with
              | Some (`List values) ->
                let rec loop acc = function
                  | [] -> Ok (List.rev acc)
                  | `String value :: rest when nonempty value ->
                    if List.mem value acc
                    then fail stage "permission repeats observation %S" value
                    else loop (value :: acc) rest
                  | _ -> fail stage "permission observations must be strings"
                in
                loop [] values
              | _ -> fail stage "permission binding names no observations"
            in
            let content = semantic_digest json in
            Ok
              { provider
              ; candidate
              ; harness_revision
              ; evaluator
              ; attempt =
                  { id = attempt_id
                  ; target
                  ; cluster
                  ; provider
                  ; claim
                  ; issuer
                  ; candidate_revision
                  }
              ; contract_id
              ; contract_digest
              ; selection
              ; phases
              ; observations
              ; claims
              ; boundary = { kind = boundary_kind; observations = boundary_observations }
              ; permission =
                  { deploy_identity
                  ; mechanism
                  ; subject
                  ; observations = permission_observations
                  }
              ; verification = Unverified
              ; raw_sha256 = None
              ; content_sha256 = content
              }
;;

let record_to_yojson (record : record) =
  `Assoc
    [ "schema", `Int 2
    ; "provider", provider_json record.provider
    ; "candidate", candidate_json record.candidate
    ; "harness_revision", `String record.harness_revision
    ; "evaluator", evaluator_json record.evaluator
    ; ( "attempt"
      , `Assoc
          [ "id", `String record.attempt.id
          ; "target", `String record.attempt.target
          ; "cluster", `String record.attempt.cluster
          ; "provider", provider_json record.attempt.provider
          ; "claim", `String record.attempt.claim
          ; "issuer", `String record.attempt.issuer
          ; "candidate_revision", `String record.attempt.candidate_revision
          ] )
    ; ( "contract"
      , `Assoc
          [ "id", `String record.contract_id; "digest", `String record.contract_digest ] )
    ; "selection", selection_json record.selection
    ; ( "phases"
      , `List
          (List.map
             (fun (phase, evidence) ->
                `Assoc
                  [ "name", `String (Qual_lifecycle.string_of_phase phase)
                  ; "evidence", `List (List.map evidence_json evidence)
                  ])
             record.phases) )
    ; "observations", `List (List.map observation_json record.observations)
    ; "claims", `List (List.map claim_json record.claims)
    ; ( "boundary"
      , `Assoc
          [ "kind", `String (string_of_boundary record.boundary.kind)
          ; ( "observations"
            , `List (List.map (fun value -> `String value) record.boundary.observations) )
          ] )
    ; ( "permission_binding"
      , `Assoc
          [ "deploy_identity", `String record.permission.deploy_identity
          ; ( "mechanism"
            , `String (string_of_permission_mechanism record.permission.mechanism) )
          ; "subject", `String record.permission.subject
          ; ( "observations"
            , `List (List.map (fun value -> `String value) record.permission.observations)
            )
          ] )
    ]
;;

(* Evidence loading ------------------------------------------------------- *)

let read_file ~stage ~limit path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG
    then fail stage "%s is not a regular file" path
    else if stat.Unix.st_size > limit
    then fail stage "%s exceeds the %d-byte evidence bound" path limit
    else (
      let bytes = In_channel.with_open_bin path In_channel.input_all in
      if String.length bytes > limit
      then fail stage "%s exceeds the %d-byte evidence bound" path limit
      else Ok bytes)
  with
  | Unix.Unix_error (code, _, _) -> fail stage "%s: %s" path (Unix.error_message code)
  | Sys_error message -> fail stage "%s" message
;;

let realpath ~stage path =
  try Ok (Unix.realpath path) with
  | Unix.Unix_error (code, _, _) -> fail stage "%s: %s" path (Unix.error_message code)
;;

let load_evidence ~directory evidence =
  let stage = "evidence" in
  if not (relative_path evidence.path)
  then fail stage "evidence path %S is not contained" evidence.path
  else
    let* base = realpath ~stage directory in
    let* actual = realpath ~stage (Filename.concat base evidence.path) in
    if Filename.dirname actual <> base
    then fail stage "evidence %S escapes the attempt directory" evidence.path
    else
      let* bytes = read_file ~stage ~limit:max_record_bytes actual in
      let digest = sha256 bytes in
      if digest <> evidence.sha256
      then
        fail
          stage
          "evidence %S has sha256:%s, not the recorded sha256:%s"
          evidence.path
          digest
          evidence.sha256
      else Ok evidence
;;

let load_evidence_list ~directory evidence =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
      let* value = load_evidence ~directory value in
      loop (value :: acc) rest
  in
  loop [] evidence
;;

let lifecycle_reason assessment =
  match Qual_lifecycle.assess assessment with
  | { eligible = true; required_phases_ok = true; reasons = []; _ } -> None
  | assessed ->
    Some
      (Printf.sprintf
         "the attempt lifecycle is not a clean promotion-eligible sequence: %s"
         (match assessed.reasons with
          | [] -> "no reason recorded"
          | reasons ->
            String.concat "; " (List.map Qual_lifecycle.string_of_reason reasons)))
;;

let check_attempt ~directory (record : record) =
  let stage = "attempt" in
  match Qual_lifecycle.of_dir directory with
  | Error diagnostic -> fail stage "%s" diagnostic
  | Ok lifecycle ->
    let provenance : Qual_lifecycle.provenance = lifecycle.provenance in
    let mismatch name expected actual =
      fail stage "attempt %s is %S, not the record's %S" name actual expected
    in
    let* () =
      if provenance.attempt = record.attempt.id
      then Ok ()
      else mismatch "identity" record.attempt.id provenance.attempt
    in
    let* () =
      match
        ( provenance.candidate_revision
        , provenance.provider
        , provenance.target
        , provenance.cluster )
      with
      | Some revision, Some provider, Some target, Some cluster ->
        let* () =
          if revision = record.attempt.candidate_revision
          then Ok ()
          else mismatch "candidate_revision" record.attempt.candidate_revision revision
        in
        let* () =
          if provider = string_of_provider record.provider
          then Ok ()
          else mismatch "provider" (string_of_provider record.provider) provider
        in
        let* () =
          if target = record.attempt.target
          then Ok ()
          else mismatch "target" record.attempt.target target
        in
        if cluster = record.attempt.cluster
        then Ok ()
        else mismatch "cluster" record.attempt.cluster cluster
      | _ ->
        fail
          stage
          "attempt.txt records no candidate revision, provider, target or cluster; v2 \
           cannot bind this record"
    in
    let* () =
      if provenance.claim = record.attempt.claim
      then Ok ()
      else mismatch "claim" record.attempt.claim provenance.claim
    in
    let* () =
      if provenance.issuer = record.attempt.issuer
      then Ok ()
      else mismatch "issuer" record.attempt.issuer provenance.issuer
    in
    let* () =
      let recorded =
        lifecycle.Qual_lifecycle.verdicts
        |> List.map (fun verdict -> verdict.Qual_lifecycle.phase)
        |> List.filter (fun phase -> List.mem phase Qual_lifecycle.required_phases)
      in
      if recorded = Qual_lifecycle.required_phases
      then Ok ()
      else
        fail
          stage
          "the attempt ledger records %s, not the required lifecycle sequence %s"
          (String.concat "," (List.map Qual_lifecycle.string_of_phase recorded))
          (String.concat
             ","
             (List.map Qual_lifecycle.string_of_phase Qual_lifecycle.required_phases))
    in
    (match lifecycle_reason lifecycle with
     | None -> Ok ()
     | Some diagnostic -> fail stage "%s" diagnostic)
;;

let load_record ~(contract : contract) ~directory ~path =
  let stage = "record" in
  let* bytes = read_file ~stage ~limit:max_record_bytes path in
  let raw_sha256 = sha256 bytes in
  let* json =
    try Ok (Yojson.Safe.from_string bytes) with
    | Yojson.Json_error diagnostic -> fail stage "malformed record JSON: %s" diagnostic
  in
  let* record = record_of_json ~contract json in
  let evidence =
    (List.map snd record.phases |> List.concat)
    @ List.concat_map (fun observation -> observation.evidence) record.observations
  in
  let* _ = load_evidence_list ~directory evidence in
  let* () = check_attempt ~directory record in
  Ok { record with verification = Verified; raw_sha256 = Some raw_sha256 }
;;

let load_contract ~repository =
  let stage = "contract" in
  let path = Filename.concat repository canonical_contract_path in
  let* bytes = read_file ~stage ~limit:max_contract_bytes path in
  let raw_sha256 = sha256 bytes in
  let* () =
    if raw_sha256 <> canonical_contract_sha256
    then
      fail
        stage
        "the contract bytes at %s (sha256:%s) do not match the evaluator's reviewed pin \
         (sha256:%s)"
        canonical_contract_path
        raw_sha256
        canonical_contract_sha256
    else Ok ()
  in
  let* json =
    try Ok (Yojson.Safe.from_string bytes) with
    | Yojson.Json_error diagnostic -> fail stage "malformed contract JSON: %s" diagnostic
  in
  let* contract =
    contract_of_json_internal ~source:{ path = canonical_contract_path; raw_sha256 } json
  in
  let* () =
    List.fold_left
      (fun state reference ->
         let* () = state in
         let path = Filename.concat repository reference in
         let* base = realpath ~stage repository in
         let* actual = realpath ~stage path in
         if actual <> base && not (starts_with (base ^ "/") actual)
         then fail stage "contract test reference %S escapes the repository" reference
         else (
           match Unix.stat actual with
           | { Unix.st_kind = Unix.S_REG; _ } -> Ok ()
           | _ -> fail stage "contract test reference %S is not a regular file" reference
           | exception Unix.Unix_error (code, _, _) ->
             fail
               stage
               "contract test reference %S: %s"
               reference
               (Unix.error_message code)))
      (Ok ())
      (List.concat_map
         (fun (claim : claim_family) -> [ claim.test ])
         (contract.claims : claim_family list)
       @ List.map (fun (declared : exception_) -> declared.test) contract.exceptions)
  in
  Ok contract
;;

(* Pure evaluator --------------------------------------------------------- *)

let evidence_in_observations record ids =
  ids
  |> List.filter_map (fun id ->
    List.find_opt (fun observation -> observation.id = id) record.observations)
  |> List.concat_map (fun observation -> observation.evidence)
;;

let observations_exist record ids =
  List.for_all
    (fun id -> List.exists (fun observation -> observation.id = id) record.observations)
    ids
;;

let evaluator_reasons
      ~(evaluator : evaluator)
      (contract : contract)
      (aws : record)
      (gcp : record)
  =
  let reasons = ref [] in
  let refuse format =
    Printf.ksprintf (fun message -> reasons := message :: !reasons) format
  in
  let check condition format =
    Printf.ksprintf
      (fun message -> if not condition then reasons := message :: !reasons)
      format
  in
  check
    (Option.is_some contract.source)
    "the contract was not loaded from the repository-owned source";
  check
    (aws.verification = Verified)
    "the aws record was not loaded and evidence-verified";
  check
    (gcp.verification = Verified)
    "the gcp record was not loaded and evidence-verified";
  check
    (aws.provider = Aws)
    "the aws slot contains a %s record"
    (string_of_provider aws.provider);
  check
    (gcp.provider = Gcp)
    "the gcp slot contains a %s record"
    (string_of_provider gcp.provider);
  check
    (aws.contract_id = contract.id && aws.contract_digest = contract.digest)
    "the aws record does not bind the loaded contract id and digest";
  check
    (gcp.contract_id = contract.id && gcp.contract_digest = contract.digest)
    "the gcp record does not bind the loaded contract id and digest";
  check
    (aws.candidate = gcp.candidate)
    "the aws and gcp records name different candidates";
  check
    (aws.harness_revision = gcp.harness_revision)
    "the aws and gcp records name different harness revisions";
  check
    (aws.evaluator = gcp.evaluator)
    "the aws and gcp records were not judged by the same evaluator";
  check
    (aws.evaluator = evaluator)
    "the aws record was not produced by this evaluator revision and binary";
  check
    (gcp.evaluator = evaluator)
    "the gcp record was not produced by this evaluator revision and binary";
  check
    (aws.attempt.id <> gcp.attempt.id)
    "the same attempt cannot be both provider records";
  check
    (aws.attempt.candidate_revision = gcp.attempt.candidate_revision
     && aws.attempt.candidate_revision = aws.candidate.revision)
    "the attempt provenance does not bind the candidate revision";
  check
    (covers ~required:contract.selection.languages aws.selection.languages)
    "the aws record does not cover the contract's required languages";
  check
    (covers ~required:contract.selection.primitives aws.selection.primitives)
    "the aws record does not cover the contract's required primitives";
  check
    (covers ~required:contract.selection.languages gcp.selection.languages)
    "the gcp record does not cover the contract's required languages";
  check
    (covers ~required:contract.selection.primitives gcp.selection.primitives)
    "the gcp record does not cover the contract's required primitives";
  check
    (aws.selection = gcp.selection)
    "the aws and gcp records exercised different selections";
  let required = Qual_lifecycle.required_phases in
  List.iter
    (fun (label, (record : record)) ->
       let phases = List.map fst record.phases in
       check
         (phases = required)
         "the %s record phases do not match the lifecycle authority in order"
         label;
       List.iter
         (fun (phase, evidence) ->
            check
              (evidence <> [])
              "the %s record phase %s has no evidence"
              label
              (Qual_lifecycle.string_of_phase phase);
            check
              (List.exists
                 (fun evidence -> satisfies ~required:Behavioral evidence.class_)
                 evidence)
              "the %s record phase %s has no behavioural evidence"
              label
              (Qual_lifecycle.string_of_phase phase))
         record.phases)
    [ "aws", aws; "gcp", gcp ];
  List.iter
    (fun (label, (record : record)) ->
       let expected = claim_ids_for contract record.provider in
       let actual =
         List.map (fun (claim : claim) -> claim.id) record.claims
         |> List.sort String.compare
       in
       check
         (expected = actual)
         "the %s record claims %s, not the contract's %s"
         label
         (String.concat "," actual)
         (String.concat "," expected);
       List.iter
         (fun (claim : claim) ->
            match claim_family_for contract ~provider:record.provider ~id:claim.id with
            | None -> refuse "the %s record claims unknown id %S" label claim.id
            | Some family ->
              (match claim.status with
               | Claim_pass ->
                 check
                   (claim.observations <> [])
                   "the %s claim %S passes with no observation references"
                   label
                   claim.id;
                 check
                   (observations_exist record claim.observations)
                   "the %s claim %S references an observation the record does not contain"
                   label
                   claim.id;
                 let evidence = evidence_in_observations record claim.observations in
                 check
                   (evidence <> [])
                   "the %s claim %S references no evidence"
                   label
                   claim.id;
                 check
                   (List.exists
                      (fun evidence ->
                         satisfies ~required:family.evidence_class evidence.class_)
                      evidence)
                   "the %s claim %S has no %s evidence"
                   label
                   claim.id
                   (string_of_evidence_class family.evidence_class)
               | Claim_excluded ->
                 refuse
                   "the %s claim %S is excluded; a provider-specific omission is a \
                    contract exception, not a record status"
                   label
                   claim.id
               | Claim_fail -> refuse "the %s claim %S failed" label claim.id
               | Claim_blocked -> refuse "the %s claim %S is blocked" label claim.id
               | Claim_not_run -> refuse "the %s claim %S was not run" label claim.id))
         record.claims;
       let boundary_evidence =
         evidence_in_observations record record.boundary.observations
       in
       check
         (record.boundary.observations <> [])
         "the %s record boundary names no observations"
         label;
       check
         (observations_exist record record.boundary.observations)
         "the %s record boundary references observations the record does not contain"
         label;
       check
         (List.exists
            (fun evidence -> satisfies ~required:Behavioral evidence.class_)
            boundary_evidence)
         "the %s record boundary is not supported by behavioural evidence"
         label;
       let permission_evidence =
         evidence_in_observations record record.permission.observations
       in
       check
         (record.permission.observations <> [])
         "the %s record permission binding names no observations"
         label;
       check
         (observations_exist record record.permission.observations)
         "the %s record permission binding references observations the record does not \
          contain"
         label;
       check
         (List.exists
            (fun evidence -> satisfies ~required:Behavioral evidence.class_)
            permission_evidence)
         "the %s record permission binding is not supported by behavioural evidence"
         label;
       check
         (record.permission.mechanism <> Group_mapping
          || (nonempty record.permission.subject
              && record.permission.subject <> record.permission.deploy_identity))
         "the %s group permission binding does not name how the deploy identity receives \
          it"
         label;
       check
         (record.attempt.claim = contract.attempt_claim)
         "the %s attempt claim %S is not the contract's %S"
         label
         record.attempt.claim
         contract.attempt_claim;
       check
         (record.attempt.issuer = contract.attempt_issuer)
         "the %s attempt issuer %S is not the contract's %S"
         label
         record.attempt.issuer
         contract.attempt_issuer)
    [ "aws", aws; "gcp", gcp ];
  List.rev !reasons
;;

let record_binding ~record_sha256 (record : record) =
  { provider = record.provider
  ; attempt = record.attempt.id
  ; record_sha256
  ; record_content_sha256 = record.content_sha256
  ; boundary = record.boundary.kind
  ; deploy_identity = record.permission.deploy_identity
  ; permission_mechanism = record.permission.mechanism
  }
;;

let claim_binding (contract : contract) (claim : claim_family) =
  { family = claim.family
  ; evidence_class = claim.evidence_class
  ; providers =
      List.map
        (fun provider ->
           let id = List.assoc_opt provider claim.ids in
           provider, id)
        contract.providers
  }
;;

let exception_view (exception_ : exception_) =
  { family = exception_.family
  ; provider = exception_.provider
  ; reason = exception_.reason
  ; test = exception_.test
  }
;;

let evaluate ~(evaluator : evaluator) (contract : contract) aws gcp =
  let reasons = evaluator_reasons ~evaluator contract aws gcp in
  match reasons, aws.raw_sha256, gcp.raw_sha256 with
  | _ :: _, _, _ -> Refused reasons
  | [], Some aws_sha256, Some gcp_sha256 ->
    Pass
      { contract_id = contract.id
      ; contract_digest = contract.digest
      ; contract_source = contract.source
      ; candidate = aws.candidate
      ; harness_revision = aws.harness_revision
      ; selection = aws.selection
      ; evaluator
      ; records =
          [ record_binding ~record_sha256:aws_sha256 aws
          ; record_binding ~record_sha256:gcp_sha256 gcp
          ]
      ; claims = List.map (claim_binding contract) contract.claims
      ; exceptions = List.map exception_view contract.exceptions
      }
  | [], _, _ -> Refused [ "the record bytes were not read" ]
;;

(* Verdict encoding ------------------------------------------------------- *)

let source_json (source : source) =
  `Assoc [ "path", `String source.path; "sha256", `String source.raw_sha256 ]
;;

let claim_binding_json (binding : claim_binding) =
  `Assoc
    [ "family", `String binding.family
    ; "evidence_class", evidence_class_json binding.evidence_class
    ; ( "providers"
      , `List
          (List.map
             (fun (provider, id) ->
                `Assoc
                  ([ "provider", provider_json provider ]
                   @
                   match id with
                   | None -> [ "id", `Null ]
                   | Some id -> [ "id", `String id ]))
             binding.providers) )
    ]
;;

let exception_json (exception_ : exception_view) =
  `Assoc
    [ "family", `String exception_.family
    ; "provider", provider_json exception_.provider
    ; "reason", `String exception_.reason
    ; "test", `String exception_.test
    ]
;;

let record_binding_json (binding : record_binding) =
  `Assoc
    [ "provider", provider_json binding.provider
    ; "attempt", `String binding.attempt
    ; "record_sha256", `String binding.record_sha256
    ; "record_content_sha256", `String binding.record_content_sha256
    ; "boundary", `String (string_of_boundary binding.boundary)
    ; "deploy_identity", `String binding.deploy_identity
    ; ( "permission_mechanism"
      , `String (string_of_permission_mechanism binding.permission_mechanism) )
    ]
;;

let verdict_to_yojson = function
  | Pass pass ->
    `Assoc
      [ "schema", `Int 2
      ; "kind", `String "cross-provider-qualification-parity"
      ; "verdict", `String "PASS"
      ; ( "contract"
        , `Assoc
            ([ "id", `String pass.contract_id; "digest", `String pass.contract_digest ]
             @
             match pass.contract_source with
             | None -> []
             | Some source -> [ "source", source_json source ]) )
      ; "candidate", candidate_json pass.candidate
      ; "harness_revision", `String pass.harness_revision
      ; "selection", selection_json pass.selection
      ; "evaluator", evaluator_json pass.evaluator
      ; "records", `List (List.map record_binding_json pass.records)
      ; "claims", `List (List.map claim_binding_json pass.claims)
      ; "exceptions", `List (List.map exception_json pass.exceptions)
      ; "reasons", `List []
      ]
  | Refused reasons ->
    `Assoc
      [ "schema", `Int 2
      ; "kind", `String "cross-provider-qualification-parity"
      ; "verdict", `String "REFUSED"
      ; "reasons", `List (List.map (fun reason -> `String reason) reasons)
      ]
;;
