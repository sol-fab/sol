module D = Qual_domain
module E = Qual_evidence

let domain = function
  | Ok x -> x
  | Error e -> Alcotest.fail e
;;

let get = function
  | Ok x -> x
  | Error (e : E.error) -> Alcotest.fail (e.stage ^ ": " ^ e.diagnostic)
;;

let rejects = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unsafe result accepted"
;;

let kubernetes : Qual_domain.kube_target =
  { principal = "fixture-reader"
  ; cluster = "fixture-cluster"
  ; endpoint = "https://fixture.invalid"
  }
;;

(* Synthetic facts for domain/recorder mechanics, not observer agreement fixtures. *)
let synthetic_ca run instance workload : Qual_domain.ca_facts =
  let open Qual_domain in
  let context =
    { target = kubernetes
    ; verified_at = 0
    ; started_at = 1
    ; finished_at = 2
    ; expires_at = Some 300
    }
  in
  let wrap state =
    { requirement = instance_identity instance
    ; subject =
        (match String.split_on_char '/' (instance_key instance) |> List.rev with
         | x :: _ -> x
         | [] -> assert false)
    ; context
    ; state = Present state
    }
  in
  ignore run;
  { deployment =
      wrap
        { namespace = "apps"
        ; name = workload
        ; uid = "deployment-uid"
        ; resource_version = "1"
        ; volumes =
            [ { volume_name = "ca-volume"
              ; source_configmap = Some "declared-ledger-ca"
              ; items = None
              }
            ]
        ; containers =
            [ { container_name = "app"
              ; mounts =
                  [ { volume_name = "ca-volume"
                    ; path = "/etc/sol/db-ca"
                    ; sub_path = None
                    ; sub_path_expr = None
                    }
                  ]
              }
            ]
        }
  ; configmap =
      wrap
        { namespace = "apps"
        ; name = "declared-ledger-ca"
        ; uid = "configmap-uid"
        ; resource_version = "2"
        ; entries = [ "ca.pem", true ]
        }
  }
;;

(* Mechanism-only happy facts; hostile Job fixtures exercise the real decoder separately. *)
let synthetic_migration run instance =
  let open Qual_domain in
  let ca = synthetic_ca run instance "execution-job" in
  let template =
    match ca.deployment.state with
    | Present x -> x
    | _ -> assert false
  in
  let namespace = "database-system" in
  let job =
    { template with
      namespace
    ; containers =
        List.map (fun c -> { c with container_name = "migrate" }) template.containers
    }
  in
  let configmap =
    match ca.configmap.state with
    | Present x -> x
    | _ -> assert false
  in
  { execution =
      { requirement = instance_identity instance
      ; subject = "ledger"
      ; context = { ca.deployment.context with started_at = 0; finished_at = 0 }
      ; state = Present { namespace; name = job.name; uid = job.uid }
      }
  ; job = { ca.deployment with state = Present job }
  ; configmap = { ca.configmap with state = Present { configmap with namespace } }
  }
;;

let contract =
  `Assoc
    [ "schema", `Int 1
    ; "ca_key", `String "ca.pem"
    ; "ca_path", `String "/etc/sol/db-ca/ca.pem"
    ; "credential_key", `String "POSTGRES_URL"
    ; "dml_class", `String "dml"
    ; "capabilities", `List [ `String "ca"; `String "dml"; `String "tls" ]
    ]
;;

let run
      ?(assessment = "a1")
      ?(specimen = "fixture-cluster")
      ?(candidate = String.make 40 'a')
      ()
  =
  D.Fixture.bind
    ~kubernetes
    ~scenario:D.Aws
    ~attempt:"fixture-attempt"
    ~assessment
    ~candidate_revision:candidate
    ~specimen
    ~contract
  |> domain
;;

let obligations run =
  let intent = D.Fixture.intent (Yojson.Safe.from_file "intent.json") |> domain in
  let selected = D.select run intent |> domain in
  D.bind_obligations run D.Aws selected |> domain
;;

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun p -> remove (Filename.concat path p)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let temp fn =
  let parent = Filename.temp_file "sol-qual-evidence-" ".test" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  Fun.protect
    ~finally:(fun () -> remove parent)
    (fun () -> fn (Filename.concat parent "evidence"))
;;

let open_store ?fault ?(secrets = []) directory run =
  E.open_store ?fault ~directory ~run ~secrets () |> get
;;

