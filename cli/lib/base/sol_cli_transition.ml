open Result.Syntax

type workload =
  { name : string
  ; kind : string
  ; image : string option
  ; schedule : string option
  ; http : (string * string) option
  ; config_digest : string option
  }

type action =
  | Add
  | Update
  | Delete
  | Preserve

type resource_kind =
  | Workload
  | Http_route
  | Gateway
  | Schedule
  | Runtime_identity
  | Permission

type change =
  { resource : resource_kind
  ; name : string
  ; action : action
  ; destructive : bool
  ; detail : string
  }

type t =
  { target : string
  ; desired_fingerprint : string
  ; fingerprint : string
  ; changes : change list
  ; unknown : string list
  }

let action_to_string = function
  | Add -> "ADD"
  | Update -> "UPDATE"
  | Delete -> "DELETE"
  | Preserve -> "PRESERVE"
;;

let resource_to_string = function
  | Workload -> "workload"
  | Http_route -> "HTTP route"
  | Gateway -> "gateway"
  | Schedule -> "scheduled trigger"
  | Runtime_identity -> "runtime identity"
  | Permission -> "IAM permission"
;;

let plural = function
  | Workload -> "workloads"
  | Http_route -> "HTTP routes"
  | Gateway -> "gateways"
  | Schedule -> "scheduled triggers"
  | Runtime_identity -> "runtime identities"
  | Permission -> "IAM permissions"
;;

let normalize_schedule value =
  let value = String.trim value in
  let value =
    if String.starts_with ~prefix:"cron(" value && String.ends_with ~suffix:")" value
    then String.sub value 5 (String.length value - 6)
    else value
  in
  let parts =
    String.map
      (function
        | '?' -> '*'
        | c -> c)
      value
    |> String.split_on_char ' '
    |> List.filter (fun part -> part <> "")
  in
  let parts =
    match parts with
    | [ a; b; c; d; e; "*" ] -> [ a; b; c; d; e ]
    | _ -> parts
  in
  String.concat " " parts
;;

let optional_string json key = Sol_cli_json.string (Sol_cli_json.field [ key ] json)

let schedule_of_record json =
  match Sol_cli_json.field [ "scheduler" ] json with
  | `Null -> None
  | `Assoc _ as scheduler ->
    (match optional_string scheduler "expression" with
     | Some expression -> Some (normalize_schedule expression)
     | None -> Option.map normalize_schedule (optional_string scheduler "schedule"))
  | _ -> None
;;

let of_serverless_record ~service json =
  let* kind =
    match optional_string json "kind" with
    | Some kind -> Ok kind
    | None ->
      (* The Cloud Run -svc record predates the kind field; its revision is the
         provider-native identity that distinguishes it from a job/function. *)
      (match optional_string json "revision" with
       | Some _ -> Ok "svc"
       | None -> Error "release record has no kind")
  in
  let* primitive =
    match kind with
    | "svc" -> Ok "svc"
    | "fn" | "fn_http" -> Ok "fn"
    | other -> Error (Printf.sprintf "unknown serverless release kind %S" other)
  in
  let http =
    match kind with
    | "fn_http" ->
      (match optional_string json "http_path", optional_string json "http_exposure" with
       | Some path, Some exposure -> Some (path, exposure)
       | _ -> None)
    | _ -> None
  in
  Ok
    { name = service
    ; kind = primitive
    ; image = optional_string json "image"
    ; schedule = schedule_of_record json
    ; http
    ; config_digest = None
    }
;;

let public_route (workload : workload) =
  match workload.http with
  | Some (path, "public") -> Some path
  | _ -> None
;;

let compare_workload (a : workload) (b : workload) =
  let by_name = String.compare a.name b.name in
  if by_name <> 0 then by_name else String.compare a.kind b.kind
;;

