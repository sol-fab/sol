let scope_class = "the provider scope"

type attribution =
  | Named_for_target of string
  | Within_target of string

type observation =
  | Absent of
      { resource_class : string
      ; identity : string
      ; attribution : attribution
      ; checked_with : string
      }
  | Present of
      { resource_class : string
      ; identity : string
      ; found : string list
      ; attribution : attribution
      ; checked_with : string
      }
  | External of
      { resource_class : string
      ; identity : string
      ; reason : string
      }
  | Not_attributable of
      { resource_class : string
      ; reason : string
      }
  | Unobservable of
      { resource_class : string
      ; reason : string
      ; checked_with : string
      }

type verdict =
  | All_absent
  | Some_present of string list
  | Some_unknown of string list

let attribution_rule = function
  | Named_for_target rule -> rule
  | Within_target rule -> rule
;;

let lines output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
;;

let not_found ~needles reason =
  List.exists
    (fun needle -> Sol_cli_string.contains ~needle (String.lowercase_ascii reason))
    needles
;;

let unresolved ~reason =
  [ Unobservable
      { resource_class = "the provider inventory"
      ; reason
      ; checked_with = "(not run: the target could not be identified)"
      }
  ]
;;

let scope_failure ~reason =
  [ Unobservable
      { resource_class = scope_class
      ; reason
      ; checked_with = "(not run: the provider scope could not be established)"
      }
  ]
;;

let durable_state_bucket ~identity =
  External
    { resource_class = "Terraform state bucket"
    ; identity
    ; reason =
        "the state bucket is explicitly durable and outside the target's disposable \
         surface: Sol documents that it survives destroy, so its presence is the \
         contract, not residue"
    }
;;

let verdict observations =
  let present = ref [] in
  let unknown = ref [] in
  observations
  |> List.iter (function
    | Present { resource_class; identity; found; _ } ->
      present
      := Printf.sprintf "%s %s (%s)" resource_class identity (String.concat ", " found)
         :: !present
    | Unobservable { resource_class; reason; _ } ->
      unknown
      := Printf.sprintf "%s could not be observed: %s" resource_class reason :: !unknown
    | Not_attributable { resource_class; reason } ->
      unknown
      := Printf.sprintf "%s could not be attributed: %s" resource_class reason :: !unknown
    | Absent _ | External _ -> ());
  match List.rev !present, List.rev !unknown with
  | _ :: _, unknown -> Some_present (List.rev !present @ unknown)
  | [], [] -> All_absent
  | [], unknown -> Some_unknown unknown
;;

let permits_absence_claim = function
  | All_absent -> true
  | Some_present _ | Some_unknown _ -> false
;;

let residue = function
  | All_absent -> []
  | Some_present names | Some_unknown names -> names
;;

let to_sweep observations =
  let residues = ref [] in
  let indeterminate = ref [] in
  observations
  |> List.iter (function
    | Present { resource_class; identity; found; attribution; checked_with } ->
      residues
      := Printf.sprintf
           "%s %s is present after destroy: %s (%s; checked with: %s)"
           resource_class
           identity
           (String.concat ", " found)
           (attribution_rule attribution)
           checked_with
         :: !residues
    | Unobservable { resource_class; reason; checked_with } ->
      indeterminate
      := Printf.sprintf
           "%s could not be observed (%s; checked with: %s)"
           resource_class
           reason
           checked_with
         :: !indeterminate
    | Not_attributable { resource_class; reason } ->
      indeterminate
      := Printf.sprintf "%s could not be attributed: %s" resource_class reason
         :: !indeterminate
    | Absent _ | External _ -> ());
  match List.rev !residues, List.rev !indeterminate with
  | [], [] -> Sol_cli_destroy_verification.Sweep_ran { residues = []; indeterminate = [] }
  | residues, indeterminate ->
    Sol_cli_destroy_verification.Sweep_ran { residues; indeterminate }
;;

let summary = function
  | Absent { resource_class; identity; checked_with; _ } ->
    Printf.sprintf "%s %s is absent (%s)" resource_class identity checked_with
  | Present { resource_class; identity; found; checked_with; _ } ->
    Printf.sprintf
      "%s %s is PRESENT: %s (%s)"
      resource_class
      identity
      (String.concat ", " found)
      checked_with
  | External { resource_class; identity; reason } ->
    Printf.sprintf "%s %s is external: %s" resource_class identity reason
  | Not_attributable { resource_class; reason } ->
    Printf.sprintf "%s could not be attributed: %s" resource_class reason
  | Unobservable { resource_class; reason; checked_with } ->
    Printf.sprintf "%s could not be observed: %s (%s)" resource_class reason checked_with
;;

let report observations =
  let buffer = Buffer.create 1024 in
  let line format = Printf.ksprintf (Buffer.add_string buffer) format in
  line "  provider inventory: what was checked, and why anything found is this target's\n";
  line
    "    (Sol verifies absence by observing the provider directly; Terraform's own state \
     is\n\
    \     necessary evidence, and never sufficient -- a resource the provider created \
     but never\n\
    \     adopted into that state is PRESENT, not absent)\n";
  observations
  |> List.iter (function
    | Absent { resource_class; identity; attribution; checked_with } ->
      line
        "    absent: %s %s (%s; checked with: %s)\n"
        resource_class
        identity
        (attribution_rule attribution)
        checked_with
    | Present { resource_class; identity; found; attribution; checked_with } ->
      line
        "    PRESENT: %s %s -- found %s (%s; checked with: %s)\n"
        resource_class
        identity
        (String.concat ", " found)
        (attribution_rule attribution)
        checked_with
    | External { resource_class; identity; reason } ->
      line "    external: %s %s -- %s\n" resource_class identity reason
    | Not_attributable { resource_class; reason } ->
      line
        "    not attributed: %s -- %s (reported, never counted as this target's residue)\n"
        resource_class
        reason
    | Unobservable { resource_class; reason; checked_with } ->
      line
        "    UNKNOWN: %s could not be observed -- %s (checked with: %s)\n"
        resource_class
        reason
        checked_with);
  Buffer.contents buffer
;;