let begin_run t =
  E.start_assessment
    ~required_captures:[]
    t
    ~reason:"initial offline fixture"
    ~previous:[]
  |> get
;;

let subject i = List.rev (String.split_on_char '/' (D.instance_key i)) |> List.hd

let decide run request evidence =
  let i = D.requested request in
  let workload = subject i in
  let obs facts =
    D.Fixture.observe
      run
      ~subject:workload
      ~evidence:[ E.digest evidence ]
      (D.Present facts)
    |> domain
  in
  match request with
  | D.Ca_delivery r -> D.evaluate (D.Ca_checked (r, obs (synthetic_ca run i workload)))
  | D.Dml_delivery r ->
    D.evaluate
      (D.Dml_checked
         ( r
         , obs
             D.
               { namespace = "apps"
               ; workload
               ; credential_class = "dml"
               ; key = "POSTGRES_URL"
               ; nonempty = true
               } ))
  | D.No_master_copy r ->
    D.evaluate
      (D.No_master_checked (r, obs D.{ namespace = "apps"; workload; references = [] }))
  | D.Tls_connectivity r ->
    D.evaluate
      (D.Tls_checked (r, obs D.{ namespace = "apps"; workload; verified = true }))
  | D.Migration_ca_delivery r ->
    D.evaluate (D.Migration_ca_checked (r, obs (synthetic_migration run i)))
  | D.Migration_input r ->
    D.evaluate
      (D.Migration_checked
         (r, obs D.{ database = "ledger"; key = "POSTGRES_URL"; nonempty = true }))
;;

