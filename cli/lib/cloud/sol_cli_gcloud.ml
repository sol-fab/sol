type reason =
  | Not_found
  | Other

let names_after ~marker text =
  let marker_length = String.length marker in
  let text_length = String.length text in
  let is_name_char c =
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
  in
  let rec scan i acc =
    if i + marker_length > text_length
    then acc
    else if String.sub text i marker_length = marker
    then (
      let start = i + marker_length in
      let rec take j =
        if j < text_length && is_name_char text.[j] then take (j + 1) else j
      in
      let stop = take start in
      let name = String.sub text start (stop - start) in
      scan (max (i + 1) stop) (if name = "" then acc else name :: acc))
    else scan (i + 1) acc
  in
  List.rev (scan 0 [])
;;

let mentioned_projects stderr =
  let text = String.lowercase_ascii stderr in
  names_after ~marker:"projects/" text @ names_after ~marker:"project '" text
;;

let not_found_wording =
  [ "code=404"; "httperror 404"; "not_found"; "not found"; "does not exist" ]
;;

let says_not_found ?project text =
  let lowered = String.lowercase_ascii text in
  let absent_wording =
    List.exists (fun needle -> Sol_cli_string.contains ~needle lowered) not_found_wording
  in
  let subject_matches =
    match project with
    | None -> true
    | Some project ->
      let project = String.lowercase_ascii project in
      let mentions = mentioned_projects text in
      (* gcloud often names the project by number in a Secret Manager NOT_FOUND,
         while the command was scoped with the project ID. The numeric mention is
         the same scope the CLI resolved; a named project ID must still match. *)
      let numeric value =
        value <> "" && String.for_all (fun c -> c >= '0' && c <= '9') value
      in
      List.for_all (fun mentioned -> mentioned = project || numeric mentioned) mentions
  in
  absent_wording && subject_matches
;;

let classify ?project = function
  | Sol_cli_process.Non_zero { stderr; stdout; _ } ->
    if says_not_found ?project (stderr ^ "\n" ^ stdout) then Not_found else Other
  | Sol_cli_process.Spawn_failed _ | Sol_cli_process.Timeout _ -> Other
;;
