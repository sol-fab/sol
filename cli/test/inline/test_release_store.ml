let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

let read_file path =
  try
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  with
  | _ -> ""
;;

let fake_kubectl ~log ~mode_file ~json_file =
  Printf.sprintf
    {|#!/bin/sh
verb=""
for a in "$@"; do
  case "$a" in
    apply|create|delete|get|patch|replace) verb="$a"; break ;;
  esac
done
file=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-f" ]; then file="$a"; fi
  prev="$a"
done
rv=no
if [ -n "$file" ] && grep -q '"resourceVersion"' "$file" 2>/dev/null; then rv=yes; fi
printf '%%s rv=%%s\n' "$verb" "$rv" >> %s
mode=$(cat %s 2>/dev/null)
if [ "$verb" = "get" ]; then
  if [ "$mode" = "missing" ]; then
    echo 'Error from server (NotFound): configmaps "sol-release-current-pluto" not found' >&2
    exit 1
  fi
  if [ "$mode" = "forbidden" ]; then
    echo 'Error from server (Forbidden): configmaps "sol-release-current-pluto" is forbidden:' \
         'cannot get resource "configmaps" in API group "" in the namespace "default"' >&2
    exit 1
  fi
  cat %s
fi
exit 0
|}
    log
    mode_file
    json_file
;;

let with_fake_kubectl ~mode ~live_json f =
  let dir = Filename.temp_file "sol-fake-kubectl-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let log = Filename.concat dir "calls.log" in
  let mode_file = Filename.concat dir "mode" in
  let json_file = Filename.concat dir "live.json" in
  write_file mode_file mode;
  write_file json_file live_json;
  let bin = Filename.concat dir "kubectl" in
  write_file bin (fake_kubectl ~log ~mode_file ~json_file);
  Unix.chmod bin 0o755;
  let old_path =
    try Sys.getenv "PATH" with
    | Not_found -> ""
  in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      (try Sys.remove mode_file with
       | _ -> ());
      (try Sys.remove json_file with
       | _ -> ());
      (try Sys.remove log with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () -> f log)
;;

let release ~release_id =
  { Sol_cli_release.release_id
  ; workspace = "pluto"
  ; environment = None
  ; workloads = []
  ; migrations = []
  ; contract = []
  ; apply_mode = Sol_cli_release.Direct
  ; encoding_version = Some Sol_cli_release_id.encoding_version
  }
;;

let ctx = Sol_cli_kube_destination.local_context

let verbs log =
  let lines = String.split_on_char '\n' (read_file log) in
  List.filter (fun l -> not (String.equal (String.trim l) "")) lines
;;

let test_absent_object_is_created () =
  with_fake_kubectl ~mode:"missing" ~live_json:"" (fun log ->
    Sol_cli_release_store.move_pointer ~ctx (release ~release_id:"r-aaaabbbbccccdddd")
    |> Result.iter_error (fun e -> Windtrap.fail ("expected success, got: " ^ e));
    let calls = verbs log in
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"one get, then one create, both without a resourceVersion"
      [ "get rv=no"; "create rv=no" ]
      calls;
    let all = String.concat "\n" calls in
    Windtrap.equal
      Windtrap.bool
      ~msg:"never applied"
      false
      (Sol_cli_string.contains ~needle:"apply" all);
    Windtrap.equal
      Windtrap.bool
      ~msg:"never patched"
      false
      (Sol_cli_string.contains ~needle:"patch" all))
;;

let test_identical_object_is_left_alone () =
  let live_json =
    {|{"kind":"ConfigMap","metadata":{"name":"sol-release-current-pluto","resourceVersion":"42"},"data":{"release_id":"r-aaaabbbbccccdddd"}}|}
  in
  with_fake_kubectl ~mode:"present" ~live_json (fun log ->
    Sol_cli_release_store.move_pointer ~ctx (release ~release_id:"r-aaaabbbbccccdddd")
    |> Result.iter_error (fun e -> Windtrap.fail ("expected success, got: " ^ e));
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"only a get"
      [ "get rv=no" ]
      (verbs log))
;;

let test_changed_object_is_replaced_with_a_precondition () =
  let live_json =
    {|{"kind":"ConfigMap","metadata":{"name":"sol-release-current-pluto","resourceVersion":"42"},"data":{"release_id":"r-1111222233334444"}}|}
  in
  with_fake_kubectl ~mode:"present" ~live_json (fun log ->
    Sol_cli_release_store.move_pointer ~ctx (release ~release_id:"r-aaaabbbbccccdddd")
    |> Result.iter_error (fun e -> Windtrap.fail ("expected success, got: " ^ e));
    let calls = verbs log in
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"one get, then a replace carrying the live resourceVersion"
      [ "get rv=no"; "replace rv=yes" ]
      calls;
    let all = String.concat "\n" calls in
    Windtrap.equal
      Windtrap.bool
      ~msg:"never applied"
      false
      (Sol_cli_string.contains ~needle:"apply" all);
    Windtrap.equal
      Windtrap.bool
      ~msg:"never patched"
      false
      (Sol_cli_string.contains ~needle:"patch" all))