let record_all ?selected t run =
  let o =
    match selected with
    | None -> obligations run
    | Some o -> o
  in
  let requests = List.map D.plan (D.instances o) in
  let verdicts =
    List.map
      (fun request ->
         let evidence =
           E.capture
             t
             ~subject:(subject (D.requested request))
             ~payload:
               (`Assoc
                   [ "fixture", `String "explicit synthetic fixture"
                   ; "request", `String (D.instance_identity (D.requested request))
                   ])
           |> get
         in
         E.record_verdict t (decide run request evidence) ~observations:[ evidence ]
         |> get)
      requests
  in
  o, requests, verdicts
;;

let seal_all t run =
  let o, requests, verdicts = record_all t run in
  E.seal ~captures:[] t ~obligations:o ~requests ~verdicts |> get
;;

let test_restart () =
  temp (fun directory ->
    let run = run () in
    let t = open_store directory run in
    ignore (begin_run t);
    let request = List.hd (D.instances (obligations run)) |> D.plan in
    let observation =
      E.capture
        t
        ~subject:(subject (D.requested request))
        ~payload:(`String "observed before crash")
      |> get
    in
    E.close t;
    let t = open_store directory run in
    ignore (begin_run t);
    let captured = E.read_capture ~directory ~run observation |> get in
    Alcotest.(check string)
      "persisted subject"
      (subject (D.requested request))
      captured.subject;
    Alcotest.(check bool)
      "persisted facts"
      true
      (captured.payload = `String "observed before crash");
    rejects
      (E.read_capture
         ~directory
         ~run:
           (D.Fixture.bind
              ~kubernetes
              ~scenario:D.Aws
              ~attempt:"fixture-attempt"
              ~assessment:"foreign"
              ~candidate_revision:(String.make 40 'a')
              ~specimen:"fixture-cluster"
              ~contract
            |> domain)
         observation);
    (* An observation alone is not a verdict; do not invent one on continuation. *)
    rejects
      (E.seal
         ~captures:[]
         t
         ~obligations:(obligations run)
         ~requests:(List.map D.plan (D.instances (obligations run)))
         ~verdicts:[]);
    let v =
      E.record_verdict t (decide run request observation) ~observations:[ observation ]
      |> get
    in
    E.close t;
    let t = open_store directory run in
    ignore (begin_run t);
    rejects
      (E.seal
         ~captures:[]
         t
         ~obligations:(obligations run)
         ~requests:(List.map D.plan (D.instances (obligations run)))
         ~verdicts:[ v ]);
    (* Existing identical committed verdict is idempotent, never overwritten. *)
    let v2 =
      E.record_verdict t (decide run request observation) ~observations:[ observation ]
      |> get
    in
    Alcotest.(check string) "immutable existing receipt" (E.digest v) (E.digest v2);
    E.close t)
;;

let test_manifest () =
  temp (fun directory ->
    let run = run () in
    let t = open_store directory run in
    ignore (begin_run t);
    let o, requests, verdicts = record_all t run in
    rejects (E.seal ~captures:[] t ~obligations:o ~requests ~verdicts:(List.tl verdicts));
    rejects (E.seal ~captures:[] t ~obligations:o ~requests:(List.tl requests) ~verdicts);
    let manifest = E.seal ~captures:[] t ~obligations:o ~requests ~verdicts |> get in
    E.close t;
    let summary =
      E.verify_manifest
        ~required_captures:[]
        ~directory
        ~run
        ~obligations:(obligations run)
        manifest
      |> get
    in
    Alcotest.(check bool) "verified mechanism pass" true summary.passed;
    let foreign =
      D.Fixture.bind
        ~kubernetes
        ~scenario:D.Aws
        ~attempt:"fixture-attempt"
        ~assessment:"a2"
        ~candidate_revision:(String.make 40 'a')
        ~specimen:"fixture-cluster"
        ~contract
      |> domain
    in
    rejects
      (E.verify_manifest
         ~required_captures:[]
         ~directory
         ~run:foreign
         ~obligations:(obligations foreign)
         manifest))
;;

let test_reassessment () =
  temp (fun directory ->
    let first = run () in
    let t = open_store directory first in
    let a1 = begin_run t in
    let passed = seal_all t first in
    E.close t;
    let second = run ~assessment:"a2" () in
    let t = open_store directory second in
    rejects (E.start_assessment ~required_captures:[] t ~reason:"" ~previous:[ a1 ]);
    rejects
      (E.start_assessment ~required_captures:[] t ~reason:"new attempt" ~previous:[]);
    ignore
      (E.start_assessment
         ~required_captures:[]
         t
         ~reason:"new assessment preserves earlier proof"
         ~previous:[ a1 ]
       |> get);
    let o = obligations second in
    let requests = List.map D.plan (D.instances o) in
    let verdicts =
      List.map
        (fun request ->
           let i = D.requested request in
           let e =
             E.capture t ~subject:(subject i) ~payload:(`String "Forbidden") |> get
           in
           let v =
             D.Fixture.blocked i ~evidence:[ E.digest e ] "identity unreadable" |> domain
           in
           E.record_verdict t v ~observations:[ e ] |> get)
        requests
    in
    let failed = E.seal ~captures:[] t ~obligations:o ~requests ~verdicts |> get in
    E.close t;
    rejects
      (E.verify_manifest
         ~required_captures:[]
         ~directory
         ~run:second
         ~obligations:(obligations second)
         passed);
    Alcotest.(check bool)
      "explicit failed assessment"
      false
      (E.verify_manifest
         ~required_captures:[]
         ~directory
         ~run:second
         ~obligations:(obligations second)
         failed
       |> get)
        .passed;
    Alcotest.(check bool)
      "historical pass preserved, never selected as current"
      true
      (E.verify_manifest
         ~required_captures:[]
         ~directory
         ~run:first
         ~obligations:(obligations first)
         passed
       |> get)
        .passed)
;;

