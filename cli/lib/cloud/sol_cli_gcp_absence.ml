open Sol_cli_absence

type check =
  { resource_class : string
  ; identity : string
  ; attribution : attribution
  ; argv : string list
  ; attributable : string -> bool
  ; normalize : string -> string
  }

let identity_check
      ?(attributable = fun _ -> true)
      ?(normalize = fun line -> line)
      ~resource_class
      ~identity
      ~attribution
      argv
  =
  { resource_class; identity; attribution; argv; attributable; normalize }
;;

let checked_with argv = "gcloud " ^ String.concat " " argv

let ok_observation ~check found =
  let checked_with = checked_with check.argv in
  match found with
  | [] ->
    Absent
      { resource_class = check.resource_class
      ; identity = check.identity
      ; attribution = check.attribution
      ; checked_with
      }
  | found ->
    Present
      { resource_class = check.resource_class
      ; identity = check.identity
      ; found
      ; attribution = check.attribution
      ; checked_with
      }
;;

(* gcloud can report a scope failure as a warning on an otherwise successful empty
   listing (for example, a nonexistent project). The one benign warning is the
   filter-key notice gcloud emits when the result is empty. Any other stderr on an empty
   result is unknown, not absence. *)
let benign_empty_list_warning stderr =
  lines stderr
  |> List.for_all (fun line ->
    String.starts_with
      ~prefix:"WARNING: The following filter keys were not present in any resource"
      line)
;;

(* Every GCP probe is an enumeration command. An empty successful listing is absence;
   a nonzero listing is not, even when the provider's message contains "not found": the
   subject may be the project, the caller's permission or the API's scope, not the
   resource. Reading that as absence is what allowed a bad scope to authorize state
   removal. *)
let prior_for class_name prior =
  List.assoc_opt class_name prior |> Option.value ~default:[]
;;

let run ?(previously_attributed = []) ~check () =
  match Sol_cli_process.run (Sol_cli_process.cmd ("gcloud" :: check.argv)) with
  | Ok { Sol_cli_process.stdout; stderr } ->
    (* An incomplete enumeration is unknown even when some matching resources were
       returned: presence may be real, but the collection cannot authorize a destructive
       reconciliation decision. *)
    if not (benign_empty_list_warning stderr)
    then
      Unobservable
        { resource_class = check.resource_class
        ; reason = String.trim stderr
        ; checked_with = checked_with check.argv
        }
    else (
      let raw = lines stdout in
      let prior = prior_for check.resource_class previously_attributed in
      let attributed = List.filter check.attributable raw in
      let prior_matches =
        List.filter (fun line -> List.mem (check.normalize line) prior) raw
      in
      ok_observation
        ~check
        (List.map check.normalize (List.rev_append attributed prior_matches)
         |> List.sort_uniq String.compare))
  | Error (Sol_cli_process.Non_zero r) ->
    Unobservable
      { resource_class = check.resource_class
      ; reason = String.trim r.stderr
      ; checked_with = checked_with check.argv
      }
  | Error _ ->
    Unobservable
      { resource_class = check.resource_class
      ; reason = "the gcloud CLI is unavailable"
      ; checked_with = checked_with check.argv
      }
;;

let project_of (target : Sol_cli_config.target) =
  match List.assoc_opt "gcp" target.provider_fields with
  | None -> None
  | Some fields ->
    (match List.assoc_opt "project_id" fields with
     | Some project when String.trim project <> "" -> Some (String.trim project)
     | _ -> None)
;;

let names_the_cluster cluster_name =
  Printf.sprintf
    "the target's own cluster name: every resource the target's roots create carries it \
     (cluster root and shared platform module alike), so %s is that name"
    cluster_name
;;

let cluster_check ~project ~region ~cluster_name =
  identity_check
    ~resource_class:"GKE cluster"
    ~identity:cluster_name
    ~attribution:(Named_for_target (names_the_cluster cluster_name))
    ~attributable:(fun line -> line = cluster_name)
    [ "--project"
    ; project
    ; "container"
    ; "clusters"
    ; "list"
    ; "--region"
    ; region
    ; "--format"
    ; "value(name)"
    ]
;;

