(* Exercise the real guarded writer at its Kubernetes boundary. The stub records
   complete requests; Kubernetes, rather than Sol, provides JSON Patch atomicity. *)
let with_projection f =
  let root = Filename.temp_dir "sol-kafka-projection-" "" in
  let state = Filename.concat root "state.json" in
  let calls = Filename.concat root "calls.jsonl" in
  let fail = Filename.concat root "fail" in
  let race = Filename.concat root "race" in
  let kubectl = Filename.concat root "kubectl" in
  let write path contents =
    Out_channel.with_open_text path (fun ch -> output_string ch contents)
  in
  let read path = In_channel.with_open_text path In_channel.input_all in
  let secret owner =
    `Assoc
      [ ( "metadata"
        , `Assoc [ "labels", `Assoc [ "app.kubernetes.io/managed-by", `String owner ] ] )
      ; ( "data"
        , `Assoc
            [ "OTHER_KEY", `String "cHJlc2VydmU="
            ; "KAFKA_SASL_PASSWORD", `String "b2xk"
            ; "KAFKA_SSL_CA_CERT", `String "b2xkLWNh"
            ] )
      ]
  in
  let initial = `Assoc [ "first", secret "sol"; "second", secret "sol" ] in
  write state (Yojson.Safe.to_string initial);
  write
    kubectl
    {|#!/usr/bin/env python3
import json,pathlib,sys
root=pathlib.Path(__file__).parent
a=sys.argv[1:]
state=json.loads((root/'state.json').read_text())
ns=a[a.index('-n')+1] if '-n' in a else None
race=(root/'race').read_text() if (root/'race').exists() else ''
if 'get' in a and 'externalsecrets' in a: sys.exit(0)
if 'get' in a and 'secret' in a:
 if ns=='first' and race and not (root/'raced').exists():
  (root/'raced').touch()
  if race=='foreign-create':
   state[ns]['metadata']['labels']['app.kubernetes.io/managed-by']='other'
   (root/'state.json').write_text(json.dumps(state))
   print('Error from server (NotFound): Secret absent at read',file=sys.stderr);sys.exit(1)
  if race=='data-created':
   print(json.dumps(state[ns]))
   state[ns]['data']={'OTHER_KEY':'cHJlc2VydmU='}
   state[ns]['metadata']['resourceVersion']='2'
   (root/'state.json').write_text(json.dumps(state));sys.exit(0)
 print(json.dumps(state[ns])); sys.exit(0)
if 'create' in a:
 manifest=pathlib.Path(a[a.index('-f')+1]).read_text()
 if 'kind: Secret' in manifest:
  assert race=='foreign-create'
  print('Error from server (AlreadyExists): concurrent Secret',file=sys.stderr);sys.exit(1)
 assert 'kind: Namespace' in manifest
 sys.exit(0)
if 'patch' in a:
 ops=json.loads(pathlib.Path(a[a.index('--patch-file')+1]).read_text())
 with (root/'calls.jsonl').open('a') as f: f.write(json.dumps([ns,ops])+'\n')
 if (root/'fail').exists() and ns=='second':
  print('Error from server (Forbidden): scoped write denied password-canary ca-canary cGFzc3dvcmQtY2FuYXJ5 Y2EtY2FuYXJ5',file=sys.stderr);sys.exit(1)
 for op in ops:
  if op['op']=='test':
   actual=(state[ns]['metadata']['resourceVersion'] if op['path']=='/metadata/resourceVersion'
           else state[ns]['metadata']['labels']['app.kubernetes.io/managed-by'])
   if actual!=op['value']:
    print('Error from server (Conflict): stale Secret precondition',file=sys.stderr);sys.exit(1)
  else:
   assert op['op']=='add'
   if op['path']=='/data': state[ns]['data']=op['value']
   else:
    assert op['path'].startswith('/data/')
    state[ns]['data'][op['path'][6:]]=op['value']
 (root/'state.json').write_text(json.dumps(state)); sys.exit(0)
raise AssertionError('unexpected Kubernetes call: '+repr(a))
|};
  Unix.chmod kubectl 0o700;
  let old_path = Sys.getenv "PATH" in
  Unix.putenv "PATH" (root ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      Array.iter (fun name -> Sys.remove (Filename.concat root name)) (Sys.readdir root);
      Unix.rmdir root)
    (fun () ->
       f
         ~initial
         ~state:(fun () -> Yojson.Safe.from_string (read state))
         ~set_state:(fun json -> write state (Yojson.Safe.to_string json))
         ~calls:(fun () ->
           if Sys.file_exists calls
           then
             read calls
             |> String.split_on_char '\n'
             |> List.filter (( <> ) "")
             |> List.map Yojson.Safe.from_string
           else [])
         ~fail:(fun enabled -> if enabled then write fail "" else Sys.remove fail)
         ~race:(write race))
;;

let credential_values =
  [ "KAFKA_SASL_PASSWORD", "password-canary"; "KAFKA_SSL_CA_CERT", "ca-canary" ]
;;

let deliver () =
  Sol_cli_secret.set_target_keys
    ~ctx:Sol_cli_kube_destination.local_context
    ~namespaces:[ "first"; "second" ]
    ~secret_name:"prod-kafka-creds"
    ~values:credential_values
;;

let updated initial namespace =
  let open Yojson.Safe.Util in
  let original = initial |> member namespace |> to_assoc in
  let data = initial |> member namespace |> member "data" |> to_assoc in
  `Assoc
    (( "data"
     , `Assoc
         (List.map
            (fun (key, value) -> key, `String (Base64.encode_exn value))
            credential_values
          @ List.filter (fun (key, _) -> not (List.mem_assoc key credential_values)) data
         ) )
     :: List.remove_assoc "data" original)