let workload_changes backend previous desired =
  let previous = List.sort compare_workload previous in
  let desired = List.sort compare_workload desired in
  let changes = ref [] in
  let add change = changes := change :: !changes in
  List.iter
    (fun (expected : workload) ->
       match
         List.find_opt
           (fun (actual : workload) ->
              String.equal actual.name expected.name
              && String.equal actual.kind expected.kind)
           previous
       with
       | None ->
         add
           { resource = Workload
           ; name = expected.name
           ; action = Add
           ; destructive = false
           ; detail =
               (match expected.image with
                | Some image -> "image " ^ image
                | None -> "new " ^ expected.kind)
           }
       | Some actual ->
         let image_changed =
           match actual.image, expected.image with
           | Some a, Some b -> not (String.equal a b)
           | None, None -> false
           | _ -> true
         in
         if image_changed
         then
           add
             { resource = Workload
             ; name = expected.name
             ; action = Update
             ; destructive = false
             ; detail = "image and runtime configuration change"
             }
         else
           add
             { resource = Workload
             ; name = expected.name
             ; action = Preserve
             ; destructive = false
             ; detail = "unchanged"
             })
    desired;
  List.iter
    (fun (actual : workload) ->
       if
         not
           (List.exists
              (fun (expected : workload) ->
                 String.equal actual.name expected.name
                 && String.equal actual.kind expected.kind)
              desired)
       then
         add
           { resource = Workload
           ; name = actual.name
           ; action = Delete
           ; destructive = true
           ; detail =
               (match backend with
                | `Kubernetes ->
                  "the target no longer declares it; removal requires the recorded UID"
                | `Serverless -> "the target no longer declares it")
           })
    previous;
  List.rev !changes
;;

let schedule_changes previous desired =
  let changes = ref [] in
  let add change = changes := change :: !changes in
  List.iter
    (fun (expected : workload) ->
       let actual =
         List.find_opt
           (fun (actual : workload) -> String.equal actual.name expected.name)
           previous
       in
       match actual with
       | None ->
         (match expected.schedule with
          | Some schedule ->
            add
              { resource = Schedule
              ; name = expected.name
              ; action = Add
              ; destructive = false
              ; detail = schedule
              }
          | None -> ())
       | Some actual ->
         (match actual.schedule, expected.schedule with
          | Some old_schedule, Some new_schedule
            when not (String.equal old_schedule new_schedule) ->
            add
              { resource = Schedule
              ; name = expected.name
              ; action = Update
              ; destructive = true
              ; detail = Printf.sprintf "%s becomes %s" old_schedule new_schedule
              }
          | Some old_schedule, None ->
            add
              { resource = Schedule
              ; name = expected.name
              ; action = Delete
              ; destructive = true
              ; detail = old_schedule
              }
          | None, Some new_schedule ->
            add
              { resource = Schedule
              ; name = expected.name
              ; action = Add
              ; destructive = false
              ; detail = new_schedule
              }
          | _ -> ()))
    desired;
  List.iter
    (fun (actual : workload) ->
       if
         (not
            (List.exists (fun (e : workload) -> String.equal e.name actual.name) desired))
         && Option.is_some actual.schedule
       then
         add
           { resource = Schedule
           ; name = actual.name
           ; action = Delete
           ; destructive = true
           ; detail = Option.get actual.schedule
           })
    previous;
  List.rev !changes
;;