let project_iam_binding_check ~project ~resource_class ~identity ~role ~member =
  identity_check
    ~resource_class
    ~identity
    ~attribution:
      (Named_for_target
         (Printf.sprintf
            "the target's own project: a binding of %s to %s is the grant the root \
             creates"
            role
            member))
    ~attributable:(fun line ->
      match String.split_on_char '\t' line with
      | [ actual_role; actual_member ] ->
        String.equal actual_role role && String.equal actual_member member
      | _ -> false)
    [ "--project"
    ; project
    ; "projects"
    ; "get-iam-policy"
    ; project
    ; "--flatten=bindings[].members"
    ; "--format=value(bindings.role,bindings.members)"
    ]
;;

let checks ~project ~region ~cluster_name =
  let p args = [ "--project"; project ] @ args in
  let named ~resource_class ~identity ?(prefix = cluster_name ^ "-") argv =
    identity_check
      ~resource_class
      ~identity
      ~attribution:(Named_for_target (names_the_cluster cluster_name))
      ~attributable:(fun line ->
        line = cluster_name
        || (prefix <> "" && Sol_cli_string.contains ~needle:prefix line))
      argv
  in
  let role_prefix =
    "sol_"
    ^ String.map
        (function
          | '-' -> '_'
          | c -> c)
        cluster_name
    ^ "_"
  in
  let project_roles = "projects/" ^ project ^ "/roles/" in
  [ cluster_check ~project ~region ~cluster_name
  ; identity_check
      ~resource_class:"GKE node pool"
      ~identity:(cluster_name ^ "-*")
      ~attribution:(Named_for_target (names_the_cluster cluster_name))
      ~attributable:(fun line -> Sol_cli_string.contains ~needle:cluster_name line)
      (p
         [ "container"
         ; "node-pools"
         ; "list"
         ; "--cluster"
         ; cluster_name
         ; "--location"
         ; region
         ; "--format"
         ; "value(name)"
         ])
  ; named
      ~resource_class:"VPC network"
      ~identity:cluster_name
      ~prefix:""
      (p [ "compute"; "networks"; "list"; "--format"; "value(name)" ])
  ; named
      ~resource_class:"subnetwork"
      ~identity:(cluster_name ^ "-nodes")
      (p
         [ "compute"
         ; "networks"
         ; "subnets"
         ; "list"
         ; "--regions"
         ; region
         ; "--format"
         ; "value(name)"
         ])
  ; named
      ~resource_class:"Cloud Router"
      ~identity:(cluster_name ^ "-router")
      (p [ "compute"; "routers"; "list"; "--regions"; region; "--format"; "value(name)" ])
  ; named
      ~resource_class:"Cloud NAT"
      ~identity:(cluster_name ^ "-nat")
      (p
         [ "compute"
         ; "routers"
         ; "nats"
         ; "list"
         ; "--router"
         ; cluster_name ^ "-router"
         ; "--router-region"
         ; region
         ; "--format"
         ; "value(name)"
         ])
  ; named
      ~resource_class:"Cloud SQL instance"
      ~identity:(cluster_name ^ "-postgres")
      (p
         [ "sql"
         ; "instances"
         ; "list"
         ; "--filter"
         ; "region:" ^ region
         ; "--format"
         ; "value(name)"
         ])
  ; named
      ~resource_class:"reserved global address"
      ~identity:(cluster_name ^ "-sql-peering")
      (p [ "compute"; "addresses"; "list"; "--global"; "--format"; "value(name)" ])
  ; named
      ~resource_class:"Artifact Registry repository"
      ~identity:cluster_name
      ~prefix:""
      (p
         [ "artifacts"
         ; "repositories"
         ; "list"
         ; "--location"
         ; region
         ; "--format"
         ; "value(name)"
         ])
  ; named
      ~resource_class:"service account"
      ~identity:(cluster_name ^ "-*")
      (p [ "iam"; "service-accounts"; "list"; "--format"; "value(email)" ])
  ; identity_check
      ~resource_class:"custom role"
      ~identity:(role_prefix ^ "*")
      ~attribution:(Named_for_target (names_the_cluster cluster_name))
      ~attributable:(fun line ->
        if String.starts_with ~prefix:"projects/" line
        then
          String.starts_with ~prefix:project_roles line
          && Sol_cli_string.contains ~needle:role_prefix line
        else Sol_cli_string.contains ~needle:role_prefix line)
      ~normalize:(fun line ->
        if String.starts_with ~prefix:"projects/" line then line else project_roles ^ line)
      (p [ "iam"; "roles"; "list"; "--format"; "value(name)" ])
  ; named
      ~resource_class:"storage bucket"
      ~identity:(cluster_name ^ "-*")
      (p [ "storage"; "buckets"; "list"; "--format"; "value(name)" ])
  ; identity_check
      ~resource_class:"persistent disk"
      ~identity:(Printf.sprintf "a disk labelled goog-k8s-cluster-name=%s" cluster_name)
      ~attribution:
        (Within_target
           (Printf.sprintf
              "the target's own GKE cluster label: GKE applies goog-k8s-cluster-name=%s \
               to the disks it owns, and the disk name is not an ownership signal"
              cluster_name))
      ~attributable:(fun line ->
        match String.split_on_char '\t' line with
        | [ _name; label ] -> String.equal label cluster_name
        | _ -> false)
      ~normalize:(fun line ->
        match String.split_on_char '\t' line with
        | name :: _ -> name
        | [] -> line)
      (p
         [ "compute"
         ; "disks"
         ; "list"
         ; "--regions"
         ; region
         ; "--format"
         ; "value(name,labels.goog-k8s-cluster-name)"
         ])
  ; identity_check
      ~resource_class:"firewall rule"
      ~identity:(cluster_name ^ " and gke-" ^ cluster_name ^ "-*")
      ~attribution:
        (Named_for_target
           (Printf.sprintf
              "the target's own cluster name: GKE names the rules it creates gke-%s-*, \
               and the ones rule %s belongs to are the target's own VPC"
              cluster_name
              cluster_name))
      ~attributable:(fun line ->
        Sol_cli_string.contains ~needle:("gke-" ^ cluster_name) line
        || Sol_cli_string.contains ~needle:("/networks/" ^ cluster_name) line)
      (p [ "compute"; "firewall-rules"; "list"; "--format"; "value(name,network)" ])
  ; identity_check
      ~resource_class:"service-networking peering connection"
      ~identity:("the target's own VPC " ^ cluster_name)
      ~attribution:
        (Within_target
           (Printf.sprintf
              "the target's own VPC: the Cloud SQL peering is created on %s, so it \
               cannot                outlive it"
              cluster_name))
      ~attributable:(fun line -> line <> "")
      (p
         [ "services"
         ; "vpc-peerings"
         ; "list"
         ; "--network"
         ; cluster_name
         ; "--format"
         ; "value(state)"
         ])
  ; identity_check
      ~resource_class:"forwarding rule"
      ~identity:("in the target's own VPC " ^ cluster_name)
      ~attribution:
        (Within_target
           (Printf.sprintf
              "the target's own VPC: a forwarding rule inside %s belongs to a service \
               the target's cluster created, whatever GKE named it"
              cluster_name))
      ~attributable:(fun line ->
        Sol_cli_string.contains ~needle:("/networks/" ^ cluster_name) line)
      (p [ "compute"; "forwarding-rules"; "list"; "--format"; "value(name,network)" ])
  ; (* Project IAM bindings are not children of the principal or the custom
       role. Deleting the service account or role can leave the project policy
       entry behind, so observe each binding the root creates. *)
    project_iam_binding_check
      ~project
      ~resource_class:"provisioner project IAM binding"
      ~identity:
        (Printf.sprintf
           "%s -> serviceAccount:%s-provisioner@%s.iam.gserviceaccount.com"
           (project_roles ^ role_prefix ^ "cluster_access")
           cluster_name
           project)
      ~role:(project_roles ^ role_prefix ^ "cluster_access")
      ~member:
        ("serviceAccount:"
         ^ cluster_name
         ^ "-provisioner@"
         ^ project
         ^ ".iam.gserviceaccount.com")
  ; project_iam_binding_check
      ~project
      ~resource_class:"cert-manager DNS discovery project IAM binding"
      ~identity:
        (Printf.sprintf
           "%s -> serviceAccount:%s-cert-manager@%s.iam.gserviceaccount.com"
           (project_roles ^ role_prefix ^ "cert_manager_dns_discovery")
           cluster_name
           project)
      ~role:(project_roles ^ role_prefix ^ "cert_manager_dns_discovery")
      ~member:
        ("serviceAccount:"
         ^ cluster_name
         ^ "-cert-manager@"
         ^ project
         ^ ".iam.gserviceaccount.com")
  ]
