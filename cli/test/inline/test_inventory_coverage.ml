(* Required observations come from the native ownership/recovery contracts, not
   from the inventory under test. Removing a probe must break this join even
   though advertised coverage correctly shrinks with the executable inventory. *)
let missing_classes entries observed =
  entries
  |> List.filter_map (fun (entry : Sol_cli_resource_identity.entry) ->
    if entry.resource_class = "" || List.mem entry.resource_class observed
    then None
    else Some entry.resource_class)
  |> List.sort_uniq String.compare
;;

let%test "every native recovery class has an executable provider probe" =
  List.iter
    (fun (provider, entries, observed) ->
       Windtrap.equal
         (Windtrap.list Windtrap.string)
         ~msg:(provider ^ " native resource classes missing executable probes")
         []
         (missing_classes entries observed))
    [ ( "aws"
      , Sol_cli_resource_identity.aws ~cluster_name:"coverage"
      , Sol_cli_aws_absence.observed_classes () )
    ; ( "gcp"
      , Sol_cli_resource_identity.gcp
          ~project_id:(Some "coverage")
          ~cluster_name:"coverage"
      , Sol_cli_gcp_absence.observed_classes () )
    ]
;;

let%test "the independent coverage requirement detects a deleted subnet-group probe" =
  let observed =
    Sol_cli_aws_absence.observed_classes ()
    |> List.filter (fun name -> name <> "RDS subnet group")
  in
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"deleting a probe cannot erase its native recovery obligation"
    [ "RDS subnet group" ]
    (missing_classes (Sol_cli_resource_identity.aws ~cluster_name:"coverage") observed)
;;


let observed_required_classes () =
  Sol_cli_aws_absence.observed_classes () @ Sol_cli_gcp_absence.observed_classes ()
;;

let missing_required_classes observed =
  Sol_cli_cloud_destroy.required_identity_classes ()
  |> List.filter (fun class_name -> not (List.mem class_name observed))
  |> List.sort_uniq String.compare
;;

let%test "every required pre-destroy identity class has an executable probe" =
  Windtrap.equal
    (Windtrap.list Windtrap.string)
    ~msg:"required controller-created classes missing executable probes"
    []
    (missing_required_classes (observed_required_classes ()))
;;

let%test "the independent coverage check detects a removed required observation" =
  List.iter
    (fun class_name ->
       let observed =
         observed_required_classes () |> List.filter (fun name -> name <> class_name)
       in
       Windtrap.equal
         (Windtrap.list Windtrap.string)
         ~msg:("removing the " ^ class_name ^ " observation must be detected")
         [ class_name ]
         (missing_required_classes observed))
    [ "EBS volume"
    ; "OIDC provider"
    ; "regional address"
    ; "persistent disk"
    ; "elastic IP"
    ; "load balancer"
    ; "reserved global address"
    ; "forwarding rule"
    ]
;;
