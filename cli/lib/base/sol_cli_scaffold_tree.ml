open Result.Syntax

type rule =
  | Write
  | Skip_if_exists
  | Patch_modules of string

let kinds =
  [ "workspace"; "svc"; "worker"; "fn"; "event"; "svc-ts"; "worker-ts"; "fn-ts" ]
;;

let dir_of ~root ~kind = Filename.concat root kind

let plan ~root ~kind =
  let base = dir_of ~root ~kind in
  let rec walk rel acc =
    match Sys.readdir (Filename.concat base rel) with
    | exception Sys_error message ->
      Error (Printf.sprintf "no %s templates under %s: %s" kind root message)
    | entries ->
      Array.sort String.compare entries;
      let rec iter acc index =
        if index >= Array.length entries
        then Ok acc
        else (
          let entry = entries.(index) in
          let rel' = if rel = "" then entry else Filename.concat rel entry in
          if Sys.is_directory (Filename.concat base rel')
          then
            let* acc = walk rel' acc in
            iter acc (index + 1)
          else iter (rel' :: acc) (index + 1))
      in
      iter acc 0
  in
  walk "" [] |> Result.map (List.sort String.compare)
;;

let text ~root ~kind ~rel =
  let path = Filename.concat (dir_of ~root ~kind) rel in
  Sol_cli_fs.read_file path
  |> Result.map_error (fun message -> Printf.sprintf "could not read %s: %s" path message)
;;

let patch_modules_stanza path new_mod =
  let ic = open_in path in
  let content = In_channel.input_all ic in
  close_in ic;
  let prefix = "(modules " in
  let plen = String.length prefix in
  let clen = String.length content in
  let rec find_prefix i =
    if i > clen - plen
    then None
    else if String.sub content i plen = prefix
    then Some (i + plen)
    else find_prefix (i + 1)
  in
  match find_prefix 0 with
  | None ->
    Sol_cli_report.app
      "  note: could not locate (modules ...) in %s — add %s manually"
      path
      new_mod
  | Some pos ->
    let rec find_close i depth =
      if i >= clen
      then clen
      else (
        match content.[i] with
        | '(' -> find_close (i + 1) (depth + 1)
        | ')' -> if depth = 0 then i else find_close (i + 1) (depth - 1)
        | _ -> find_close (i + 1) depth)
    in
    let close = find_close pos 0 in
    let updated =
      String.sub content 0 close ^ " " ^ new_mod ^ String.sub content close (clen - close)
    in
    let oc = open_out path in
    output_string oc updated;
    close_out oc;
    Sol_cli_report.app "  updated  %s" path
;;

let copy ~root ~kind ~dest ~vars ~rule =
  let* rels = plan ~root ~kind in
  let rec iter written = function
    | [] -> Ok (List.rev written)
    | rel :: rest ->
      let v = vars rel in
      let target = Filename.concat dest (Sol_cli_scaffold.subst v rel) in
      (match rule rel with
       | Skip_if_exists when Sys.file_exists target -> iter written rest
       | Patch_modules module_ when Sys.file_exists target ->
         patch_modules_stanza target module_;
         iter (target :: written) rest
       | Write | Skip_if_exists | Patch_modules _ ->
         let* content = text ~root ~kind ~rel in
         let* () =
           Sol_cli_scaffold.write_file
             ~path:target
             ~content:(Sol_cli_scaffold.subst v content)
         in
         iter (target :: written) rest)
  in
  iter [] rels
;;