;;

let durable_observations ~(target : Sol_cli_config.target) ~cluster_name =
  let base_domain = Option.value target.base_domain ~default:"" in
  [ Sol_cli_absence.durable_state_bucket
      ~identity:(cluster_name ^ " (the durable backend)")
  ; External
      { resource_class = "DNS managed zone"
      ; identity =
          (if base_domain = "" then "(the target's base domain)" else base_domain)
      ; reason =
          "a delegation zone is not created or owned by default: the operator publishes \
           it and it outlives the target, so its presence is the contract, not residue"
      }
  ]
;;

let derived_by_vpc ~cluster_name observations =
  let vpc_observation =
    List.find_opt
      (fun observation ->
         match observation with
         | Absent { resource_class; _ } | Present { resource_class; _ } ->
           resource_class = "VPC network"
         | _ -> false)
      observations
  in
  match vpc_observation with
  | Some (Absent { attribution; checked_with; _ }) ->
    observations
    |> List.map (function
      | Unobservable { resource_class = "service-networking peering connection"; _ } ->
        Absent
          { resource_class = "service-networking peering connection"
          ; identity =
              Printf.sprintf "the target's own VPC %s (which is absent)" cluster_name
          ; attribution
          ; checked_with
          }
      | other -> other)
  | _ -> observations
