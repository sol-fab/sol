type verdict =
  | Pass
  | Fail of string
  | Unknown of string
  | Not_run of string

type claim =
  { id : string
  ; verdict : verdict
  }

(* An unreadable prerequisite leaves dependent claims NOT_RUN. Independent claims
   still execute, so a failed neighbour does not hide a second observation. *)
let dependent prerequisite observe =
  match prerequisite with
  | Ok value -> observe value
  | Error reason -> Not_run reason
;;

let verdict_name = function
  | Pass -> "PASS"
  | Fail _ -> "FAIL"
  | Unknown _ -> "UNKNOWN"
  | Not_run _ -> "NOT_RUN"
;;

let verdict_json verdict =
  let detail =
    match verdict with
    | Pass -> "claim established"
    | Fail s | Unknown s | Not_run s -> s
  in
  `Assoc [ "verdict", `String (verdict_name verdict); "detail", `String detail ]
;;

let report ~context claims =
  let passed = claims <> [] && List.for_all (fun c -> c.verdict = Pass) claims in
  ( passed
  , `Assoc
      ([ "evidence_class", `String "MECHANISM"
       ; "passed", `Bool passed
       ; ( "claims"
         , `List
             (List.map
                (fun c -> `Assoc [ "id", `String c.id; "result", verdict_json c.verdict ])
                claims) )
       ]
       @ context) )
;;
