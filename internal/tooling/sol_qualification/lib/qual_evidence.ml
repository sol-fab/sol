open Qual_domain
open Result.Syntax

type reference =
  { digest : string
  ; size : int
  ; kind : string
  }

type error =
  { stage : string
  ; diagnostic : string
  }

type boundary =
  | Temp_written
  | File_synced
  | Published
  | Directory_synced

type summary =
  { assessment : string
  ; passed : bool
  ; manifest : reference
  }

type t =
  { directory : string
  ; run : run
  ; scope : Yojson.Safe.t
  ; secrets : string list
  ; lock : Unix.file_descr
  ; fault : boundary -> unit
  ; mutable closed : bool
  ; mutable assessment : reference option
  ; mutable failed : error option
  }

let fail stage diagnostic = Error { stage; diagnostic }
let digest r = r.digest
let max_member_size = 1024 * 1024

let field k = function
  | `Assoc xs -> List.assoc_opt k xs
  | _ -> None
;;

let equal_json a b =
  match canonical_json a, canonical_json b with
  | Ok a, Ok b -> a = b
  | _ -> false
;;

let field_is key json expected =
  match field key json with
  | Some actual -> equal_json actual expected
  | None -> false
;;

let string k json =
  match field k json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let run_field run k =
  match string k (run_json run) with
  | Some s -> s
  | None -> ""
;;

let scope_json = function
  | `Assoc xs -> `Assoc (List.remove_assoc "assessment" xs)
  | _ -> `Null
;;

let binding run = scope_json (run_json run)

let reference_json r =
  `Assoc [ "digest", `String r.digest; "size", `Int r.size; "kind", `String r.kind ]
;;

let reference_of_json json =
  match string "digest" json, field "size" json, string "kind" json with
  | Some digest, Some (`Int size), Some kind
    when String.length digest = 64
         && String.for_all
              (function
                | 'a' .. 'f' | '0' .. '9' -> true
                | _ -> false)
              digest
         && size > 0
         && size <= max_member_size
         && List.mem
              kind
              [ "assessment"; "observation"; "diagnostic"; "verdict"; "manifest" ] ->
    Ok { digest; size; kind }
  | _ -> fail "reference" "invalid evidence reference"
;;

let replace text secret =
  let result = Buffer.create (String.length text) in
  let rec loop pos =
    if pos < String.length text
    then
      if
        pos + String.length secret <= String.length text
        && String.sub text pos (String.length secret) = secret
      then (
        Buffer.add_string result "[REDACTED]";
        loop (pos + String.length secret))
      else (
        Buffer.add_char result text.[pos];
        loop (pos + 1))
  in
  loop 0;
  Buffer.contents result
;;

let redact secrets text = List.fold_left replace text secrets

let sensitive key =
  List.mem
    (String.lowercase_ascii key)
    [ "data"
    ; "stringdata"
    ; "env"
    ; "environment"
    ; "password"
    ; "token"
    ; "authorization"
    ; "credentials"
    ]
;;

let rec sanitize secrets = function
  | `String s -> `String (redact secrets s)
  | `List xs -> `List (List.map (sanitize secrets) xs)
  | `Assoc xs ->
    `Assoc
      (List.map
         (fun (k, v) ->
            ( redact secrets k
            , if sensitive k then `String "[REDACTED]" else sanitize secrets v ))
         xs)
  | v -> v
;;

let protect secrets stage fn =
  try fn () with
  | Unix.Unix_error (e, fn, _) ->
    fail stage (redact secrets (fn ^ ": " ^ Unix.error_message e))
  | Sys_error s -> fail stage (redact secrets s)
  | Yojson.Json_error _ -> fail stage "malformed evidence JSON"
;;

let canon json =
  match canonical_json json with
  | Ok s -> Ok s
  | Error e -> fail "encoding" e
;;

