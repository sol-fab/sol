type action =
  | Create
  | Update
  | Delete
  | Replace
  | Read
  | No_op
  | Unknown of string list

type change =
  { address : string
  ; resource_type : string
  ; mode : string
  ; action : action
  }

type matcher =
  | Exact of string
  | Resource of string
  | Type of string
  | Every_change

type rule =
  { matches : matcher list
  ; allows : action list
  ; reason : string
  }

type policy =
  { phase : string
  ; rules : rule list
  }

let action_of_raw = function
  | [ "no-op" ] -> No_op
  | [ "read" ] -> Read
  | [ "create" ] -> Create
  | [ "update" ] -> Update
  | [ "delete" ] -> Delete
  | [ "delete"; "create" ] | [ "create"; "delete" ] -> Replace
  | raw -> Unknown raw
;;

let action_to_string = function
  | Create -> "create"
  | Update -> "update"
  | Delete -> "delete"
  | Replace -> "replace"
  | Read -> "read"
  | No_op -> "no-op"
  | Unknown raw -> "unrecognised action [" ^ String.concat "," raw ^ "]"
;;

let changes_of_plan_json json : (change list, string) result =
  let text path item = Sol_cli_json.field path item |> Sol_cli_json.string in
  let change item =
    let raw_actions =
      Sol_cli_json.field [ "change"; "actions" ] item
      |> Sol_cli_json.list
      |> Option.value ~default:[]
      |> List.filter_map Sol_cli_json.string
    in
    match text [ "address" ] item, text [ "type" ] item, text [ "mode" ] item with
    | Some address, Some resource_type, Some mode ->
      Ok { address; resource_type; mode; action = action_of_raw raw_actions }
    | _ ->
      Error
        "a resource change in the plan has no address, type or mode, so it cannot be \
         asserted"
  in
  match Sol_cli_json.decode_sensitive ~what:"Terraform plan" json with
  | Error message -> Error message
  | Ok document ->
    (match Sol_cli_json.field [ "resource_changes" ] document with
     | `List items -> Sol_cli_result.map_list change items
     | _ -> Error "the plan JSON carries no `resource_changes` array")
;;

let without_instance_key address =
  match String.rindex_opt address '[' with
  | Some open_bracket
    when String.length address > open_bracket + 1
         && address.[String.length address - 1] = ']' -> String.sub address 0 open_bracket
  | Some _ | None -> address
;;

let same_resource a b = String.equal (without_instance_key a) (without_instance_key b)

let matches matcher change =
  match matcher with
  | Exact address -> change.address = address
  | Resource resource -> String.equal (without_instance_key change.address) resource
  | Type kind -> change.resource_type = kind
  | Every_change -> true
;;

let permitted policy change =
  match change.action with
  | No_op -> true
  | Read when change.mode = "data" -> true
  | action ->
    policy.rules
    |> List.exists (fun rule ->
      List.exists (fun matcher -> matches matcher change) rule.matches
      && List.mem action rule.allows)
;;

let violations policy changes =
  changes
  |> List.filter_map (fun change ->
    if permitted policy change
    then None
    else (
      let action = action_to_string change.action in
      let in_scope =
        policy.rules
        |> List.exists (fun rule ->
          List.exists (fun matcher -> matches matcher change) rule.matches)
      in
      Some
        (if in_scope
         then
           Printf.sprintf
             "%s phase: %s on %s (%s) is not an action this phase permits"
             policy.phase
             action
             change.address
             change.resource_type
         else
           Printf.sprintf
             "%s phase: %s on %s (%s) is outside this phase's scope"
             policy.phase
             action
             change.address
             change.resource_type)))
;;

type apply_failure =
  | Plan_failed of string
  | Plan_unreadable of string
  | Refused of string list
  | Apply_failed of string

let apply_failure_to_string = function
  | Plan_failed message -> message
  | Plan_unreadable message -> message
  | Refused violations -> "refused before apply: " ^ String.concat "; " violations
  | Apply_failed message -> message
;;

let was_refused = function
  | Refused _ -> true
  | Plan_failed _ | Plan_unreadable _ | Apply_failed _ -> false
;;

let guarded_apply ~policy ~plan ~show_plan ~apply_plan () =
  match plan () with
  | Error message ->
    Error
      (Plan_failed (Printf.sprintf "%s: terraform plan failed: %s" policy.phase message))
  | Ok plan_file ->
    (match show_plan plan_file with
     | Error message ->
       Error
         (Plan_unreadable
            (Printf.sprintf "%s: the plan could not be read: %s" policy.phase message))
     | Ok json ->
       (match changes_of_plan_json json with
        | Error message ->
          Error (Plan_unreadable (Printf.sprintf "%s: %s" policy.phase message))
        | Ok changes ->
          (match violations policy changes with
           | [] ->
             (match apply_plan plan_file with
              | Ok () -> Ok ()
              | Error message ->
                Error (Apply_failed (Printf.sprintf "%s: %s" policy.phase message)))
           | violations -> Error (Refused violations))))
;;

let removed_of_type ~resource_type changes =
  changes
  |> List.filter_map (fun c ->
    match c.action with
    | (Delete | Replace) when String.equal c.resource_type resource_type -> Some c.address
    | _ -> None)
;;

let show_and_record ~run_log ~phase ~show =
  let open Result.Syntax in
  let* json = show () in
  let* changes = changes_of_plan_json json in
  Sol_cli_run_log.append_phase_log
    run_log
    ~phase
    (String.concat
       ""
       (changes
        |> List.map (fun c ->
          Printf.sprintf "%s %s\n" (action_to_string c.action) c.address)));
  Ok (json, changes)
;;
