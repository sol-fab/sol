let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual

let recorded calls label result () =
  calls := label :: !calls;
  result
;;

let%test "mixed apply: both components run once in serverless-then-kubernetes order" =
  let calls = ref [] in
  let outcome =
    Sol_cli_mixed_apply.run
      ~apply_serverless:(recorded calls "serverless" (Ok ()))
      ~apply_kubernetes:(recorded calls "kubernetes" (Ok ()))
  in
  check_bool "complete" true (outcome = Sol_cli_mixed_apply.Complete);
  check_bool "order" true (List.rev !calls = [ "serverless"; "kubernetes" ])
;;

let%test "mixed apply: a serverless failure does not apply Kubernetes" =
  let calls = ref [] in
  let outcome =
    Sol_cli_mixed_apply.run
      ~apply_serverless:(recorded calls "serverless" (Error "serverless failed"))
      ~apply_kubernetes:(recorded calls "kubernetes" (Ok ()))
  in
  check_bool
    "serverless failure"
    true
    (outcome = Sol_cli_mixed_apply.Failed_serverless "serverless failed");
  check_bool "Kubernetes not called" true (List.rev !calls = [ "serverless" ])
;;

let%test "mixed apply: a Kubernetes failure reports the serverless component applied" =
  let calls = ref [] in
  let outcome =
    Sol_cli_mixed_apply.run
      ~apply_serverless:(recorded calls "serverless" (Ok ()))
      ~apply_kubernetes:(recorded calls "kubernetes" (Error "kubernetes failed"))
  in
  check_bool "partial" true (outcome = Sol_cli_mixed_apply.Partial "kubernetes failed");
  check_bool "both attempted" true (List.rev !calls = [ "serverless"; "kubernetes" ])
;;

let%test "mixed apply retry: the second attempt applies only the failed component" =
  let calls = ref [] in
  let attempt fail_kubernetes =
    Sol_cli_mixed_apply.run
      ~apply_serverless:(fun () ->
        calls := "serverless" :: !calls;
        Ok ())
      ~apply_kubernetes:(fun () ->
        calls := "kubernetes" :: !calls;
        if fail_kubernetes then Error "kubernetes failed" else Ok ())
  in
  (match attempt true with
   | Sol_cli_mixed_apply.Partial _ -> ()
   | _ -> Windtrap.fail "first attempt did not report a partial apply");
  (match attempt false with
   | Sol_cli_mixed_apply.Complete -> ()
   | _ -> Windtrap.fail "retry did not converge");
  check_bool
    "both attempts ran both components"
    true
    (List.rev !calls = [ "serverless"; "kubernetes"; "serverless"; "kubernetes" ])
;;

let workload ?image ?http name =
  { Sol_cli_transition.name
  ; kind = "fn"
  ; image
  ; schedule = None
  ; http
  ; config_digest = None
  }
;;

let%test "mixed apply retry: preserving an unrelated function is not destructive" =
  let previous =
    [ workload "ops/quote_fn" ~image:"image:a" ~http:("/quote", "public")
    ; workload "ops/unrelated_fn" ~image:"image:b" ~http:("/unrelated", "public")
    ]
  in
  let desired = previous in
  let transition =
    Sol_cli_transition.compute
      ~target:"dev/gcp/us-west1"
      ~backend:`Serverless
      ~previous
      ~desired
      ~unknown:[]
      ()
  in
  check_bool
    "unrelated function preserved"
    true
    (List.exists
       (fun (change : Sol_cli_transition.change) ->
          change.action = Preserve && String.equal change.name "ops/unrelated_fn")
       transition.changes);
  check_bool
    "retry has no destructive actions"
    true
    (Sol_cli_transition.destructive transition = [])
;;
