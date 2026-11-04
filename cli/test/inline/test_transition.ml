let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_int msg expected actual = Windtrap.equal Windtrap.int ~msg expected actual

let workload ?image ?schedule ?http ?config_digest name kind =
  { Sol_cli_transition.name; kind; image; schedule; http; config_digest }
;;

let actions transition =
  Sol_cli_transition.destructive transition
  |> List.map (fun (change : Sol_cli_transition.change) ->
    change.action, change.resource, change.name)
;;

let has action resource name (transition : Sol_cli_transition.t) =
  List.exists
    (fun (change : Sol_cli_transition.change) ->
       change.action = action
       && change.resource = resource
       && String.equal change.name name)
    transition.changes
;;

let%test "transition: unchanged workloads are preserved, not destructive" =
  let previous = [ workload "payments/charge_svc" "svc" ~image:"image:a" ] in
  let desired = [ workload "payments/charge_svc" "svc" ~image:"image:a" ] in
  let transition =
    Sol_cli_transition.compute
      ~target:"dev/aws/us-east-1"
      ~backend:`Kubernetes
      ~previous
      ~desired
      ~unknown:[]
      ()
  in
  check_bool "preserved" true (has Preserve Workload "payments/charge_svc" transition);
  check_bool "no destructive" true (Sol_cli_transition.destructive transition = [])
;;

let%test "transition: removing a workload and its route is destructive" =
  let previous =
    [ workload "payments/quote_fn" "fn" ~image:"image:a" ~http:("/quote", "public") ]
  in
  let transition =
    Sol_cli_transition.compute
      ~target:"dev/aws/us-east-1"
      ~backend:`Serverless
      ~previous
      ~desired:[]
      ~unknown:[]
      ()
  in
  check_bool "workload delete" true (has Delete Workload "payments/quote_fn" transition);
  check_bool "route delete" true (has Delete Http_route "payments/quote_fn" transition);
  check_bool "gateway delete" true (has Delete Gateway "shared HTTP API" transition);
  check_bool
    "runtime identity delete"
    true
    (has Delete Runtime_identity "payments/quote_fn" transition);
  check_int "destructive count" 4 (List.length (actions transition))
;;

let%test "transition: a new public route adds the shared gateway" =
  let desired = [ workload "payments/quote_fn" "fn" ~http:("/quote", "public") ] in
  let transition =
    Sol_cli_transition.compute
      ~target:"dev/aws/us-east-1"
      ~backend:`Serverless
      ~previous:[]
      ~desired
      ~unknown:[]
      ()
  in
  check_bool "route add" true (has Add Http_route "payments/quote_fn" transition);
  check_bool "gateway add" true (has Add Gateway "shared HTTP API" transition);
  check_bool
    "runtime identity add"
    true
    (has Add Runtime_identity "payments/quote_fn" transition);
  check_bool "no destructive" true (Sol_cli_transition.destructive transition = [])
;;

let%test "transition: AWS public routes and schedules expose IAM permissions" =
  let transition =
    Sol_cli_transition.compute
      ~target:"dev/aws/us-east-1"
      ~backend:`Serverless
      ~previous:[]
      ~desired:
        [ workload
            "payments/quote_fn"
            "fn"
            ~schedule:"0 * * * *"
            ~http:("/quote", "public")
        ]
      ~unknown:[]
      ~permissions:{ Sol_cli_transition.scheduler_invoke = true; gateway_invoke = true }
      ()
  in
  check_bool
    "gateway permission"
    true
    (has Add Permission "payments/quote_fn gateway invoke" transition);
  check_bool
    "scheduler permission"
    true
    (has Add Permission "payments/quote_fn scheduler invoke" transition)
;;

let%test "transition: a path change deletes the old route before adding the new one" =
  let previous = [ workload "payments/quote_fn" "fn" ~http:("/quote", "public") ] in
  let desired = [ workload "payments/quote_fn" "fn" ~http:("/v2/quote", "public") ] in
  let transition =
    Sol_cli_transition.compute
      ~target:"dev/aws/us-east-1"
      ~backend:`Serverless
      ~previous
      ~desired
      ~unknown:[]
      ()
  in
  check_bool "route update" true (has Update Http_route "payments/quote_fn" transition);
  check_bool
    "route update destructive"
    true
    (List.exists
       (fun (change : Sol_cli_transition.change) ->
          change.action = Update && change.resource = Http_route)
       (Sol_cli_transition.destructive transition))
;;

let%test "transition: pulling a schedule is destructive; the same schedule is not" =
  let previous = [ workload "ops/cleanup_fn" "fn" ~schedule:"0 * * * *" ] in
  let same =
    Sol_cli_transition.compute
      ~target:"dev/gcp/us-west1"
      ~backend:`Serverless
      ~previous
      ~desired:[ workload "ops/cleanup_fn" "fn" ~schedule:"0 * * * *" ]
      ~unknown:[]
      ()
  in
  check_bool
    "same schedule has no destructive change"
    true
    (Sol_cli_transition.destructive same = []);
  let removed =
    Sol_cli_transition.compute
      ~target:"dev/gcp/us-west1"
      ~backend:`Serverless
      ~previous
      ~desired:[ workload "ops/cleanup_fn" "fn" ]
      ~unknown:[]
      ()
  in
  check_bool "schedule delete" true (has Delete Schedule "ops/cleanup_fn" removed)
;;

let%test "transition: AWS EventBridge expression compares as the declared five-field cron"
  =
  let expression = Sol_cli_transition.normalize_schedule "cron(0 * ? * * *)" in
  check_bool "normalized" true (String.equal expression "0 * * * *")
;;

let%test "transition: a persisted plan round-trips and preserves authorization entries" =
  let transition =
    Sol_cli_transition.compute
      ~target:"dev/aws/us-east-1"
      ~backend:`Serverless
      ~previous:[]
      ~desired:[ workload "payments/quote_fn" "fn" ~http:("/quote", "public") ]
      ~unknown:[]
      ~permissions:{ Sol_cli_transition.scheduler_invoke = true; gateway_invoke = true }
      ()
  in
  match Sol_cli_transition.of_json (Sol_cli_transition.to_json transition) with
  | Error message -> Windtrap.fail message
  | Ok loaded ->
    check_bool "round trip" true (loaded = transition);
    check_bool
      "permission retained"
      true
      (has Add Permission "payments/quote_fn gateway invoke" loaded)
;;