;;

let check_json msg expected actual =
  Windtrap.equal Windtrap.bool ~msg true (Yojson.Safe.equal expected actual)
;;

let assert_atomic_requests calls =
  List.iter
    (function
      | `List [ `String _; `List operations ] ->
        let open Yojson.Safe.Util in
        let paths = List.map (fun op -> op |> member "path" |> to_string) operations in
        Windtrap.equal
          (Windtrap.list Windtrap.string)
          ~msg:
            "one guarded request contains both keys and never overwrites unrelated data"
          [ "/metadata/labels/app.kubernetes.io~1managed-by"
          ; "/data/KAFKA_SASL_PASSWORD"
          ; "/data/KAFKA_SSL_CA_CERT"
          ]
          paths
      | _ -> Windtrap.fail "unexpected patch request")
    calls
;;

let%test
    "Kafka projection failure leaves complete pairs; retry reconciles remaining \
     namespaces"
  =
  with_projection (fun ~initial ~state ~set_state:_ ~calls ~fail ~race:_ ->
    fail true;
    (match deliver () with
     | Ok _ -> Windtrap.fail "the second namespace write should fail"
     | Error message ->
       List.iter
         (fun needle ->
            Windtrap.equal
              Windtrap.bool
              ~msg:needle
              true
              (Sol_cli_string.contains ~needle message))
         [ "second/prod-kafka-creds"
         ; "Forbidden"
         ; "scoped write denied"
         ; "already updated in namespace(s): first"
         ; "not rolled back"
         ];
       List.iter
         (fun (_, value) ->
            Windtrap.equal
              Windtrap.bool
              ~msg:"values stay out of diagnostics"
              false
              (Sol_cli_string.contains ~needle:value message))
         (List.concat_map
            (fun (key, value) -> [ key, value; key, Base64.encode_exn value ])
            credential_values));
    let open Yojson.Safe.Util in
    check_json
      "first namespace has both values and its unrelated key"
      (updated initial "first")
      (state () |> member "first");
    check_json
      "failed namespace retains its entire previous pair"
      (initial |> member "second")
      (state () |> member "second");
    Windtrap.equal Windtrap.int ~msg:"one update per namespace" 2 (List.length (calls ()));
    assert_atomic_requests (calls ());
    fail false;
    Windtrap.equal
      (Windtrap.result (Windtrap.list Windtrap.string) Windtrap.string)
      ~msg:"retry only changes the unfinished namespace"
      (Ok [ "second" ])
      (deliver ());
    List.iter
      (fun ns ->
         check_json
           "both namespaces reconciled"
           (updated initial ns)
           (state () |> member ns))
      [ "first"; "second" ];
    Windtrap.equal
      Windtrap.int
      ~msg:"retry skips the already reconciled namespace"
      3
      (List.length (calls ()));
    assert_atomic_requests (calls ()))
;;

let%test
    "Kafka projection refuses unowned destinations without overwriting earlier namespaces"
  =
  List.iter
    (fun metadata ->
       with_projection (fun ~initial ~state ~set_state ~calls ~fail:_ ~race:_ ->
         let open Yojson.Safe.Util in
         let second = initial |> member "second" |> to_assoc in
         let second =
           `Assoc (("metadata", metadata) :: List.remove_assoc "metadata" second)
         in
         set_state (`Assoc [ "first", initial |> member "first"; "second", second ]);
         (match deliver () with
          | Ok _ -> Windtrap.fail "unowned Secret accepted"
          | Error message ->
            Windtrap.equal
              Windtrap.bool
              ~msg:"partial completion is explicit"
              true
              (Sol_cli_string.contains
                 ~needle:"already updated in namespace(s): first"
                 message));
         check_json "unowned Secret untouched" second (state () |> member "second");
         Windtrap.equal
           Windtrap.int
           ~msg:"only the owned destination is patched"
           1
           (List.length (calls ()));
         assert_atomic_requests (calls ())))
    [ `Assoc []
    ; `Assoc [ "labels", `Assoc [ "app.kubernetes.io/managed-by", `String "other" ] ]
    ]
;;

let%test "Kafka projection never patches an unobserved concurrent creator" =
  with_projection (fun ~initial:_ ~state ~set_state:_ ~calls ~fail:_ ~race ->
    race "foreign-create";
    (match deliver () with
     | Ok _ -> Windtrap.fail "foreign concurrent creator received the credential"
     | Error message ->
       Windtrap.equal
         Windtrap.bool
         true
         (Sol_cli_string.contains ~needle:"managed by other" message));
    Windtrap.equal
      Windtrap.int
      ~msg:"ownership is rechecked before any patch"
      0
      (List.length (calls ()));
    let open Yojson.Safe.Util in
    Windtrap.equal
      Windtrap.string
      ~msg:"foreign data unchanged"
      "b2xk"
      (state ()
       |> member "first"
       |> member "data"
       |> member "KAFKA_SASL_PASSWORD"
       |> to_string))
;;

let%test
    "Kafka projection refuses stale data-map initialization and retry preserves \
     concurrent keys"
  =
  with_projection (fun ~initial ~state ~set_state ~calls ~fail:_ ~race ->
    let open Yojson.Safe.Util in
    let first = initial |> member "first" |> to_assoc |> List.remove_assoc "data" in
    let metadata = first |> List.assoc "metadata" |> to_assoc in
    let first =
      `Assoc
        (("metadata", `Assoc (("resourceVersion", `String "1") :: metadata))
         :: List.remove_assoc "metadata" first)
    in
    set_state (`Assoc [ "first", first; "second", initial |> member "second" ]);
    race "data-created";
    (match deliver () with
     | Ok _ -> Windtrap.fail "stale /data replacement accepted"
     | Error message ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"provider conflict retained"
         true
         (Sol_cli_string.contains ~needle:"Conflict" message));
    check_json
      "concurrent unrelated data survives"
      (`Assoc [ "OTHER_KEY", `String "cHJlc2VydmU=" ])
      (state () |> member "first" |> member "data");
    Windtrap.equal
      Windtrap.int
      ~msg:"failure stops before the next namespace"
      1
      (List.length (calls ()));
    Windtrap.equal
      (Windtrap.result (Windtrap.list Windtrap.string) Windtrap.string)
      (Ok [ "first"; "second" ])
      (deliver ());
    check_json
      "retry preserves unrelated data and projects both values"
      (updated initial "first" |> member "data")
      (state () |> member "first" |> member "data"))
;;
