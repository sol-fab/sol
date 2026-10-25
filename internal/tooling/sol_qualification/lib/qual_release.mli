(** Typed release qualification authority (schema v2).

    This module is the release-authority owner. [Qual_evidence] and
    [Qual_lifecycle] remain mechanism/attempt authorities: this module does not
    promote either of them to release authority. It reuses their public values
    (content digests, phase names, attempt provenance) and adds the explicit
    contract, evidence, record, parity-verdict and promotion-authorization
    boundary.

    Separation of duties:

    - [contract_of_json] / [record_of_json] parse untrusted representations only;
      they do not read evidence and cannot construct a verdict.
    - [load_contract] reads the repository-owned, revision-reviewed contract.
    - [load_record] reads one provider record and verifies every evidence
      reference (containment, existence, raw-byte SHA-256 and class) and its
      attempt/lifecycle binding against the evidence directory.
    - [evaluate] is pure. It consumes verified records and never reads the
      filesystem, starts a subprocess or consults a clock.
    - Only [Pass] carries a parity verdict. A recorded boolean, a [PASS] string in
      a producer document or a stored verdict is not authority; promotion must
      re-run the evaluator and compare the complete verdict (see
      [verdict_to_yojson]).

    The authoritative phase set comes from [Qual_lifecycle.required_phases]. The
    authoritative claim set is the contract, and this module contains no second
    required-claim list. *)

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

type candidate = private
  { version : string
  ; revision : string
  ; bundle_sha256 : string
  ; runner_image : string
  }

type evaluator = private
  { revision : string
  ; source_revision : string option
  ; binary_sha256 : string
  }

(** The attempt facts v2 binds. [#1729] owns typed attempt transitions; until
    that owner lands, this is the explicit interim [Qual_lifecycle] boundary:
    the same [attempt.txt]/[phase-verdicts.txt] authority, not a third attempt
    model. *)
type attempt = private
  { id : string
  ; target : string
  ; cluster : string
  ; provider : provider
  ; claim : string
  ; issuer : string
  ; candidate_revision : string
  }

type selection = private
  { languages : string list
  ; primitives : string list
  }

type source = private
  { path : string
  ; raw_sha256 : string
  }

type evidence = private
  { path : string
  ; sha256 : string
  ; class_ : evidence_class
  }

type claim_family = private
  { family : string
  ; evidence_class : evidence_class
  ; ids : (provider * string) list
  ; test : string
  }

type exception_ = private
  { family : string
  ; provider : provider
  ; reason : string
  ; test : string
  }

type contract = private
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

type claim = private
  { id : string
  ; status : claim_status
  ; observations : string list
  ; reason : string option
  }

type observation = private
  { id : string
  ; evidence : evidence list
  }

type permission_mechanism =
  | Direct_identity
  | Group_mapping
  | Service_account

type permission = private
  { deploy_identity : string
  ; mechanism : permission_mechanism
  ; subject : string
  ; observations : string list
  }

type record_boundary = private
  { kind : boundary
  ; observations : string list
  }

type verification = private
  | Unverified
  | Verified

type record = private
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

type record_binding = private
  { provider : provider
  ; attempt : string
  ; record_sha256 : string
  ; record_content_sha256 : string
  ; boundary : boundary
  ; deploy_identity : string
  ; permission_mechanism : permission_mechanism
  }

type claim_binding = private
  { family : string
  ; evidence_class : evidence_class
  ; providers : (provider * string option) list
  }

type exception_view = private
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

val evaluator_revision : string
val canonical_contract_path : string
val canonical_contract_sha256 : string
val contract_of_json : Yojson.Safe.t -> (contract, error) result

(** Parse a provider record only. Evidence references are represented, not
    resolved; use [load_record] before evaluating. *)
val record_of_json : contract:contract -> Yojson.Safe.t -> (record, error) result

(** Load the repository-owned canonical contract. The path is fixed: a caller
    cannot substitute an attached or weaker contract. *)
val load_contract : repository:string -> (contract, error) result

(** Read and verify one provider record. [path] names the record file and
    [directory] is the attempt/evidence directory its references and
    [attempt.txt]/[phase-verdicts.txt] must resolve inside. *)
val load_record
  :  contract:contract
  -> directory:string
  -> path:string
  -> (record, error) result

val evaluate : evaluator:evaluator -> contract -> record -> record -> verdict
val verdict_to_yojson : verdict -> Yojson.Safe.t
val contract_to_yojson : contract -> Yojson.Safe.t
val evaluator_json : evaluator -> Yojson.Safe.t
val contract_id : contract -> string
val contract_digest : contract -> string
val contract_source : contract -> source option
val record_to_yojson : record -> Yojson.Safe.t

(** The evaluator identity for the executable built from this source. The
    revision is the semantic identity of the evaluating implementation; the
    caller supplies the binary digest because only the executable boundary can
    observe its own bytes. *)
val evaluator
  :  revision:string
  -> source_revision:string option
  -> binary_sha256:string
  -> (evaluator, error) result
