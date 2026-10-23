type t =
  | Aws
  | Gcp
  | Byo

let of_string = function
  | "aws" -> Some Aws
  | "gcp" -> Some Gcp
  | "byo" -> Some Byo
  | _ -> None
;;

let to_string = function
  | Aws -> "aws"
  | Gcp -> "gcp"
  | Byo -> "byo"
;;

let is_known s = Option.is_some (of_string s)

let next = function
  | Aws -> Some Gcp
  | Gcp -> Some Byo
  | Byo -> None
;;

let all =
  let rec from p =
    p
    ::
    (match next p with
     | Some q -> from q
     | None -> [])
  in
  from Aws
;;

type key_disposition =
  | Sol_consumes
  | Passed_to_terraform

type owned_key =
  { key : string
  ; disposition : key_disposition
  }

let owned_keys : t -> owned_key list = function
  | Aws ->
    [ { key = "state_lock_table"; disposition = Sol_consumes }
    ; { key = "provisioner_role_arn"; disposition = Sol_consumes }
    ; { key = "cluster_access_role_arn"; disposition = Sol_consumes }
    ; { key = "deploy_role_arn"; disposition = Sol_consumes }
    ; { key = "operator_role_arn"; disposition = Sol_consumes }
    ]
  | Gcp ->
    [ { key = "provisioner_impersonator"; disposition = Sol_consumes }
    ; { key = "publisher_service_account"; disposition = Sol_consumes }
    ]
  | Byo -> []
;;

let owned_legacy_key name =
  List.find_map
    (fun driver ->
       if List.exists (fun owned -> String.equal owned.key name) (owned_keys driver)
       then Some driver
       else None)
    all
;;

let sol_keys driver =
  owned_keys driver
  |> List.filter_map (fun owned ->
    match owned.disposition with
    | Sol_consumes -> Some owned.key
    | Passed_to_terraform -> None)
;;
