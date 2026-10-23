let record path line =
  let oc = open_out_gen [ Open_append; Open_creat ] 0o600 path in
  output_string oc (line ^ "\n");
  close_out oc
;;

let read_lines path =
  let ic = open_in path in
  let rec go acc =
    match input_line ic with
    | line -> go (line :: acc)
    | exception End_of_file ->
      close_in ic;
      List.rev acc
  in
  go []
;;

let peak_concurrency lines =
  let rec go concurrent peak = function
    | [] -> peak
    | line :: rest ->
      let is_start = String.length line > 6 && String.sub line 0 6 = "start " in
      let is_end = String.length line > 4 && String.sub line 0 4 = "end " in
      let concurrent =
        if is_start then concurrent + 1 else if is_end then concurrent - 1 else concurrent
      in
      go concurrent (max peak concurrent) rest
  in
  go 0 0 lines
;;

let install ~path ~delay ?(fail = false) ?(failure_diagnosis = fun () -> "") label =
  { Sol_cli_local_infra.label
  ; run =
      (fun () ->
        record path ("start " ^ label);
        Unix.sleepf delay;
        record path ("end " ^ label);
        if fail then Error ("installed nothing: " ^ label) else Ok ())
  ; failure_diagnosis
  }
;;

let with_events f =
  let path = Filename.temp_file "sol-local-infra-test-" ".events" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () -> f path)
;;

let test_installs_overlap_within_the_bound () =
  with_events (fun path ->
    let installs =
      List.init 6 (fun i -> install ~path ~delay:0.2 (Printf.sprintf "c%d" i))
    in
    match Sol_cli_local_infra.run_bounded ~max_in_flight:3 installs with
    | Error e -> Windtrap.failf "installs should have succeeded: %s" e
    | Ok () ->
      let peak = peak_concurrency (read_lines path) in
      Windtrap.equal Windtrap.bool ~msg:"three installs do overlap" true (peak >= 2);
      Windtrap.equal
        Windtrap.bool
        ~msg:(Printf.sprintf "never more than three at once (saw %d)" peak)
        true
        (peak <= 3);
      Windtrap.equal
        Windtrap.int
        ~msg:"every install ran and finished"
        12
        (List.length (read_lines path)))
;;

let test_serial_mode_keeps_plan_order () =
  with_events (fun path ->
    let installs =
      List.init 4 (fun i -> install ~path ~delay:0.05 (Printf.sprintf "c%d" i))
    in
    match Sol_cli_local_infra.run_bounded ~max_in_flight:1 installs with
    | Error e -> Windtrap.failf "serial installs should have succeeded: %s" e
    | Ok () ->
      Windtrap.equal
        Windtrap.int
        ~msg:"one at a time"
        1
        (peak_concurrency (read_lines path));
      Windtrap.equal
        (Windtrap.list Windtrap.string)
        ~msg:"started in the order given"
        [ "start c0"; "start c1"; "start c2"; "start c3" ]
        (List.filteri (fun i _ -> i mod 2 = 0) (read_lines path)))
;;

let test_a_failure_stops_new_installs () =
  with_events (fun path ->
    let installs =
      [ install ~path ~delay:0.05 "a"
      ; install ~path ~delay:0.05 ~fail:true "b"
      ; install ~path ~delay:0.05 "c"
      ]
    in
    match Sol_cli_local_infra.run_bounded ~max_in_flight:1 installs with
    | Ok () -> Windtrap.fail "a failing install must fail the run"
    | Error message ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"the failure names the component that failed"
        true
        (Sol_cli_string.contains ~needle:"b failed" message);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and says which components never ran, by name"
        true
        (Sol_cli_string.contains ~needle:"not attempted" message
         && Sol_cli_string.contains ~needle:"c" message);
      let lines = read_lines path in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the failed component ran"
        true
        (List.mem "start b" lines);
      Windtrap.equal
        Windtrap.bool
        ~msg:"the component after it never started"
        false
        (List.mem "start c" lines))
;;

let test_a_failure_prints_its_diagnosis () =
  with_events (fun path ->
    let installs =
      [ install
          ~path
          ~delay:0.05
          ~fail:true
          ~failure_diagnosis:(fun () ->
            "Pod loki-0: Pending\nReason: ImagePullBackOff — back-off pulling image")
          "Loki"
      ]
    in
    let result, reported =
      Sol_cli_report.collect (fun () ->
        Sol_cli_local_infra.run_bounded ~max_in_flight:1 installs)
    in
    match result with
    | Ok () -> Windtrap.fail "a failing install must fail the run"
    | Error _ ->
      let output = reported |> List.map snd |> String.concat "\n" in
      Windtrap.equal
        Windtrap.bool
        ~msg:"the failure output labels the component's diagnosis"
        true
        (Sol_cli_string.contains ~needle:"--- Loki diagnosis ---" output);
      Windtrap.equal
        Windtrap.bool
        ~msg:"and carries the pod reason"
        true
        (Sol_cli_string.contains ~needle:"ImagePullBackOff" output))
;;

let test_a_success_does_not_ask_for_a_diagnosis () =
  with_events (fun path ->
    let asked = ref false in
    let installs =
      [ install
          ~path
          ~delay:0.05
          ~failure_diagnosis:(fun () ->
            asked := true;
            "this must not be printed")
          "Loki"
      ]
    in
    match Sol_cli_local_infra.run_bounded ~max_in_flight:1 installs with
    | Error message -> Windtrap.failf "the install should have succeeded: %s" message
    | Ok () ->
      Windtrap.equal
        Windtrap.bool
        ~msg:"a successful install does not run its failure diagnosis"
        false
        !asked)