let test_conflicts () =
  temp (fun directory ->
    let run = run () in
    let t = open_store directory run in
    ignore (begin_run t);
    rejects
      (E.start_assessment
         ~required_captures:[]
         t
         ~reason:"silently replace assessment"
         ~previous:[]);
    let request = List.hd (D.instances (obligations run)) |> D.plan in
    let i = D.requested request in
    let e = E.capture t ~subject:(subject i) ~payload:(`String "first read") |> get in
    ignore (E.record_verdict t (decide run request e) ~observations:[ e ] |> get);
    let blocked =
      D.Fixture.blocked i ~evidence:[ E.digest e ] "later failure" |> domain
    in
    rejects (E.record_verdict t blocked ~observations:[ e ]);
    rejects (E.open_store ~directory ~run ~secrets:[] ());
    E.close t)
;;

let test_corruption () =
  List.iter
    (fun delete ->
       temp (fun directory ->
         let run = run () in
         let t = open_store directory run in
         ignore (begin_run t);
         let o, requests, verdicts = record_all t run in
         let manifest = E.seal ~captures:[] t ~obligations:o ~requests ~verdicts |> get in
         E.close t;
         let path =
           Filename.concat
             (Filename.concat directory "members")
             (E.digest (List.hd verdicts))
         in
         if delete
         then Unix.unlink path
         else Out_channel.with_open_bin path (fun c -> output_string c "corrupt");
         rejects
           (E.verify_manifest
              ~required_captures:[]
              ~directory
              ~run
              ~obligations:(obligations run)
              manifest);
         let t = open_store directory run in
         rejects
           (E.start_assessment
              ~required_captures:[]
              t
              ~reason:"initial offline fixture"
              ~previous:[]);
         E.close t))
    [ false; true ]
;;

let test_wrong_binding () =
  temp (fun directory ->
    let r = run () in
    let t = open_store directory r in
    ignore (begin_run t);
    let manifest = seal_all t r in
    E.close t;
    List.iter
      (fun foreign ->
         rejects (E.open_store ~directory ~run:foreign ~secrets:[] ());
         rejects
           (E.verify_manifest
              ~required_captures:[]
              ~directory
              ~run:foreign
              ~obligations:(obligations foreign)
              manifest))
      [ run ~candidate:(String.make 40 'b') (); run ~specimen:"different" () ])
;;

let test_complete_unsealed_restart () =
  temp (fun directory ->
    let r = run () in
    let t = open_store directory r in
    ignore (begin_run t);
    let o, requests, verdicts = record_all t r in
    E.close t;
    let t = open_store directory r in
    ignore (begin_run t);
    let manifest = E.seal ~captures:[] t ~obligations:o ~requests ~verdicts |> get in
    E.close t;
    Alcotest.(check bool)
      "complete decisions require explicit finalization"
      true
      (E.verify_manifest
         ~required_captures:[]
         ~directory
         ~run:r
         ~obligations:(obligations r)
         manifest
       |> get)
        .passed)
;;

let test_transitive_corruption () =
  temp (fun directory ->
    let r = run () in
    let t = open_store directory r in
    ignore (begin_run t);
    let o, requests, verdicts = record_all t r in
    let verdict_file =
      Filename.concat (Filename.concat directory "members") (E.digest (List.hd verdicts))
    in
    let json = Yojson.Safe.from_file verdict_file in
    let deps = Yojson.Safe.Util.(member "dependencies" json |> to_list) in
    let dep =
      List.find (fun j -> Yojson.Safe.Util.member "kind" j = `String "observation") deps
      |> E.reference_of_json
      |> get
    in
    let path = Filename.concat (Filename.concat directory "members") (E.digest dep) in
    Out_channel.with_open_bin path (fun c -> output_string c "corrupt observation");
    rejects (E.seal ~captures:[] t ~obligations:o ~requests ~verdicts);
    E.close t)
;;

let child_failed_expected pid =
  match Unix.waitpid [] pid with
  | _, Unix.WEXITED 97 -> ()
  | _ -> Alcotest.fail "fault did not kill child at boundary"
;;

let test_crashes () =
  List.iter
    (fun boundary ->
       List.iter
         (fun manifest_target ->
            temp (fun directory ->
              let r = run () in
              let t = open_store directory r in
              ignore (begin_run t);
              let o, requests, verdicts =
                if manifest_target then record_all t r else obligations r, [], []
              in
              E.close t;
              let pid = Unix.fork () in
              if pid = 0
              then (
                try
                  let armed = ref false in
                  let fault at = if !armed && at = boundary then Unix._exit 97 in
                  let t = open_store ~fault directory r in
                  ignore (begin_run t);
                  armed := true;
                  if manifest_target
                  then ignore (E.seal ~captures:[] t ~obligations:o ~requests ~verdicts)
                  else
                    ignore
                      (E.capture t ~subject:"w1" ~payload:(`String "partial capture"));
                  Unix._exit 96
                with
                | _ -> Unix._exit 95)
              else (
                child_failed_expected pid;
                let t = open_store directory r in
                ignore (begin_run t);
                if not manifest_target
                then
                  rejects
                    (E.seal
                       ~captures:[]
                       t
                       ~obligations:o
                       ~requests:(List.map D.plan (D.instances o))
                       ~verdicts:[]);
                E.close t;
                (* Only an explicitly selected, fully validated published manifest can recover. *)
                Array.iter
                  (fun name ->
                     let path =
                       Filename.concat (Filename.concat directory "members") name
                     in
                     let bytes = In_channel.with_open_bin path In_channel.input_all in
                     let json = Yojson.Safe.from_string bytes in
                     if Yojson.Safe.Util.member "kind" json = `String "manifest"
                     then (
                       let ref_json =
                         `Assoc
                           [ "digest", `String name
                           ; "size", `Int (String.length bytes)
                           ; "kind", `String "manifest"
                           ]
                       in
                       let reference = E.reference_of_json ref_json |> get in
                       Alcotest.(check bool)
                         "recovered manifest closure verified"
                         true
                         (E.verify_manifest
                            ~required_captures:[]
                            ~directory
                            ~run:r
                            ~obligations:(obligations r)
                            reference
                          |> get)
                           .passed))
                  (Sys.readdir (Filename.concat directory "members")))))
         [ false; true ])
    [ E.Temp_written; E.File_synced; E.Published; E.Directory_synced ]