let route_changes backend previous desired =
  let changes = ref [] in
  let add change = changes := change :: !changes in
  let previous_routes =
    List.filter_map
      (fun (workload : workload) ->
         Option.map (fun path -> workload.name, path) (public_route workload))
      previous
  in
  let desired_routes =
    List.filter_map
      (fun (workload : workload) ->
         Option.map (fun path -> workload.name, path) (public_route workload))
      desired
  in
  List.iter
    (fun (name, path) ->
       match List.assoc_opt name previous_routes with
       | None ->
         add
           { resource = Http_route
           ; name
           ; action = Add
           ; destructive = false
           ; detail = path
           }
       | Some old_path when not (String.equal old_path path) ->
         add
           { resource = Http_route
           ; name
           ; action = Update
           ; destructive = true
           ; detail = Printf.sprintf "%s becomes %s" old_path path
           }
       | Some _ -> ())
    desired_routes;
  List.iter
    (fun (name, path) ->
       if not (List.mem_assoc name desired_routes)
       then
         add
           { resource = Http_route
           ; name
           ; action = Delete
           ; destructive = true
           ; detail = path
           })
    previous_routes;
  (match backend with
   | `Kubernetes -> ()
   | `Serverless ->
     let previous_gateway = previous_routes <> [] in
     let desired_gateway = desired_routes <> [] in
     (match previous_gateway, desired_gateway with
      | false, true ->
        add
          { resource = Gateway
          ; name = "shared HTTP API"
          ; action = Add
          ; destructive = false
          ; detail = "one public API for this target"
          }
      | true, false ->
        add
          { resource = Gateway
          ; name = "shared HTTP API"
          ; action = Delete
          ; destructive = true
          ; detail = "no public HTTP routes remain"
          }
      | true, true when previous_routes <> desired_routes ->
        add
          { resource = Gateway
          ; name = "shared HTTP API"
          ; action = Update
          ; destructive = false
          ; detail = "routes are reconciled"
          }
      | _ -> ()));
  List.rev !changes
;;

type permissions =
  { scheduler_invoke : bool
  ; gateway_invoke : bool
  }

let no_permissions = { scheduler_invoke = false; gateway_invoke = false }

let digest_config pairs =
  pairs
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  |> List.map (fun (key, value) -> key ^ "=" ^ value)
  |> String.concat "\000"
  |> Digest.string
  |> Digest.to_hex
;;