let dir path =
  (try Unix.mkdir path 0o700 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let s = Unix.lstat path in
  if s.Unix.st_kind <> Unix.S_DIR || s.st_perm land 0o077 <> 0
  then raise (Sys_error "evidence directory is not private regular directory")
;;

let sync_dir path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
;;

let read_file path =
  let s = Unix.lstat path in
  if
    s.Unix.st_kind <> Unix.S_REG
    || s.st_size > max_member_size
    || s.st_perm land 0o077 <> 0
  then raise (Sys_error "invalid evidence member type, mode or size");
  In_channel.with_open_bin path In_channel.input_all
;;

let member_path directory r =
  Filename.concat (Filename.concat directory "members") r.digest
;;

let load directory r =
  protect [] "integrity" (fun () ->
    let bytes = read_file (member_path directory r) in
    if String.length bytes <> r.size || sha256 bytes <> r.digest
    then fail "integrity" "member digest/length mismatch"
    else (
      let json = Yojson.Safe.from_string bytes in
      if string "kind" json <> Some r.kind
      then fail "integrity" "member kind mismatch"
      else Ok json))
;;

let references json =
  match field "dependencies" json with
  | Some (`List xs) ->
    let rec loop = function
      | [] -> Ok []
      | x :: xs ->
        let* x = reference_of_json x in
        let* xs = loop xs in
        Ok (x :: xs)
    in
    loop xs
  | _ -> fail "integrity" "missing dependency list"
;;

(* Structural receipt validation belongs here, shared by commit and recovery.
   Requirement/subject semantics remain exclusively in the pure evaluator. *)
let validate_receipt directory json deps =
  let invalid message = fail "integrity" message in
  let* () =
    match
      reconcile_keys ~expected:(List.map digest deps) ~actual:(List.map digest deps)
    with
    | Ok () -> Ok ()
    | Error e -> invalid e
  in
  let same_run dep =
    let* child = load directory dep in
    if field_is "run" child (Option.value ~default:`Null (field "run" json))
    then Ok ()
    else invalid "receipt dependency assessment mismatch"
  in
  let rec same_runs = function
    | [] -> Ok ()
    | d :: ds ->
      let* () = same_run d in
      same_runs ds
  in
  let assessments, supports = List.partition (fun r -> r.kind = "assessment") deps in
  let one_assessment () =
    if List.length assessments <> 1
    then invalid "receipt needs exactly one assessment dependency"
    else same_runs deps
  in
  match string "kind" json with
  | Some "assessment" ->
    if supports <> [] then invalid "invalid assessment history dependency" else Ok ()
  | Some "observation" | Some "diagnostic" ->
    let* () = one_assessment () in
    if supports = [] then Ok () else invalid "invalid capture dependency"
  | Some "verdict" ->
    let* () = one_assessment () in
    if supports = [] || List.exists (fun r -> r.kind <> "observation") supports
    then invalid "verdict needs observation dependencies"
    else (
      let payload = Option.value ~default:`Null (field "payload" json) in
      if not (field_is "run" payload (Option.value ~default:`Null (field "run" json)))
      then invalid "verdict payload run mismatch"
      else (
        match
          field "evidence" payload, string "instance" payload, string "decision" payload
        with
        | Some (`List evidence), Some instance, Some decision
          when instance <> ""
               && List.mem decision [ "PASS"; "FAIL"; "UNKNOWN"; "NOT_RUN" ] ->
          let hashes =
            List.filter_map
              (function
                | `String s -> Some s
                | _ -> None)
              evidence
          in
          if List.length hashes <> List.length evidence
          then invalid "invalid verdict evidence"
          else (
            match reconcile_keys ~expected:hashes ~actual:(List.map digest supports) with
            | Ok () -> Ok ()
            | Error _ -> invalid "verdict evidence/dependency mismatch")
        | _ -> invalid "malformed verdict payload"))
  | Some "manifest" ->
    let* () = one_assessment () in
    if List.for_all (fun r -> r.kind = "verdict") supports
    then Ok ()
    else invalid "invalid manifest dependency"
  | _ -> invalid "unknown receipt kind"
;;