;;

let test_permission_failure_is_not_absence () =
  with_fake_kubectl ~mode:"forbidden" ~live_json:"" (fun log ->
    (match
       Sol_cli_release_store.move_pointer ~ctx (release ~release_id:"r-aaaabbbbccccdddd")
     with
     | Ok () -> Windtrap.fail "a forbidden read must not be reported as success"
     | Error msg ->
       Windtrap.equal
         Windtrap.bool
         ~msg:"the error names the read"
         true
         (Sol_cli_string.contains ~needle:"kubectl get configmap" msg));
    let calls = verbs log in
    Windtrap.equal
      (Windtrap.list Windtrap.string)
      ~msg:"a get and nothing else"
      [ "get rv=no" ]
      calls;
    Windtrap.equal
      Windtrap.bool
      ~msg:"no create was attempted"
      false
      (Sol_cli_string.contains ~needle:"create" (String.concat "\n" calls)))
;;

let test_missing_release_is_not_found () =
  with_fake_kubectl ~mode:"missing" ~live_json:"" (fun _log ->
    match
      Sol_cli_release_store.get ~ctx ~workspace:"pluto" ~release_id:"r-aaaabbbbccccdddd"
    with
    | Ok _ -> Windtrap.fail "a missing release was found"
    | Error e ->
      Windtrap.equal
        Windtrap.bool
        ~msg:("names it not found: " ^ e)
        true
        (Sol_cli_string.contains ~needle:"release r-aaaabbbbccccdddd not found" e))
;;

let test_forbidden_release_read_is_not_absence () =
  with_fake_kubectl ~mode:"forbidden" ~live_json:"" (fun _log ->
    match
      Sol_cli_release_store.get ~ctx ~workspace:"pluto" ~release_id:"r-aaaabbbbccccdddd"
    with
    | Ok _ -> Windtrap.fail "a forbidden read succeeded"
    | Error e ->
      Windtrap.equal
        Windtrap.bool
        ~msg:("not reported as absence: " ^ e)
        false
        (Sol_cli_string.contains ~needle:"not found" e);
      Windtrap.equal
        Windtrap.bool
        ~msg:("carries kubectl's reason: " ^ e)
        true
        (Sol_cli_string.contains ~needle:"forbidden" e))
;;

let test_current_release_pointer_absence_is_empty () =
  with_fake_kubectl ~mode:"missing" ~live_json:"" (fun log ->
    match Sol_cli_release_store.current_record ~ctx ~workspace:"pluto" with
    | Error message -> Windtrap.fail message
    | Ok None ->
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"only a read is performed"
        [ "get rv=no" ]
        (verbs log)
    | Ok (Some _) -> Windtrap.fail "an absent current release pointer returned a record")
;;

let test_current_release_pointer_corruption_is_not_absence () =
  let live_json =
    {|{"kind":"ConfigMap","metadata":{"name":"sol-release-current-pluto"},"data":{}}|}
  in
  with_fake_kubectl ~mode:"present" ~live_json (fun log ->
    match Sol_cli_release_store.current_record ~ctx ~workspace:"pluto" with
    | Ok _ -> Windtrap.fail "a malformed current release pointer was treated as absent"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the malformed pointer is identified"
        true
        (Sol_cli_string.contains ~needle:"no data.release_id" message);
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"the malformed pointer is only read"
        [ "get rv=no" ]
        (verbs log))
;;

let%test "release record write (INFRA-055): an absent object is created" =
  test_absent_object_is_created ()
;;

let%test "release record write (INFRA-055): an identical object is left alone" =
  test_identical_object_is_left_alone ()
;;

let%test
    "release record write (INFRA-055): a changed object is replaced with a precondition"
  =
  test_changed_object_is_replaced_with_a_precondition ()
;;

let%test "release record write (INFRA-055): a permission failure is not absence" =
  test_permission_failure_is_not_absence ()
;;

let%test "release record read (REFAC-116): a missing release is not found" =
  test_missing_release_is_not_found ()
;;

let%test "release record read (REFAC-116): a forbidden read is not absence" =
  test_forbidden_release_read_is_not_absence ()
;;

let%test "release record read (1304): missing current pointer is empty" =
  test_current_release_pointer_absence_is_empty ()
;;

let%test "release record read (1304): malformed current pointer fails closed" =
  test_current_release_pointer_corruption_is_not_absence ()
;;
