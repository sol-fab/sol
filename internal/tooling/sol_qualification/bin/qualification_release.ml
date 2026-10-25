(* Thin JSON adapter over Qual_release.

   The executable is an effects boundary only: it reads the repository-owned
   contract and the two evidence directories, computes its own binary identity,
   invokes the pure evaluator and prints the typed verdict. It accepts no
   --contract argument, so a caller cannot substitute a weaker attached contract.

   Exit codes: 0 PASS, 1 REFUSED, 2 input/usage error. *)

let usage =
  "usage:\n\
  \  qualification_release contract --repository DIR [--out FILE]\n\
  \  qualification_release evaluate --repository DIR \\\n\
  \    --aws-record FILE --aws-evidence DIR --gcp-record FILE --gcp-evidence DIR \\\n\
  \    [--out FILE]"
;;

let die message =
  prerr_endline ("qualification_release: " ^ message);
  exit 2
;;

let arguments () =
  let arguments = List.tl (Array.to_list Sys.argv) in
  match arguments with
  | command :: rest -> command, rest
  | [] -> die usage
;;

let flags arguments =
  let rec loop values = function
    | [] -> Ok (List.rev values)
    | flag :: value :: rest
      when String.length flag > 2 && flag.[0] = '-' && flag.[1] = '-' ->
      if String.length value > 1 && value.[0] = '-' && value.[1] = '-'
      then Error (Printf.sprintf "option %s needs a value" flag)
      else loop ((flag, value) :: values) rest
    | flag :: _ -> Error (Printf.sprintf "unexpected argument %S" flag)
  in
  loop [] arguments
;;

let required option values =
  match List.assoc_opt option values with
  | Some value -> value
  | None -> die (Printf.sprintf "missing %s\n%s" option usage)
;;

let optional option values = List.assoc_opt option values

let known options values =
  List.iter
    (fun (option, _) ->
       if not (List.mem option options)
       then die (Printf.sprintf "unknown option %s\n%s" option usage))
    values
;;

let read_bytes path =
  try In_channel.with_open_bin path In_channel.input_all with
  | Sys_error message -> die message
;;

let binary_identity () =
  let revision = Qual_release.evaluator_revision in
  let binary_sha256 = Qual_domain.sha256 (read_bytes Sys.executable_name) in
  match Qual_release.evaluator ~revision ~binary_sha256 with
  | Ok evaluator -> evaluator
  | Error error -> die (error.stage ^ ": " ^ error.diagnostic)
;;

let emit optional_path json =
  let text = Yojson.Safe.pretty_to_string json ^ "\n" in
  match optional_path with
  | None -> print_string text
  | Some path ->
    (try Out_channel.with_open_bin path (fun channel -> output_string channel text) with
     | Sys_error message -> die message)
;;

let error_message error = error.Qual_release.stage ^ ": " ^ error.diagnostic

let main () =
  let command, arguments = arguments () in
  let values =
    match flags arguments with
    | Ok values -> values
    | Error message -> die message
  in
  match command with
  | "contract" ->
    known [ "--repository"; "--out" ] values;
    let repository = required "--repository" values in
    (match Qual_release.load_contract ~repository with
     | Error error -> die (error_message error)
     | Ok contract ->
       emit
         (optional "--out" values)
         (`Assoc
             [ "contract", Qual_release.contract_to_yojson contract
             ; "id", `String (Qual_release.contract_id contract)
             ; "digest", `String (Qual_release.contract_digest contract)
             ]))
  | "evaluate" ->
    known
      [ "--repository"
      ; "--aws-record"
      ; "--aws-evidence"
      ; "--gcp-record"
      ; "--gcp-evidence"
      ; "--out"
      ]
      values;
    let repository = required "--repository" values in
    let aws_record = required "--aws-record" values in
    let aws_evidence = required "--aws-evidence" values in
    let gcp_record = required "--gcp-record" values in
    let gcp_evidence = required "--gcp-evidence" values in
    let evaluator = binary_identity () in
    (match Qual_release.load_contract ~repository with
     | Error error -> die (error_message error)
     | Ok contract ->
       let load record directory =
         match Qual_release.load_record ~contract ~directory ~path:record with
         | Ok value -> Ok value
         | Error error -> Error (error_message error)
       in
       (match load aws_record aws_evidence, load gcp_record gcp_evidence with
        | Error message, _ | _, Error message -> die message
        | Ok aws, Ok gcp ->
          let verdict = Qual_release.evaluate ~evaluator contract aws gcp in
          emit (optional "--out" values) (Qual_release.verdict_to_yojson verdict);
          (match verdict with
           | Qual_release.Pass _ -> ()
           | Qual_release.Refused _ -> exit 1)))
  | other -> die (Printf.sprintf "unknown command %S\n%s" other usage)
;;

let () = main ()
