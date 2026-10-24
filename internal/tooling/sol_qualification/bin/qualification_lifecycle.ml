(* Print the typed qualification assessment for one attempt directory.

   The live shell row consumes this instead of re-deriving phase eligibility from
   the append-only ledger. A malformed history is a refusal, not an empty pass. *)

let arg name =
  let rec loop = function
    | flag :: value :: _ when flag = name -> Some value
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop (List.tl (Array.to_list Sys.argv))
;;

let () =
  match arg "--attempt-dir" with
  | None ->
    prerr_endline "usage: qualification_lifecycle --attempt-dir DIR";
    exit 2
  | Some directory ->
    (match Qual_lifecycle.of_dir directory with
     | Error message ->
       prerr_endline ("qualification_lifecycle: " ^ message);
       exit 2
     | Ok attempt ->
       let assessment = Qual_lifecycle.assess attempt in
       print_endline
         (Yojson.Safe.to_string (Qual_lifecycle.assessment_to_yojson assessment)))
;;
