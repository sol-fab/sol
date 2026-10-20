type execution_mode =
  | Dry_run
  | Apply

type deploy_action =
  | Deploy_dry_run of { emit_to : string option }
  | Deploy_emit_to of string
  | Deploy_apply

type local_deploy_request =
  { scope : string option
  ; mode : execution_mode
  ; image_tag : string
  ; image_tag_warning : string option
  ; confirm_group_change : bool
  ; keep_releases : int
  }

type deploy_request =
  { target : string
  ; action : deploy_action
  ; emit_plan_to : string option
  ; image_tag : string
  ; image_refs : (string option * string) list
  ; registry : string option
  ; confirm_group_change : bool
  ; confirm_ecr_removal : bool
  ; accept_unresolved : bool
  ; loki_push_url : string option
  ; keep_releases : int
  ; await_delegation : int option
  }

val git_sha : unit -> (string, string) result

val make_local_deploy_request
  :  scope:string option
  -> dry_run:bool
  -> tag:string option
  -> confirm_group_change:bool
  -> keep_releases:int
  -> git_sha:(unit -> (string, string) result)
  -> (local_deploy_request, string) result

val make_deploy_request
  :  target:string
  -> dry_run:bool
  -> emit_to:string option
  -> emit_plan_to:string option
  -> image_tag:string option
  -> image_refs:(string option * string) list
  -> registry:string option
  -> confirm_group_change:bool
  -> confirm_ecr_removal:bool
  -> loki_push_url:string option
  -> keep_releases:int
  -> await_delegation:int option
  -> accept_unresolved:bool
  -> git_sha:(unit -> (string, string) result)
  -> (deploy_request, string) result