;;

let contains haystack needle =
  let rec loop i =
    i + String.length needle <= String.length haystack
    && (String.sub haystack i (String.length needle) = needle || loop (i + 1))
  in
  loop 0
;;

let rec files root =
  Array.to_list (Sys.readdir root)
  |> List.concat_map (fun name ->
    let path = Filename.concat root name in
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then files path else [ path ])
;;

let test_secrecy () =
  temp (fun directory ->
    let secret = "DISTINCTIVE-QUAL-CREDENTIAL-93d4"
    and unknown = "UNREGISTERED-KUBE-SECRET-2cb7" in
    let r = run () in
    let t = open_store ~secrets:[ secret ] directory r in
    ignore (begin_run t);
    let ((output, _, errors) as channels) =
      Unix.open_process_args_full
        "python3"
        [| "python3"
         ; "-c"
         ; "import os,sys; print('environment='+os.environ['QUAL_TEST_SECRET']); \
            print('Authentication failed: '+os.environ['QUAL_TEST_SECRET'], \
            file=sys.stderr); sys.exit(3)"
        |]
        [| "QUAL_TEST_SECRET=" ^ secret; "PATH=" ^ Sys.getenv "PATH" |]
    in
    let stdout = In_channel.input_all output
    and stderr = In_channel.input_all errors in
    (* Close/wait via the original channel tuple. No output is printed or written raw. *)
    ignore (Unix.close_process_full channels);
    ignore (E.diagnostic t (stdout ^ stderr) |> get);
    ignore
      (E.capture
         t
         ~subject:"w1"
         ~payload:
           (`Assoc
               [ "data", `Assoc [ "POSTGRES_URL", `String unknown ]
               ; "environment", `String unknown
               ; "failure", `String secret
               ])
       |> get);
    ignore (seal_all t r);
    E.close t;
    List.iter
      (fun path ->
         let bytes = In_channel.with_open_bin path In_channel.input_all in
         Alcotest.(check bool)
           "registered secret absent from all evidence"
           false
           (contains bytes secret);
         Alcotest.(check bool)
           "unprojected data/env absent from all evidence"
           false
           (contains bytes unknown))
      (files directory))
;;

let test_secret_temporary () =
  temp (fun directory ->
    let secret = "DISTINCTIVE-INTERRUPTED-CREDENTIAL-9ac5" in
    let r = run () in
    let t = open_store ~secrets:[ secret ] directory r in
    ignore (begin_run t);
    E.close t;
    let pid = Unix.fork () in
    if pid = 0
    then (
      try
        let armed = ref false in
        let fault boundary = if !armed && boundary = E.Temp_written then Unix._exit 97 in
        let t = open_store ~fault ~secrets:[ secret ] directory r in
        ignore (begin_run t);
        armed := true;
        ignore (E.capture t ~subject:"w1" ~payload:(`String ("stderr: " ^ secret)));
        Unix._exit 96
      with
      | _ -> Unix._exit 95)
    else (
      child_failed_expected pid;
      Alcotest.(check bool)
        "interrupted temporary retained"
        true
        (Array.length (Sys.readdir (Filename.concat directory "tmp")) > 0);
      List.iter
        (fun path ->
           let bytes = In_channel.with_open_bin path In_channel.input_all in
           Alcotest.(check bool)
             "no raw secret even in interrupted files"
             false
             (contains bytes secret))
        (files directory)))
;;

