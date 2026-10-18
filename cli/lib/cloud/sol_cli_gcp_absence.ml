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

let class_names =
  [ "GKE cluster"
  ; "GKE node pool"
  ; "VPC network"
  ; "subnetwork"
  ; "Cloud Router"
  ; "Cloud NAT"
  ; "Cloud SQL instance"
  ; "reserved global address"
  ; "Artifact Registry repository"
  ; "service account"
  ; "custom role"
  ; "storage bucket"
  ; "persistent disk"
  ; "firewall rule"
  ; "forwarding rule"
  ]
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

let observations
      ?(previously_attributed = [])
      (target : Sol_cli_config.target)
      ~cluster_name
  =
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
    let observations =
      if Sol_cli_provider_capabilities.authorization_trust target = None
      then observations
      else
        observations
        @ List.map
            (fun check -> strict_authorization_observation ~check)
            (authorization_checks ~project ~target)
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