let verify_graph directory root =
  let* scope =
    protect [] "integrity" (fun () ->
      Ok (Yojson.Safe.from_string (read_file (Filename.concat directory "binding.json"))))
  in
  let rec visit active visited r =
    if List.mem r.digest active
    then fail "integrity" "cyclic evidence dependency"
    else if List.length visited > 10000
    then fail "integrity" "evidence graph too large"
    else if List.mem r.digest visited
    then Ok visited
    else
      let* json = load directory r in
      if
        field "schema" json <> Some (`Int 1)
        ||
        match field "run" json with
        | Some actual -> not (equal_json (scope_json actual) scope)
        | None -> true
      then fail "integrity" "member schema or candidate/specimen scope mismatch"
      else
        let* deps = references json in
        let* () = validate_receipt directory json deps in
        let rec children visited = function
          | [] -> Ok visited
          | d :: ds ->
            let* visited = visit (r.digest :: active) visited d in
            children visited ds
        in
        let* visited = children visited deps in
        Ok (r.digest :: visited)
  in
  let* _ = visit [] [] root in
  Ok ()
;;

let resync_graph directory root =
  protect [] "durability" (fun () ->
    let rec visit seen r =
      if List.mem r.digest seen
      then Ok seen
      else
        let* json = load directory r in
        let* deps = references json in
        let rec children seen = function
          | [] -> Ok seen
          | d :: ds ->
            let* seen = visit seen d in
            children seen ds
        in
        let* seen = children seen deps in
        let fd =
          Unix.openfile (member_path directory r) [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
        in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
        Ok (r.digest :: seen)
    in
    let* _ = visit [] root in
    sync_dir (Filename.concat directory "members");
    sync_dir directory;
    Ok ())
;;

let assert_open t = if t.closed then fail "session" "recorder is closed" else Ok ()

let publish t ~path bytes =
  protect t.secrets "commit" (fun () ->
    if String.length bytes > max_member_size
    then fail "commit" "capture exceeds bounded member size"
    else (
      let temp, channel =
        Filename.open_temp_file
          ~temp_dir:(Filename.concat t.directory "tmp")
          ~perms:0o600
          "capture-"
          ".tmp"
      in
      Fun.protect
        ~finally:(fun () ->
          close_out_noerr channel;
          try Unix.unlink temp with
          | Unix.Unix_error _ -> ())
        (fun () ->
           output_string channel bytes;
           flush channel;
           t.fault Temp_written;
           Unix.fsync (Unix.descr_of_out_channel channel);
           t.fault File_synced;
           (try Unix.link temp path with
            | Unix.Unix_error (Unix.EEXIST, _, _) ->
              if read_file path <> bytes
              then raise (Sys_error "immutable evidence conflict"));
           t.fault Published;
           sync_dir (Filename.dirname path);
           t.fault Directory_synced;
           Ok ())))
;;

let commit t kind dependencies payload =
  let result =
    let* () = assert_open t in
    let rec verify = function
      | [] -> Ok ()
      | r :: rs ->
        let* () = verify_graph t.directory r in
        verify rs
    in
    let* () = verify dependencies in
    let envelope =
      `Assoc
        [ "schema", `Int 1
        ; "kind", `String kind
        ; "run", run_json t.run
        ; "dependencies", `List (List.map reference_json dependencies)
        ; "payload", sanitize t.secrets payload
        ]
    in
    let* () = validate_receipt t.directory envelope dependencies in
    let* bytes = canon envelope in
    if redact t.secrets bytes <> bytes
    then fail "capture" "registered secret remains in encoded envelope"
    else (
      let reference = { digest = sha256 bytes; size = String.length bytes; kind } in
      let* () = publish t ~path:(member_path t.directory reference) bytes in
      Ok reference)
  in
  (match result with
   | Error e -> t.failed <- Some e
   | Ok _ -> ());
  result
;;

let close t =
  if not t.closed
  then (
    t.closed <- true;
    Unix.close t.lock)
;;

let open_store ?(fault = fun _ -> ()) ~directory ~run ~secrets () =
  if List.exists (( = ) "") secrets
  then fail "open" "empty secret registration"
  else
    protect secrets "open" (fun () ->
      let fresh = not (Sys.file_exists directory) in
      dir directory;
      let lock =
        Unix.openfile
          (Filename.concat directory ".writer.lock")
          [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ]
          0o600
      in
      let acquired = ref false in
      try
        if not (Qual_lock_raw.try_lock lock)
        then (
          Unix.close lock;
          fail "open" "attempt already has a writer")
        else (
          acquired := true;
          dir (Filename.concat directory "members");
          dir (Filename.concat directory "tmp");
          let t =
            { directory
            ; run
            ; scope = binding run
            ; secrets =
                List.sort
                  (fun a b -> Int.compare (String.length b) (String.length a))
                  secrets
            ; lock
            ; fault
            ; closed = false
            ; assessment = None
            ; failed = None
            }
          in
          let* bytes = canon t.scope in
          if redact secrets bytes <> bytes
          then (
            close t;
            fail "open" "secret appears in binding")
          else (
            let path = Filename.concat directory "binding.json" in
            if (not fresh) && not (Sys.file_exists path)
            then (
              close t;
              fail "open" "existing directory has no committed binding")
            else (
              match publish t ~path bytes with
              | Error e ->
                close t;
                Error e
              | Ok () ->
                sync_dir directory;
                sync_dir (Filename.dirname directory);
                Ok t)))
      with
      | exn ->
        if !acquired then Unix.close lock;
        raise exn)
;;

let members t kind =
  protect t.secrets "scan" (fun () ->
    let rec scan acc = function
      | [] -> Ok (List.rev acc)
      | file :: rest ->
        let path = Filename.concat (Filename.concat t.directory "members") file in
        let bytes = read_file path in
        let json = Yojson.Safe.from_string bytes in
        let* r =
          reference_of_json
            (`Assoc
                [ "digest", `String file
                ; "size", `Int (String.length bytes)
                ; ( "kind"
                  , match field "kind" json with
                    | Some k -> k
                    | None -> `Null )
                ])
        in
        let* () = verify_graph t.directory r in
        let acc = if r.kind = kind then (r, json) :: acc else acc in
        scan acc rest
    in
    scan
      []
      (Array.to_list (Sys.readdir (Filename.concat t.directory "members"))
       |> List.sort String.compare))
;;

let assessments t =
  let* () = assert_open t in
  let* xs = members t "assessment" in
  Ok (List.map fst xs)
;;

let same_assessment t json = field_is "run" json (run_json t.run)

let start_assessment t ~reason ~previous =
  let* () = assert_open t in
  if String.trim reason = ""
  then fail "assessment" "reassessment needs explicit reason"
  else
    let* xs = members t "assessment" in
    let current, others = List.partition (fun (_, j) -> same_assessment t j) xs in
    let* () =
      match
        reconcile_keys
          ~expected:(List.map (fun (r, _) -> r.digest) others)
          ~actual:(List.map digest previous)
      with
      | Ok () -> Ok ()
      | Error s -> fail "assessment" s
    in
    let previous = List.sort (fun a b -> String.compare a.digest b.digest) previous in
    let payload = sanitize t.secrets (`Assoc [ "reason", `String reason ]) in
    if
      List.length current > 1
      || List.exists
           (fun (_, j) ->
              (not (field_is "payload" j payload))
              || not
                   (field_is "dependencies" j (`List (List.map reference_json previous))))
           current
    then fail "assessment" "conflicting assessment definition"
    else
      let* r = commit t "assessment" previous payload in
      t.assessment <- Some r;
      Ok r
;;

let active t =
  let* () = assert_open t in
  match t.assessment with
  | Some r -> Ok r
  | None -> fail "assessment" "explicit assessment selection required"
;;

let capture t ~subject ~payload =
  let* a = active t in
  if String.trim subject = ""
  then fail "capture" "missing observation subject"
  else
    commit t "observation" [ a ] (`Assoc [ "subject", `String subject; "facts", payload ])
;;

let diagnostic t text =
  let* a = active t in
  commit t "diagnostic" [ a ] (`String text)
;;

let record_verdict t verdict ~observations =
  let* a = active t in
  let json = verdict_json verdict in
  if not (field_is "run" json (run_json t.run))
  then fail "verdict" "verdict belongs to another run"
  else
    let* existing = members t "verdict" in
    let conflict =
      List.exists
        (fun (_, j) ->
           same_assessment t j
           &&
           match field "payload" j with
           | Some p ->
             field "instance" p = field "instance" json
             && not (equal_json p (sanitize t.secrets json))
           | None -> false)
        existing
    in
    if conflict
    then fail "verdict" "conflicting outcome in assessment"
    else commit t "verdict" (a :: observations) json
;;

let verdicts_for t refs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | r :: rs ->
      let* () = verify_graph t.directory r in
      let* j = load t.directory r in
      if r.kind <> "verdict" || not (same_assessment t j)
      then fail "manifest" "wrong verdict provenance"
      else (
        match field "payload" j with
        | Some p -> loop (p :: acc) rs
        | None -> fail "manifest" "missing verdict")
  in
  loop [] refs
;;

let seal t ~obligations ~requests ~verdicts =
  let* a = active t in
  let* () =
    match t.failed with
    | None -> Ok ()
    | Some _ ->
      fail "manifest" "capture failed in this session; no successful seal permitted"
  in
  let* () =
    match reconcile_plan obligations requests with
    | Ok () -> Ok ()
    | Error e -> fail "coverage" e
  in
  let* bodies = verdicts_for t verdicts in
  let keys = List.filter_map (string "instance") bodies in
  let* () =
    match
      reconcile_keys
        ~expected:(List.map instance_key (instances obligations))
        ~actual:keys
    with
    | Ok () -> Ok ()
    | Error e -> fail "coverage" e
  in
  if not (field_is "run" (obligations_json obligations) (run_json t.run))
  then fail "coverage" "wrong obligation run"
  else
    let* all = members t "verdict" in
    let actual =
      List.filter (fun (_, j) -> same_assessment t j) all
      |> List.map (fun (r, _) -> r.digest)
    in
    let* () =
      match reconcile_keys ~expected:actual ~actual:(List.map digest verdicts) with
      | Ok () -> Ok ()
      | Error e -> fail "coverage" e
    in
    let passed = List.for_all (fun j -> string "decision" j = Some "PASS") bodies in
    commit
      t
      "manifest"
      (a :: verdicts)
      (`Assoc [ "obligations", obligations_json obligations; "passed", `Bool passed ])
;;

let verify_manifest ~directory ~run ~obligations reference =
  protect [] "verify" (fun () ->
    let* binding_bytes = canon (binding run) in
    if read_file (Filename.concat directory "binding.json") <> binding_bytes
    then fail "verify" "attempt/candidate/specimen binding mismatch"
    else
      let* () = verify_graph directory reference in
      let* json = load directory reference in
      if reference.kind <> "manifest" || not (field_is "run" json (run_json run))
      then fail "verify" "explicit assessment/manifest mismatch"
      else
        let* deps = references json in
        let rec bodies acc = function
          | [] -> Ok acc
          | r :: rs ->
            let* j = load directory r in
            if not (field_is "run" j (run_json run))
            then fail "verify" "dependency assessment mismatch"
            else if r.kind = "verdict"
            then (
              match field "payload" j with
              | Some p -> bodies (p :: acc) rs
              | None -> fail "verify" "missing verdict")
            else if r.kind = "assessment"
            then bodies acc rs
            else fail "verify" "invalid manifest dependency"
        in
        let* bodies = bodies [] deps in
        let payload =
          match field "payload" json with
          | Some p -> p
          | None -> `Null
        in
        let policy =
          match field "obligations" payload with
          | Some p -> p
          | None -> `Null
        in
        let* () =
          if equal_json policy (obligations_json obligations)
          then Ok ()
          else
            fail
              "verify"
              "sealed obligations disagree with independently bound policy/selection"
        in
        let expected =
          match field "required" policy with
          | Some (`List xs) ->
            List.filter_map
              (function
                | `String s -> Some s
                | _ -> None)
              xs
          | _ -> []
        in
        let* () =
          if expected = [] || not (field_is "run" policy (run_json run))
          then fail "verify" "missing/misbound obligation set"
          else (
            match
              reconcile_keys
                ~expected
                ~actual:(List.filter_map (string "instance") bodies)
            with
            | Ok () -> Ok ()
            | Error e -> fail "verify" e)
        in
        let passed = List.for_all (fun j -> string "decision" j = Some "PASS") bodies in
        if field "passed" payload <> Some (`Bool passed)
        then fail "verify" "manifest status disagrees with decisions"
        else
          let* () = resync_graph directory reference in
          Ok { assessment = run_field run "assessment"; passed; manifest = reference })
;;

type captured =
  { run : Qual_domain.run
  ; subject : string
  ; payload : Yojson.Safe.t
  ; reference : reference
  }

let read_capture ~directory ~run reference =
  let* () = verify_graph directory reference in
  let* json = load directory reference in
  if reference.kind <> "observation" || not (field_is "run" json (run_json run))
  then fail "read" "observation storage context mismatch"
  else (
    match field "payload" json with
    | Some payload ->
      (match string "subject" payload, field "facts" payload with
       | Some subject, Some payload ->
         let* () = resync_graph directory reference in
         Ok { run; subject; payload; reference }
       | _ -> fail "read" "malformed observation envelope")
    | None -> fail "read" "missing observation payload")
;;
