(* The platform teardown's absence verification is what lets a destroy claim absence, so it must
   classify the read instead of its exit status: a read that is refused, unauthorized, timed
   out, unreachable, unlaunchable or malformed is UNKNOWN, never a namespace that is gone
   (sol-fab/sol#1497). Kubernetes evaluates RBAC before object lookup, so an identity without a
   grant in the namespace answers Forbidden -- which the old `not (process_ok ...)` read as
   absence.

   Non-vacuity: restoring the exit-status rule fails the forbidden, timeout, unreachable,
   malformed and present cases below, and the two verify_absent cases that must refuse.

   Run it through dune (`dune build @ci-unit`, what CI runs); do not invoke the generated
   runner by hand after a plain build. *)

let with_fake_kubectl script f =
  let dir = Filename.temp_file "sol-teardown-kubectl" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let bin = Filename.concat dir "kubectl" in
  let oc = open_out bin in
  output_string oc script;
  close_out oc;
  Unix.chmod bin 0o755;
  let old_path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  Unix.putenv "PATH" (dir ^ ":" ^ old_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" old_path;
      (try Sys.remove bin with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    f
;;

let state_of script namespace =
  with_fake_kubectl script (fun () ->
    Sol_cli_platform_teardown.namespace_state ~env:[] namespace)
;;

let verify_of script =
  with_fake_kubectl script (fun () -> Sol_cli_platform_teardown.verify_absent ~env:[])
;;

let absent_script =
  {|#!/bin/sh
printf 'Error from server (NotFound): namespaces "%s" not found\n' "$3" >&2
exit 1
|}
;;

let says what = function
  | Sol_cli_platform_teardown.Namespace_absent ->
    Windtrap.fail (what ^ ": read as absence")
  | Sol_cli_platform_teardown.Namespace_present ->
    Windtrap.fail (what ^ ": read as present")
  | Sol_cli_platform_teardown.Namespace_unknown reason ->
    Windtrap.equal
      Windtrap.bool
      ~msg:(what ^ ": unestablished, with the provider's own words")
      true
      (reason <> "")
;;

let is_absent what = function
  | Sol_cli_platform_teardown.Namespace_absent -> ()
  | Sol_cli_platform_teardown.Namespace_present ->
    Windtrap.fail (what ^ ": read as present")
  | Sol_cli_platform_teardown.Namespace_unknown reason ->
    Windtrap.fail (what ^ ": not absence (" ^ reason ^ ")")
;;

let test_a_missing_namespace_is_absence () =
  is_absent "a namespace the server does not have" (state_of absent_script "cert-manager")
;;

let test_a_namespace_that_is_there_is_present () =
  let script =
    {|#!/bin/sh
printf 'namespace/%s\n' "$3"
exit 0
|}
  in
  match state_of script "cert-manager" with
  | Sol_cli_platform_teardown.Namespace_present -> ()
  | Sol_cli_platform_teardown.Namespace_absent ->
    Windtrap.fail "a namespace the server returns is not absence"
  | Sol_cli_platform_teardown.Namespace_unknown reason ->
    Windtrap.fail ("a namespace the server returns is present, not unknown: " ^ reason)
;;

let test_a_refused_read_is_unknown () =
  let script =
    {|#!/bin/sh
printf 'Error from server (Forbidden): namespaces "cert-manager" is forbidden\n' >&2
exit 1
|}
  in
  says "a read the cluster refuses" (state_of script "cert-manager")
;;

let test_a_timed_out_read_is_unknown () =
  let script =
    {|#!/bin/sh
printf 'error: timed out waiting for the condition\n' >&2
exit 1
|}
  in
  says "a read that timed out" (state_of script "cert-manager")
;;

let test_an_unreachable_cluster_is_unknown () =
  let script =
    {|#!/bin/sh
printf 'Unable to connect to the server: dial tcp 10.0.0.1:443: connect: connection refused\n' >&2
exit 1
|}
  in
  says "a cluster that cannot be reached" (state_of script "cert-manager")
;;

let test_a_read_that_did_not_name_the_namespace_is_unknown () =
  let script =
    {|#!/bin/sh
printf 'NAME        STATUS   AGE\n'
printf 'cert-manager   Active   5d\n'
exit 0
|}
  in
  says
    "a successful read that did not answer as expected"
    (state_of script "cert-manager")
;;

let test_a_read_that_answers_another_namespace_is_unknown () =
  let script =
    {|#!/bin/sh
printf 'namespace/redpanda\n'
exit 0
|}
  in
  says "a read that answered another namespace" (state_of script "cert-manager")
;;

let test_verification_passes_only_when_every_namespace_is_absent () =
  match verify_of absent_script with
  | Ok () -> ()
  | Error reason -> Windtrap.fail ("every namespace is absent: " ^ reason)
;;

let test_verification_refuses_when_one_namespace_is_still_there () =
  let script =
    {|#!/bin/sh
case "$3" in
  argocd) printf 'namespace/argocd\n'; exit 0 ;;
esac
printf 'Error from server (NotFound): namespaces "%s" not found\n' "$3" >&2
exit 1
|}
  in
  match verify_of script with
  | Ok () -> Windtrap.fail "a namespace that is still there is not absence"
  | Error reason ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the refusal names the namespace that is still there"
      true
      (Sol_cli_string.contains ~needle:"argocd" reason)
;;

let test_verification_refuses_when_one_namespace_cannot_be_read () =
  let script =
    {|#!/bin/sh
case "$3" in
  argocd) printf 'Error from server (Forbidden): namespaces "argocd" is forbidden\n' >&2; exit 1 ;;
esac
printf 'Error from server (NotFound): namespaces "%s" not found\n' "$3" >&2
exit 1
|}
  in
  match verify_of script with
  | Ok () -> Windtrap.fail "an unreadable namespace is not absence"
  | Error reason ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the refusal names the namespace it could not establish and says so"
      true
      (Sol_cli_string.contains ~needle:"argocd" reason
       && Sol_cli_string.contains ~needle:"could not be established" reason)
;;

let%test "platform teardown: a missing namespace is absence" =
  test_a_missing_namespace_is_absence ()
;;

let%test "platform teardown: a namespace that is there is present" =
  test_a_namespace_that_is_there_is_present ()
;;

let%test "platform teardown: a refused read is unknown, never absence" =
  test_a_refused_read_is_unknown ()
;;

let%test "platform teardown: a timed-out read is unknown, never absence" =
  test_a_timed_out_read_is_unknown ()
;;

let%test "platform teardown: an unreachable cluster is unknown, never absence" =
  test_an_unreachable_cluster_is_unknown ()
;;

let%test "platform teardown: a malformed read is unknown, never absence" =
  test_a_read_that_did_not_name_the_namespace_is_unknown ()
;;

let%test "platform teardown: a read that answered another namespace is unknown" =
  test_a_read_that_answers_another_namespace_is_unknown ()
;;

let%test "platform teardown: verification passes only when every namespace is absent" =
  test_verification_passes_only_when_every_namespace_is_absent ()
;;

let%test "platform teardown: verification refuses a namespace that is still there" =
  test_verification_refuses_when_one_namespace_is_still_there ()
;;

let%test "platform teardown: verification refuses a namespace it cannot read" =
  test_verification_refuses_when_one_namespace_cannot_be_read ()
;;