;;

let relinquished_residue_probes =
  [ "google_service_networking_connection.sql", "service-networking peering connection" ]
;;

let observed_classes () =
  checks ~project:"coverage" ~region:"coverage" ~cluster_name:"coverage"
  |> List.map (fun check -> check.resource_class)
  |> fun classes -> classes @ [ "regional address" ]
;;

let unlistable =
  "the target declares no gcp.project_id, so the provider could not be listed -- an \
   inventory that did not run cannot establish absence"
;;

let authorization_checks ~project ~(target : Sol_cli_config.target) =
  let account_id = "sol-" ^ target.env ^ "-authorization" in
  let email = account_id ^ "@" ^ project ^ ".iam.gserviceaccount.com" in
  let role =
    "projects/"
    ^ project
    ^ "/roles/sol_"
    ^ String.map
        (function
          | '-' -> '_'
          | c -> c)
        target.env
    ^ "_authorization"
  in
  [ identity_check
      ~resource_class:"authorization service account"
      ~identity:email
      ~attribution:
        (Named_for_target
           "the target's environment names the authorization reconciler identity")
      ~attributable:(fun line -> line = email)
      ~normalize:(fun line -> line)
      [ "--project"
      ; project
      ; "iam"
      ; "service-accounts"
      ; "list"
      ; "--format"
      ; "value(email)"
      ]
  ; identity_check
      ~resource_class:"authorization custom role"
      ~identity:role
      ~attribution:
        (Named_for_target
           "the target's environment names the authorization reconciler role")
      ~attributable:(fun line -> line = role)
      ~normalize:(fun line -> line)
      [ "--project"; project; "iam"; "roles"; "list"; "--format"; "value(name)" ]
  ; project_iam_binding_check
      ~project
      ~resource_class:"authorization project IAM binding"
      ~identity:(Printf.sprintf "%s -> serviceAccount:%s" role email)
      ~role
      ~member:("serviceAccount:" ^ email)
  ]
;;

let strict_authorization_observation ~check =
  match run ~check () with
  | Unobservable u ->
    Unobservable
      { u with
        resource_class = Sol_cli_absence.scope_class
      ; reason = check.resource_class ^ ": " ^ u.reason
      }
  | observation -> observation
;;

let secret_bindings_checked_with ~project ~environment =
  Printf.sprintf
    "gcloud secrets list --project %s --filter=name:sol-%s- --format=value(name), then \
     gcloud secrets get-iam-policy <secret> --project %s --format=json for each secret"
    project
    environment
    project
;;