let test_forged_subset_manifest () =
  temp (fun directory ->
    let r = run () in
    let t = open_store directory r in
    ignore (begin_run t);
    let o, requests, verdicts = record_all t r in
    let manifest = E.seal ~captures:[] t ~obligations:o ~requests ~verdicts |> get in
    E.close t;
    let path ref = Filename.concat (Filename.concat directory "members") (E.digest ref) in
    let victim = List.hd verdicts in
    let victim_json = Yojson.Safe.from_file (path victim) in
    let key = Yojson.Safe.Util.(member "payload" victim_json |> member "instance") in
    let original = Yojson.Safe.from_file (path manifest) in
    let rec mutate = function
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (name, value) ->
                let value =
                  match name, value with
                  | "required", `List xs -> `List (List.filter (( <> ) key) xs)
                  | "dependencies", `List xs ->
                    `List
                      (List.filter
                         (fun j ->
                            Yojson.Safe.Util.member "digest" j
                            <> `String (E.digest victim))
                         xs)
                  | _ -> mutate value
                in
                name, value)
             fields)
      | `List xs -> `List (List.map mutate xs)
      | value -> value
    in
    let bytes = D.canonical_json (mutate original) |> domain in
    let forged =
      E.reference_of_json
        (`Assoc
            [ "digest", `String (D.sha256 bytes)
            ; "size", `Int (String.length bytes)
            ; "kind", `String "manifest"
            ])
      |> get
    in
    let fd =
      Unix.openfile (path forged) [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let ch = Unix.out_channel_of_descr fd in
    output_string ch bytes;
    close_out ch;
    match
      E.verify_manifest ~required_captures:[] ~directory ~run:r ~obligations:o forged
    with
    | Ok _ -> Alcotest.fail "self-consistent subset qualified"
    | Error e ->
      Alcotest.(check string)
        "independent obligation check rejects subset"
        "sealed obligations disagree with independently bound policy/selection"
        e.diagnostic)
;;

let test_detached_verdict_evidence () =
  List.iter
    (fun replace_support ->
       temp (fun directory ->
         let r = run () in
         let t = open_store directory r in
         ignore (begin_run t);
         let o, requests, verdicts = record_all t r in
         let unrelated =
           E.capture t ~subject:"unrelated" ~payload:(`String "unrelated") |> get
         in
         let manifest = E.seal ~captures:[] t ~obligations:o ~requests ~verdicts |> get in
         E.close t;
         let path ref =
           Filename.concat (Filename.concat directory "members") (E.digest ref)
         in
         let rewrite kind json =
           let bytes = D.canonical_json json |> domain in
           let ref =
             E.reference_of_json
               (`Assoc
                   [ "digest", `String (D.sha256 bytes)
                   ; "size", `Int (String.length bytes)
                   ; "kind", `String kind
                   ])
             |> get
           in
           let fd =
             Unix.openfile (path ref) [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
           in
           let ch = Unix.out_channel_of_descr fd in
           output_string ch bytes;
           close_out ch;
           ref
         in
         let replace_field name value = function
           | `Assoc xs ->
             `Assoc (List.map (fun (k, v) -> k, if k = name then value else v) xs)
           | _ -> Alcotest.fail "expected envelope"
         in
         (* Migration has a unique observation; deleting it cannot fail an unrelated check. *)
         let victim = List.rev verdicts |> List.hd in
         let body = Yojson.Safe.from_file (path victim) in
         let deps = Yojson.Safe.Util.(member "dependencies" body |> to_list) in
         let assessments =
           List.filter
             (fun j -> Yojson.Safe.Util.member "kind" j = `String "assessment")
             deps
         in
         let supports =
           List.filter
             (fun j -> Yojson.Safe.Util.member "kind" j = `String "observation")
             deps
         in
         let new_deps =
           assessments @ if replace_support then [ E.reference_json unrelated ] else []
         in
         let forged_verdict =
           rewrite "verdict" (replace_field "dependencies" (`List new_deps) body)
         in
         List.iter (fun j -> Unix.unlink (path (E.reference_of_json j |> get))) supports;
         let body = Yojson.Safe.from_file (path manifest) in
         let deps = Yojson.Safe.Util.(member "dependencies" body |> to_list) in
         let deps =
           List.map
             (fun j ->
                if Yojson.Safe.Util.member "digest" j = `String (E.digest victim)
                then E.reference_json forged_verdict
                else j)
             deps
         in
         let forged_manifest =
           rewrite "manifest" (replace_field "dependencies" (`List deps) body)
         in
         match
           E.verify_manifest
             ~required_captures:[]
             ~directory
             ~run:r
             ~obligations:o
             forged_manifest
         with
         | Ok _ -> Alcotest.fail "unsupported verdict qualified"
         | Error e ->
           Alcotest.(check string)
             "receipt structure rejects forgery"
             (if replace_support
              then "verdict evidence/dependency mismatch"
              else "verdict needs observation dependencies")
             e.diagnostic))
    [ false; true ]
;;

let test_persistence_failure () =
  temp (fun directory ->
    let armed = ref false in
    let fault _ = if !armed then raise (Sys_error "injected unwritable store") in
    let r = run () in
    let t = open_store ~fault directory r in
    ignore (begin_run t);
    armed := true;
    rejects
      (E.capture t ~subject:"w1" ~payload:(`String "successful read could not persist"));
    armed := false;
    let o = obligations r in
    rejects
      (E.seal
         ~captures:[]
         t
         ~obligations:o
         ~requests:(List.map D.plan (D.instances o))
         ~verdicts:[]);
    (* A storage error does not destroy the handle; recovery diagnostics can still
     be committed when storage recovers. It does not retroactively create proof. *)
    ignore (E.diagnostic t "capture failed; no qualification verdict exists" |> get);
    E.close t)
;;

let test_failure_after_complete_decisions () =
  temp (fun directory ->
    let armed = ref false in
    let fault _ = if !armed then raise (Sys_error "injected store failure") in
    let r = run () in
    let t = open_store ~fault directory r in
    ignore (begin_run t);
    let o, requests, verdicts = record_all t r in
    armed := true;
    rejects (E.diagnostic t "required capture failed");
    armed := false;
    rejects (E.seal ~captures:[] t ~obligations:o ~requests ~verdicts);
    E.close t)
;;

let test_durable_requirement_identity () =
  temp (fun directory ->
    let r = run () in
    let t = open_store directory r in
    ignore (begin_run t);
    let rec alter = function
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (k, v) ->
                ( k
                , if k = "administrative_secret"
                  then
                    `Assoc [ "namespace", `String "other"; "name", `String "other-admin" ]
                  else alter v ))
             fields)
      | `List xs -> `List (List.map alter xs)
      | v -> v
    in
    let selected =
      D.select r (D.Fixture.intent (alter (Yojson.Safe.from_file "intent.json")) |> domain)
      |> domain
    in
    let altered = D.bind_obligations r D.Aws selected |> domain in
    let _, requests, verdicts = record_all ~selected:altered t r in
    let expected = obligations r in
    let expected_requests = List.map D.plan (D.instances expected) in
    (* All keys and run IDs match; these PASS verdicts establish another binding. *)
    (match
       E.seal t ~obligations:expected ~requests:expected_requests ~verdicts ~captures:[]
     with
     | Ok _ -> Alcotest.fail "different bindings qualified through persistence"
     | Error e ->
       Alcotest.(check string)
         "persisted semantics checked"
         "verdict requirement identity mismatch"
         e.diagnostic);
    let manifest =
      E.seal t ~obligations:altered ~requests ~verdicts ~captures:[] |> get
    in
    E.close t;
    (* Make its obligation snapshot original while retaining the mismatched verdicts.
       Hashing the changed envelope cannot make those verdicts prove original intent. *)
    let path reference =
      Filename.concat (Filename.concat directory "members") (E.digest reference)
    in
    let json = Yojson.Safe.from_file (path manifest) in
    let rec replace = function
      | `Assoc xs ->
        `Assoc
          (List.map
             (fun (k, v) ->
                k, if k = "obligations" then D.obligations_json expected else replace v)
             xs)
      | v -> v
    in
    let bytes = D.canonical_json (replace json) |> domain in
    let forged =
      E.reference_of_json
        (`Assoc
            [ "digest", `String (D.sha256 bytes)
            ; "size", `Int (String.length bytes)
            ; "kind", `String "manifest"
            ])
      |> get
    in
    let fd =
      Unix.openfile (path forged) [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let ch = Unix.out_channel_of_descr fd in
    output_string ch bytes;
    close_out ch;
    match
      E.verify_manifest
        ~directory
        ~run:r
        ~obligations:expected
        ~required_captures:[]
        forged
    with
    | Ok _ -> Alcotest.fail "recovery ignored requirement identity"
    | Error e ->
      Alcotest.(check string)
        "recovered semantics checked"
        "verdict requirement identity mismatch"
        e.diagnostic)
;;

let test_failed_capture_restart () =
  List.iter
    (fun required ->
       temp (fun directory ->
         let r = run () in
         let spec =
           if required then [ "independent-inventory", "fixture-cluster" ] else []
         in
         let start t =
           E.start_assessment
             t
             ~reason:"required capture recovery"
             ~previous:[]
             ~required_captures:spec
           |> get
         in
         let t = open_store directory r in
         ignore (start t);
         let o, requests, verdicts = record_all t r in
         E.close t;
         let pid = Unix.fork () in
         if pid = 0
         then (
           try
             let armed = ref false in
             let fault boundary =
               if !armed && boundary = E.Temp_written
               then raise (Sys_error "required capture cannot persist")
             in
             let t = open_store ~fault directory r in
             ignore (start t);
             armed := true;
             let result =
               if required
               then
                 E.capture_required
                   t
                   ~id:"independent-inventory"
                   ~subject:"fixture-cluster"
                   ~payload:(`String "successful inventory")
               else
                 E.capture
                   t
                   ~subject:"extra-diagnostic"
                   ~payload:(`String "optional diagnostic")
             in
             (* Exit before any failure diagnostic can be persisted. *)
             match result with
             | Error _ -> Unix._exit 97
             | Ok _ -> Unix._exit 96
           with
           | _ -> Unix._exit 95)
         else (
           child_failed_expected pid;
           let t = open_store directory r in
           if required
           then
             rejects
               (E.start_assessment
                  t
                  ~reason:"required capture recovery"
                  ~previous:[]
                  ~required_captures:[]);
           ignore (start t);
           let resumed = E.seal t ~obligations:o ~requests ~verdicts ~captures:[] in
           if required
           then (
             (match resumed with
              | Ok _ -> Alcotest.fail "required capture disappeared across restart"
              | Error e ->
                Alcotest.(check string)
                  "durable missing capture"
                  "required capture coverage incomplete or duplicated"
                  e.diagnostic);
             let optional =
               E.capture
                 t
                 ~subject:"fixture-cluster"
                 ~payload:(`String "not a declared slot")
               |> get
             in
             rejects (E.seal t ~obligations:o ~requests ~verdicts ~captures:[ optional ]);
             rejects
               (E.capture_required
                  t
                  ~id:"independent-inventory"
                  ~subject:"other-cluster"
                  ~payload:`Null);
             let capture =
               E.capture_required
                 t
                 ~id:"independent-inventory"
                 ~subject:"fixture-cluster"
                 ~payload:(`String "recaptured inventory")
               |> get
             in
             rejects
               (E.seal
                  t
                  ~obligations:o
                  ~requests
                  ~verdicts
                  ~captures:[ capture; capture ]);
             let manifest =
               E.seal t ~obligations:o ~requests ~verdicts ~captures:[ capture ] |> get
             in
             E.close t;
             rejects
               (E.verify_manifest
                  ~directory
                  ~run:r
                  ~obligations:o
                  ~required_captures:[]
                  manifest);
             Alcotest.(check bool)
               "recapture restores completeness"
               true
               (E.verify_manifest
                  ~directory
                  ~run:r
                  ~obligations:o
                  ~required_captures:spec
                  manifest
                |> get)
                 .passed)
           else (
             let manifest = resumed |> get in
             E.close t;
             Alcotest.(check bool)
               "unrequired diagnostic is not an obligation"
               true
               (E.verify_manifest
                  ~directory
                  ~run:r
                  ~obligations:o
                  ~required_captures:[]
                  manifest
                |> get)
                 .passed))))
    [ true; false ]
;;

let () =
  Alcotest.run
    "qualification evidence"
    [ ( "hostile"
      , List.map
          (fun (name, test) -> Alcotest.test_case name `Quick test)
          [ "restart without decisions or final seal", test_restart
          ; "verified manifest coverage", test_manifest
          ; "explicit reassessment preserves failure", test_reassessment
          ; "conflicting outcomes and writer lock", test_conflicts
          ; "corrupted and missing dependencies", test_corruption
          ; "foreign candidate/specimen", test_wrong_binding
          ; "process death at commit boundaries", test_crashes
          ; "secret subprocess and object capture", test_secrecy
          ; "secret capture interrupted before publication", test_secret_temporary
          ; "self-consistent manifest subset", test_forged_subset_manifest
          ; "detached verdict evidence", test_detached_verdict_evidence
          ; "persistence failure remains operational", test_persistence_failure
          ; ( "failed capture restart distinguishes required slots"
            , test_failed_capture_restart )
          ; "durable requirement identity", test_durable_requirement_identity
          ; "complete decisions without seal", test_complete_unsealed_restart
          ; "transitive observation corruption", test_transitive_corruption
          ; ( "capture failure after complete decisions"
            , test_failure_after_complete_decisions )
          ] )
    ]
;;
