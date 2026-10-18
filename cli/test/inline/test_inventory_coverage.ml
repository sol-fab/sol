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