let secret_binding_members ~project text =
  let open Result.Syntax in
  let* json = Sol_cli_json.decode ~what:"the secret IAM policy" text in
  let* bindings =
    Sol_cli_json.optional
      ~what:"the secret IAM policy"
      [ "bindings" ]
      Sol_cli_json.list
      json
    |> Result.map (Option.value ~default:[])
  in
  let* found =
    Sol_cli_result.map_list
      (fun binding ->
         let* role =
           Sol_cli_json.require
             ~what:"a secret IAM binding"
             [ "role" ]
             Sol_cli_json.string
             binding
         in
         let* members =
           Sol_cli_json.require
             ~what:"a secret IAM binding"
             [ "members" ]
             Sol_cli_json.list
             binding
         in
         let* members =
           Sol_cli_result.map_list
             (fun member ->
                match Sol_cli_json.string member with
                | Some member -> Ok member
                | None -> Error "a secret IAM member is not a string")
             members
         in
         Ok
           (List.filter_map
              (fun member ->
                 if
                   String.starts_with
                     ~prefix:("serviceAccount:" ^ project ^ ".svc.id.goog[")
                     member
                 then Some (role, member)
                 else None)
              members))
      bindings
  in
  Ok (List.concat found)
;;

(* The authorization root puts secret IAM members on durable environment
   secrets. The secrets themselves are not target residue, but a grant the
   target added to one is: deleting the reconciler or the workload identity does
   not necessarily remove the secret's policy entry. Enumerate the environment's
   secrets and read each policy; a failed read is UNKNOWN, never absence. *)
let authorization_secret_bindings ~project ~environment =
  let resource_class = "authorization secret IAM binding" in
  let identity =
    Printf.sprintf
      "secret IAM bindings on secrets named sol-%s-* in %s"
      environment
      project
  in
  let attribution =
    Named_for_target
      (Printf.sprintf
         "the target's environment names the secret prefix sol-%s-"
         environment)
  in
  let checked_with = secret_bindings_checked_with ~project ~environment in
  let list_argv =
    [ "--project"
    ; project
    ; "secrets"
    ; "list"
    ; "--filter=name:sol-" ^ environment ^ "-"
    ; "--format=value(name)"
    ]
  in
  let gcloud_failure = function
    | Sol_cli_process.Non_zero r ->
      if String.trim r.stderr = ""
      then Printf.sprintf "gcloud exited %d" r.exit_code
      else String.trim r.stderr
    | _ -> "the gcloud CLI is unavailable"
  in
  match Sol_cli_process.run (Sol_cli_process.cmd ("gcloud" :: list_argv)) with
  | Error error ->
    Unobservable { resource_class; reason = gcloud_failure error; checked_with }
  | Ok { Sol_cli_process.stdout; stderr } ->
    if String.trim stderr <> ""
    then Unobservable { resource_class; reason = String.trim stderr; checked_with }
    else (
      let secrets = Sol_cli_absence.lines stdout in
      let rec read acc = function
        | [] -> Ok (List.rev acc)
        | secret :: rest ->
          let argv =
            [ "--project"; project; "secrets"; "get-iam-policy"; secret; "--format=json" ]
          in
          (match Sol_cli_process.run (Sol_cli_process.cmd ("gcloud" :: argv)) with
           | Error error -> Error (secret, gcloud_failure error)
           | Ok { Sol_cli_process.stdout; stderr } ->
             if String.trim stderr <> ""
             then Error (secret, String.trim stderr)
             else (
               match secret_binding_members ~project stdout with
               | Error reason -> Error (secret, reason)
               | Ok bindings ->
                 let found =
                   bindings
                   |> List.map (fun (role, member) ->
                     Printf.sprintf "%s: %s -> %s" secret role member)
                 in
                 read (List.rev_append found acc) rest))
      in
      match read [] secrets with
      | Error (secret, reason) ->
        Unobservable
          { resource_class
          ; reason = Printf.sprintf "secret %s: %s" secret reason
          ; checked_with
          }
      | Ok [] -> Absent { resource_class; identity; attribution; checked_with }
      | Ok found -> Present { resource_class; identity; found; attribution; checked_with })
;;

let strict_authorization observation =
  match observation with
  | Unobservable u ->
    Unobservable
      { u with
        resource_class = Sol_cli_absence.scope_class
      ; reason = u.resource_class ^ ": " ^ u.reason
      }
  | observation -> observation
;;

let prior_for class_name prior =
  List.assoc_opt class_name prior |> Option.value ~default:[]
;;

let filter_to_prior prior observation =
  match observation with
  | Present present ->
    let prior = List.map String.trim (prior_for present.resource_class prior) in
    let found =
      List.filter (fun item -> List.mem (String.trim item) prior) present.found
    in
    if found = []
    then
      Absent
        { resource_class = present.resource_class
        ; identity = present.identity
        ; attribution = present.attribution
        ; checked_with = present.checked_with
        }
    else Present { present with found }
  | observation -> observation