;;

let%test "bounded installs: overlap, bounded" = test_installs_overlap_within_the_bound ()
let%test "bounded installs: serial keeps order" = test_serial_mode_keeps_plan_order ()

let%test "bounded installs: a failure stops the queue" =
  test_a_failure_stops_new_installs ()
;;

let%test "bounded installs: a failure prints its diagnosis" =
  test_a_failure_prints_its_diagnosis ()
;;

let%test "bounded installs: success does not diagnose" =
  test_a_success_does_not_ask_for_a_diagnosis ()
;;

let endpoint ?(required = true) ?(start = fun () -> Ok ()) ?(stop = fun () -> ()) label =
  { Sol_cli_local_infra.endpoint_label = label
  ; endpoint_required = required
  ; endpoint_start = start
  ; endpoint_stop = stop
  }
;;

let outcome_is_ready = function
  | Sol_cli_local_infra.Ready -> true
  | Sol_cli_local_infra.Optional_unavailable _ -> false
;;

let test_every_required_endpoint_ready () =
  let outcomes =
    Sol_cli_local_infra.bring_up_endpoints [ endpoint "kafka"; endpoint "ingress" ]
  in
  match outcomes with
  | Error message -> Windtrap.failf "ready endpoints must succeed: %s" message
  | Ok outcomes ->
    Windtrap.equal Windtrap.int ~msg:"one outcome per endpoint" 2 (List.length outcomes);
    Windtrap.equal
      Windtrap.bool
      ~msg:"all ready"
      true
      (List.for_all outcome_is_ready outcomes)
;;

let test_an_optional_endpoint_can_be_unavailable () =
  let order = ref [] in
  let outcomes =
    Sol_cli_local_infra.bring_up_endpoints
      [ endpoint "core" ~start:(fun () ->
          order := "start core" :: !order;
          Ok ())
      ; endpoint ~required:false "grafana" ~start:(fun () ->
          order := "start grafana" :: !order;
          Error "no route to localhost:3000")
      ; endpoint "ingress" ~start:(fun () ->
          order := "start ingress" :: !order;
          Ok ())
      ]
  in
  match outcomes with
  | Error message -> Windtrap.failf "optional failures must not fail the run: %s" message
  | Ok
      [ Sol_cli_local_infra.Ready
      ; Sol_cli_local_infra.Optional_unavailable message
      ; Sol_cli_local_infra.Ready
      ] ->
    Windtrap.equal
      Windtrap.string
      ~msg:"the optional cause is preserved"
      "no route to localhost:3000"
      message;
    Windtrap.equal
      Windtrap.bool
      ~msg:"a later endpoint still starts"
      true
      (List.mem "start ingress" !order)
  | Ok _ -> Windtrap.fail "expected two ready outcomes around one optional failure"
;;

let test_a_required_failure_stops_owned_endpoints () =
  let started = ref [] in
  let stopped = ref [] in
  let outcomes =
    Sol_cli_local_infra.bring_up_endpoints
      [ endpoint
          "kafka"
          ~start:(fun () ->
            started := "kafka" :: !started;
            Ok ())
          ~stop:(fun () -> stopped := "kafka" :: !stopped)
      ; endpoint
          "postgres"
          ~start:(fun () -> Error "target has no endpoints")
          ~stop:(fun () -> stopped := "postgres" :: !stopped)
      ; endpoint "ingress" ~start:(fun () ->
          started := "ingress" :: !started;
          Ok ())
      ]
  in
  match outcomes with
  | Ok _ -> Windtrap.fail "a required failure must fail the run"
  | Error message ->
    Windtrap.equal
      Windtrap.bool
      ~msg:"the failure names the endpoint"
      true
      (Sol_cli_string.contains ~needle:"endpoint postgres" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the failure keeps the original cause"
      true
      (Sol_cli_string.contains ~needle:"target has no endpoints" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the failure gives retry guidance and says the cluster survives"
      true
      (Sol_cli_string.contains ~needle:"re-run `sol local deploy`" message
       && Sol_cli_string.contains ~needle:"left in place" message);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the already-started endpoint is stopped"
      true
      (List.mem "kafka" !stopped);
    Windtrap.equal
      Windtrap.bool
      ~msg:"the failed endpoint is stopped too"
      true
      (List.mem "postgres" !stopped);
    Windtrap.equal
      Windtrap.bool
      ~msg:"no endpoint after the failure starts"
      false
      (List.mem "ingress" !started)
;;

let test_an_optional_failure_does_not_stop_the_rest () =
  let stopped = ref [] in
  let outcomes =
    Sol_cli_local_infra.bring_up_endpoints
      [ endpoint "core" ~stop:(fun () -> stopped := "core" :: !stopped)
      ; endpoint ~required:false "tempo" ~start:(fun () -> Error "not ready")
      ]
  in
  (match outcomes with
   | Error message -> Windtrap.failf "optional failures must not fail the run: %s" message
   | Ok _ -> ());
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"nothing is torn down for an optional failure"
    []
    !stopped
;;

let%test "endpoints: every required endpoint ready" =
  test_every_required_endpoint_ready ()
;;

let%test "endpoints: an optional endpoint may be unavailable" =
  test_an_optional_endpoint_can_be_unavailable ()
;;

let%test "endpoints: a required failure stops owned endpoints" =
  test_a_required_failure_stops_owned_endpoints ()
;;

let%test "endpoints: an optional failure leaves the rest running" =
  test_an_optional_failure_does_not_stop_the_rest ()
;;