let authorization_changes ~backend ~permissions existing =
  let changes = ref [] in
  let add change = changes := change :: !changes in
  List.iter
    (fun (change : change) ->
       match change.resource, change.action with
       | Workload, (Add | Delete) ->
         add
           { resource = Runtime_identity
           ; name = change.name
           ; action = change.action
           ; destructive = change.action = Delete
           ; detail =
               (match backend with
                | `Kubernetes -> "Kubernetes ServiceAccount for the workload"
                | `Serverless -> "runtime identity reconciled by target authorization")
           }
       | Schedule, (Add | Delete) ->
         (match backend with
          | `Kubernetes -> ()
          | `Serverless ->
            add
              { resource = Runtime_identity
              ; name = change.name ^ " scheduler"
              ; action = change.action
              ; destructive = change.action = Delete
              ; detail = "scheduler execution identity"
              };
            if permissions.scheduler_invoke
            then
              add
                { resource = Permission
                ; name = change.name ^ " scheduler invoke"
                ; action = change.action
                ; destructive = change.action = Delete
                ; detail = "EventBridge permission to invoke the function"
                })
       | Schedule, Update when backend = `Serverless ->
         if permissions.scheduler_invoke
         then
           add
             { resource = Permission
             ; name = change.name ^ " scheduler invoke"
             ; action = Update
             ; destructive = true
             ; detail = "EventBridge permission follows the replaced schedule"
             }
       | Http_route, (Add | Delete) ->
         if permissions.gateway_invoke
         then
           add
             { resource = Permission
             ; name = change.name ^ " gateway invoke"
             ; action = change.action
             ; destructive = change.action = Delete
             ; detail = "API Gateway permission to invoke the function"
             }
       | Http_route, Update ->
         if permissions.gateway_invoke
         then
           add
             { resource = Permission
             ; name = change.name ^ " gateway invoke"
             ; action = Update
             ; destructive = true
             ; detail = "API Gateway permission follows the replaced route"
             }
       | _ -> ())
    existing;
  List.rev !changes
;;

let compute_fingerprint ~target ~backend ~previous ~desired =
  let backend =
    match backend with
    | `Kubernetes -> "kubernetes"
    | `Serverless -> "serverless"
  in
  let workload (w : workload) =
    Printf.sprintf
      "%s\000%s\000%s\000%s\000%s\000%s"
      w.name
      w.kind
      (Option.value w.image ~default:"")
      (Option.value w.schedule ~default:"")
      (match w.http with
       | Some (path, exposure) -> path ^ ":" ^ exposure
       | None -> "")
      (Option.value w.config_digest ~default:"")
  in
  let all list = String.concat "\001" (List.map workload list) in
  Digest.to_hex
    (Digest.string (String.concat "\002" [ target; backend; all previous; all desired ]))
;;

let desired_fingerprint ~target ~backend ~desired =
  compute_fingerprint ~target ~backend ~previous:[] ~desired
;;

let compute
      ~target
      ~backend
      ~previous
      ~desired
      ~unknown
      ?(permissions = no_permissions)
      ?fingerprint
      ()
  =
  let changes =
    workload_changes backend previous desired
    @ schedule_changes previous desired
    @ route_changes backend previous desired
  in
  { target
  ; desired_fingerprint = desired_fingerprint ~target ~backend ~desired
  ; fingerprint =
      (let previous_and_desired =
         compute_fingerprint ~target ~backend ~previous ~desired
       in
       match fingerprint with
       | Some fingerprint ->
         (* The supplied fingerprint already covers the desired unit set (the
            Kubernetes release id). Add only the previous state, whose images
            and config are not part of that id. *)
         fingerprint ^ ":" ^ compute_fingerprint ~target ~backend ~previous ~desired:[]
       | None -> previous_and_desired)
  ; changes = changes @ authorization_changes ~backend ~permissions changes
  ; unknown
  }
;;

let destructive t = List.filter (fun change -> change.destructive) t.changes
let has_changes t = List.exists (fun change -> change.action <> Preserve) t.changes

let count_by_action_kind changes =
  let counts = Hashtbl.create 8 in
  List.iter
    (fun (change : change) ->
       if change.action <> Preserve
       then (
         let key = change.action, change.resource in
         let current = Option.value (Hashtbl.find_opt counts key) ~default:0 in
         Hashtbl.replace counts key (current + 1)))
    changes;
  Hashtbl.fold (fun key count acc -> (key, count) :: acc) counts []
  |> List.sort (fun ((a_action, a_kind), _) ((b_action, b_kind), _) ->
    let by_action = compare a_action b_action in
    if by_action <> 0 then by_action else compare a_kind b_kind)
;;

let render ?(title = "Sol deployment plan") t =
  let buffer = Buffer.create 512 in
  let line format = Printf.ksprintf (Buffer.add_string buffer) format in
  line "%s\n" title;
  line "Target: %s\n" t.target;
  let counts = count_by_action_kind t.changes in
  if counts = []
  then line "  no changes\n"
  else
    List.iter
      (fun ((action, resource), count) ->
         line "  %-8s %2d %s\n" (action_to_string action) count (plural resource))
      counts;
  let destructive = destructive t in
  if destructive <> []
  then (
    line "\nDestructive changes:\n";
    List.iter
      (fun (change : change) ->
         line
           "  %-8s %-18s %s (%s)\n"
           (action_to_string change.action)
           (resource_to_string change.resource)
           change.name
           change.detail)
      destructive);
  if t.unknown <> []
  then (
    line "\nUnknown (Sol cannot rule out destructive changes):\n";
    List.iter (fun reason -> line "  %s\n" reason) t.unknown);
  Buffer.contents buffer
;;

let action_of_string = function
  | "add" -> Ok Add
  | "update" -> Ok Update
  | "delete" -> Ok Delete
  | "preserve" -> Ok Preserve
  | other -> Error (Printf.sprintf "unknown plan action %S" other)
;;

let action_name = function
  | Add -> "add"
  | Update -> "update"
  | Delete -> "delete"
  | Preserve -> "preserve"
;;

let resource_name = function
  | Workload -> "workload"
  | Http_route -> "http_route"
  | Gateway -> "gateway"
  | Schedule -> "schedule"
  | Runtime_identity -> "runtime_identity"
  | Permission -> "permission"
;;

let resource_of_string = function
  | "workload" -> Ok Workload
  | "http_route" -> Ok Http_route
  | "gateway" -> Ok Gateway
  | "schedule" -> Ok Schedule
  | "runtime_identity" -> Ok Runtime_identity
  | "permission" -> Ok Permission
  | other -> Error (Printf.sprintf "unknown plan resource %S" other)
;;

let to_json t =
  `Assoc
    [ "version", `Int 1
    ; "target", `String t.target
    ; "desired_fingerprint", `String t.desired_fingerprint
    ; "fingerprint", `String t.fingerprint
    ; ( "changes"
      , `List
          (List.map
             (fun (change : change) ->
                `Assoc
                  [ "resource", `String (resource_name change.resource)
                  ; "name", `String change.name
                  ; "action", `String (action_name change.action)
                  ; "destructive", `Bool change.destructive
                  ; "detail", `String change.detail
                  ])
             t.changes) )
    ; "unknown", `List (List.map (fun reason -> `String reason) t.unknown)
    ]
;;

let of_json json =
  let* version =
    Sol_cli_json.int (Sol_cli_json.field [ "version" ] json)
    |> Option.to_result ~none:"transition plan has no version"
  in
  let* () =
    if version = 1
    then Ok ()
    else Error (Printf.sprintf "unsupported transition plan version %d" version)
  in
  let* target =
    Sol_cli_json.string (Sol_cli_json.field [ "target" ] json)
    |> Option.to_result ~none:"transition plan has no target"
  in
  let* desired_fingerprint =
    Sol_cli_json.string (Sol_cli_json.field [ "desired_fingerprint" ] json)
    |> Option.to_result ~none:"transition plan has no desired_fingerprint"
  in
  let* fingerprint =
    Sol_cli_json.string (Sol_cli_json.field [ "fingerprint" ] json)
    |> Option.to_result ~none:"transition plan has no fingerprint"
  in
  let* changes =
    match Sol_cli_json.field [ "changes" ] json with
    | `List changes ->
      changes
      |> Sol_cli_result.map_list (fun item ->
        let* resource =
          Sol_cli_json.string (Sol_cli_json.field [ "resource" ] item)
          |> fun value ->
          Option.to_result ~none:"transition change has no resource" value
          |> fun value -> Result.bind value resource_of_string
        in
        let* name =
          Sol_cli_json.string (Sol_cli_json.field [ "name" ] item)
          |> Option.to_result ~none:"transition change has no name"
        in
        let* action =
          Sol_cli_json.string (Sol_cli_json.field [ "action" ] item)
          |> fun value ->
          Option.to_result ~none:"transition change has no action" value
          |> fun value -> Result.bind value action_of_string
        in
        let* destructive =
          Sol_cli_json.bool (Sol_cli_json.field [ "destructive" ] item)
          |> Option.to_result ~none:"transition change has no destructive flag"
        in
        let* detail =
          Sol_cli_json.string (Sol_cli_json.field [ "detail" ] item)
          |> Option.to_result ~none:"transition change has no detail"
        in
        Ok { resource; name; action; destructive; detail })
    | _ -> Error "transition plan changes is not a list"
  in
  let* unknown =
    match Sol_cli_json.field [ "unknown" ] json with
    | `List items ->
      items
      |> Sol_cli_result.map_list (fun item ->
        Sol_cli_json.string item
        |> Option.to_result ~none:"transition plan unknown entry is not a string")
    | _ -> Error "transition plan unknown is not a list"
  in
  Ok { target; desired_fingerprint; fingerprint; changes; unknown }
;;