;;

let regional_address_checked_with ~project ~region =
  Printf.sprintf
    "gcloud compute addresses list --project %s --regions %s --format=json, then gcloud \
     compute forwarding-rules describe <rule> --project %s --region %s \
     --format=value(network) for each user of an address"
    project
    region
    project
    region
;;

let forwarding_rule_name user =
  match List.rev (String.split_on_char '/' user) with
  | name :: _ -> name
  | [] -> user
;;

let regional_address_observation
      ?(previously_attributed = [])
      ~project
      ~region
      ~cluster_name
      ()
  =
  let resource_class = "regional address" in
  let checked_with = regional_address_checked_with ~project ~region in
  let prior = prior_for resource_class previously_attributed in
  let open Result.Syntax in
  let network_of_rule rule =
    match
      Sol_cli_process.run
        (Sol_cli_process.cmd
           [ "gcloud"
           ; "compute"
           ; "forwarding-rules"
           ; "describe"
           ; rule
           ; "--project"
           ; project
           ; "--region"
           ; region
           ; "--format"
           ; "value(network)"
           ])
    with
    | Ok { Sol_cli_process.stdout; stderr } ->
      if not (benign_empty_list_warning stderr)
      then Error (String.trim stderr)
      else Ok (String.trim stdout)
    | Error (Sol_cli_process.Non_zero r) -> Error (String.trim r.stderr)
    | Error _ -> Error "the gcloud CLI is unavailable"
  in
  match
    Sol_cli_process.run
      (Sol_cli_process.cmd
         [ "gcloud"
         ; "compute"
         ; "addresses"
         ; "list"
         ; "--project"
         ; project
         ; "--regions"
         ; region
         ; "--format"
         ; "json"
         ])
  with
  | Error (Sol_cli_process.Non_zero r) ->
    Unobservable { resource_class; reason = String.trim r.stderr; checked_with }
  | Error _ ->
    Unobservable
      { resource_class; reason = "the gcloud CLI is unavailable"; checked_with }
  | Ok { Sol_cli_process.stdout; stderr } ->
    if not (benign_empty_list_warning stderr)
    then Unobservable { resource_class; reason = String.trim stderr; checked_with }
    else (
      match Sol_cli_json.decode ~what:"the regional address listing" stdout with
      | Error reason -> Unobservable { resource_class; reason; checked_with }
      | Ok json ->
        (match Sol_cli_json.list json with
         | None ->
           Unobservable
             { resource_class
             ; reason = "the regional address listing is not a list"
             ; checked_with
             }
         | Some addresses ->
           (match
              Sol_cli_result.map_list
                (fun address ->
                   let* name =
                     Sol_cli_json.require
                       ~what:"a regional address"
                       [ "name" ]
                       Sol_cli_json.string
                       address
                   in
                   if List.mem name prior
                   then Ok (Some name)
                   else (
                     let users =
                       match
                         Sol_cli_json.optional
                           ~what:"a regional address"
                           [ "users" ]
                           Sol_cli_json.list
                           address
                       with
                       | Error reason -> Error reason
                       | Ok None ->
                         (* Compute Engine documents `users` as an output-only,
                            repeated string field. Empty repeated fields are
                            omitted from JSON, so an absent field is a genuinely
                            empty relationship; a present non-list or a list with
                            a non-string entry is malformed, not empty. *)
                         Ok []
                       | Ok (Some users) ->
                         let rec strings acc = function
                           | [] -> Ok (List.rev acc)
                           | `String user :: rest -> strings (user :: acc) rest
                           | _ -> Error "a regional address has a non-string users entry"
                         in
                         strings [] users
                     in
                     let* users = users in
                     let rec attribute = function
                       | [] -> Ok None
                       | user :: rest ->
                         let* network = network_of_rule (forwarding_rule_name user) in
                         if String.ends_with ~suffix:("/" ^ cluster_name) network
                         then Ok (Some name)
                         else attribute rest
                     in
                     attribute users))
                addresses
            with
            | Error reason -> Unobservable { resource_class; reason; checked_with }
            | Ok found ->
              let found =
                List.filter_map (fun item -> item) found |> List.sort_uniq String.compare
              in
              let attribution =
                Within_target
                  (Printf.sprintf
                     "the target's own VPC: a regional address used by a forwarding rule \
                      in %s belongs to a service the target's cluster created"
                     cluster_name)
              in
              (match found with
               | [] ->
                 Absent
                   { resource_class
                   ; identity = "addresses in the target's VPC"
                   ; attribution
                   ; checked_with
                   }
               | found ->
                 Present
                   { resource_class
                   ; identity = "addresses in the target's VPC"
                   ; found
                   ; attribution
                   ; checked_with
                   }))))
;;

let observations
      ?(previously_attributed = [])
      ?(authorization_identities = [])
      ?(pre_destroy = Sol_cli_cloud_destroy.State_empty)
      (target : Sol_cli_config.target)
      ~cluster_name
  =
  let _ = pre_destroy in
  match project_of target with
  | None ->
    Sol_cli_absence.scope_failure ~reason:unlistable
    @ durable_observations ~target ~cluster_name
  | Some project ->
    let observations =
      List.map
        (fun check -> run ~previously_attributed ~check ())
        (checks ~project ~region:target.region ~cluster_name)
    in
    (* The authorization root's names are derived from the environment, not from
       the current trust declaration. A prior apply can have created them and a
       later target can have removed the trust, so an absent current declaration
       is not evidence that they are gone. Observe them unconditionally; a
       failed read is a scope failure, not absence. *)
    let observations =
      observations
      @ List.map
          (fun check ->
             strict_authorization_observation ~check
             |> filter_to_prior authorization_identities)
          (authorization_checks ~project ~target)
    in
    let observations =
      observations
      @ [ strict_authorization
            (authorization_secret_bindings ~project ~environment:target.env)
          |> filter_to_prior authorization_identities
        ]
    in
    let observations =
      observations
      @ [ regional_address_observation
            ~previously_attributed
            ~project
            ~region:target.region
            ~cluster_name
            ()
        ]
    in
    derived_by_vpc ~cluster_name observations @ durable_observations ~target ~cluster_name
;;

let substrate_absence (target : Sol_cli_config.target) ~cluster_name =
  match project_of target with
  | None ->
    (match Sol_cli_absence.scope_failure ~reason:unlistable with
     | [ observation ] -> observation
     | _ -> assert false)
  | Some project ->
    run ~check:(cluster_check ~project ~region:target.region ~cluster_name) ()
;;

let unresolved = Sol_cli_absence.unresolved

let authorization_state_identities
      ~(target : Sol_cli_config.target)
      (state : Sol_cli_cloud_destroy.state_read)
  =
  let resources = Sol_cli_cloud_destroy.resources state in
  let project =
    Option.value (Sol_cli_config.provider_field target "project_id") ~default:""
  in
  let service_accounts =
    resources
    |> List.filter_map (fun (resource : Sol_cli_cloud_destroy.resource) ->
      if String.equal resource.kind "google_service_account" then resource.email else None)
  in
  let custom_roles =
    resources
    |> List.filter_map (fun (resource : Sol_cli_cloud_destroy.resource) ->
      if String.equal resource.kind "google_project_iam_custom_role"
      then Option.map (fun name -> "projects/" ^ project ^ "/roles/" ^ name) resource.name
      else None)
  in
  let project_bindings =
    resources
    |> List.filter_map (fun (resource : Sol_cli_cloud_destroy.resource) ->
      if String.equal resource.kind "google_project_iam_member"
      then (
        match resource.role, resource.member with
        | Some role, Some member -> Some (role ^ "\t" ^ member)
        | _ -> None)
      else None)
  in
  let secret_bindings =
    resources
    |> List.filter_map (fun (resource : Sol_cli_cloud_destroy.resource) ->
      if String.equal resource.kind "google_secret_manager_secret_iam_member"
      then (
        match resource.secret_id, resource.role, resource.member with
        | Some secret, Some role, Some member ->
          Some (Printf.sprintf "%s: %s -> %s" (Filename.basename secret) role member)
        | _ -> None)
      else None)
  in
  [ "authorization service account", service_accounts
  ; "authorization custom role", custom_roles
  ; "authorization project IAM binding", project_bindings
  ; "authorization secret IAM binding", secret_bindings
  ]
;;
