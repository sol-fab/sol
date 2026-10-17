open Sol_cli_absence
open Result.Syntax

type parent =
  { parent_class : string
  ; parent_identity : string
  }

type check =
  { resource_class : string
  ; identity : string
  ; attribution : attribution
  ; argv : string list
  ; attributable : string -> bool
  ; parent : parent option
  }

let identity_check
      ?(attributable = fun _ -> true)
      ?parent
      ~resource_class
      ~identity
      ~attribution
      argv
  =
  { resource_class; identity; attribution; argv; attributable; parent }
;;

let ok_observation ~checked_with ~check found =
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

type scope =
  { project : string
  ; region : string
  ; caller : string option
  }

let run_checked argv =
  let command = "gcloud " ^ String.concat " " argv in
  match Sol_cli_process.run (Sol_cli_process.cmd ("gcloud" :: argv)) with
  | Ok { Sol_cli_process.stdout; _ } -> Ok (String.trim stdout)
  | Error (Sol_cli_process.Non_zero r) ->
    Error (Printf.sprintf "%s exited %d: %s" command r.exit_code (String.trim r.stderr))
  | Error error ->
    Error
      (Printf.sprintf
         "%s could not run: %s"
         command
         (Sol_cli_process.error_to_string error))
;;

let establish_scope ~project ~region =
  let* project_id =
    run_checked
      [ "--project"
      ; project
      ; "projects"
      ; "describe"
      ; project
      ; "--format"
      ; "value(projectId)"
      ]
  in
  if not (String.equal project_id project)
  then
    Error
      (Printf.sprintf
         "gcloud answered project %S for the target's declared project %S, so the \
          inventory cannot say which project it would be reading"
         project_id
         project)
  else
    let* region_name =
      run_checked
        [ "--project"
        ; project
        ; "compute"
        ; "regions"
        ; "describe"
        ; region
        ; "--format"
        ; "value(name)"
        ]
    in
    if not (String.equal region_name region)
    then
      Error
        (Printf.sprintf
           "gcloud answered region %S for the target's declared region %S, so the \
            inventory cannot say which region it would be reading"
           region_name
           region)
    else (
      let caller =
        match
          run_checked
            [ "auth"; "list"; "--filter=status:ACTIVE"; "--format=value(account)" ]
        with
        | Ok answer when answer <> "" -> Some answer
        | Ok _ | Error _ -> None
      in
      Ok { project; region; caller })
;;

let scope_checked_with scope argv =
  Printf.sprintf
    "gcloud %s (project %s, region %s%s)"
    (String.concat " " argv)
    scope.project
    scope.region
    (match scope.caller with
     | None -> ""
     | Some caller -> ", caller " ^ caller)
;;

let parent_is_absent ~observations = function
  | None -> false
  | Some { parent_class; parent_identity } ->
    List.exists
      (function
        | Absent { resource_class; identity; _ } ->
          String.equal resource_class parent_class
          && String.equal identity parent_identity
        | _ -> false)
      observations
;;

let run ~scope ~observations ~check =
  let checked_with = scope_checked_with scope check.argv in
  match Sol_cli_process.run (Sol_cli_process.cmd ("gcloud" :: check.argv)) with
  | Ok { Sol_cli_process.stdout; _ } ->
    ok_observation ~checked_with ~check (lines stdout |> List.filter check.attributable)
  | Error (Sol_cli_process.Non_zero r) ->
    if parent_is_absent ~observations check.parent
    then
      Absent
        { resource_class = check.resource_class
        ; identity = check.identity
        ; attribution = check.attribution
        ; checked_with =
            Printf.sprintf
              "%s (its parent %s %s is positively absent, so it cannot exist; gcloud \
               said: %s)"
              checked_with
              (match check.parent with
               | None -> ""
               | Some parent -> parent.parent_class)
              (match check.parent with
               | None -> ""
               | Some parent -> parent.parent_identity)
              (String.trim r.stderr)
        }
    else
      Unobservable
        { resource_class = check.resource_class
        ; reason = String.trim r.stderr
        ; checked_with
        }
  | Error _ ->
    Unobservable
      { resource_class = check.resource_class
      ; reason = "the gcloud CLI is unavailable"
      ; checked_with
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
  let named ~resource_class ~identity ?parent ?(prefix = cluster_name ^ "-") argv =
    identity_check
      ?parent
      ~resource_class
      ~identity
      ~attribution:(Named_for_target (names_the_cluster cluster_name))
      ~attributable:(fun line ->
        line = cluster_name
        || (prefix <> "" && Sol_cli_string.contains ~needle:prefix line))
      argv
  in
  [ cluster_check ~project ~region ~cluster_name
  ; identity_check
      ~parent:{ parent_class = "GKE cluster"; parent_identity = cluster_name }
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
      ~parent:
        { parent_class = "Cloud Router"; parent_identity = cluster_name ^ "-router" }
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
      ~identity:
        ("sol_"
         ^ String.map
             (function
               | '-' -> '_'
               | c -> c)
             cluster_name
         ^ "_*")
      ~attribution:(Named_for_target (names_the_cluster cluster_name))
      ~attributable:(fun line ->
        Sol_cli_string.contains
          ~needle:
            ("sol_"
             ^ String.map
                 (function
                   | '-' -> '_'
                   | c -> c)
                 cluster_name
             ^ "_")
          line)
      (p [ "iam"; "roles"; "list"; "--format"; "value(name)" ])
  ; named
      ~resource_class:"storage bucket"
      ~identity:(cluster_name ^ "-*")
      (p [ "storage"; "buckets"; "list"; "--format"; "value(name)" ])
  ; named
      ~resource_class:"persistent disk"
      ~identity:("gke-" ^ cluster_name ^ "-*")
      ~prefix:("gke-" ^ cluster_name ^ "-")
      (p [ "compute"; "disks"; "list"; "--format"; "value(name)" ])
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

let run_checks ~scope checks =
  let rec go observations = function
    | [] -> List.rev observations
    | check :: rest ->
      let observation = run ~scope ~observations ~check in
      go (observation :: observations) rest
  in
  go [] checks
;;

let scope_failure ~project ~region reason =
  Unobservable
    { resource_class = Sol_cli_absence.scope_class
    ; reason
    ; checked_with =
        Printf.sprintf
          "gcloud --project %s projects describe %s --format=value(projectId); gcloud \
           --project %s compute regions describe %s --format=value(name)"
          project
          project
          project
          region
    }
;;

let observations (target : Sol_cli_config.target) ~cluster_name =
  match project_of target with
  | None ->
    Unobservable
      { resource_class = "the provider inventory"
      ; reason = unlistable
      ; checked_with = "gcloud (not run)"
      }
    :: durable_observations ~target ~cluster_name
  | Some project ->
    (match establish_scope ~project ~region:target.region with
     | Error reason ->
       [ scope_failure ~project ~region:target.region reason ]
       @ durable_observations ~target ~cluster_name
     | Ok scope ->
       let observations =
         run_checks ~scope (checks ~project ~region:target.region ~cluster_name)
       in
       derived_by_vpc ~cluster_name observations
       @ durable_observations ~target ~cluster_name)
;;

let substrate_absence (target : Sol_cli_config.target) ~cluster_name =
  match project_of target with
  | None ->
    Unobservable
      { resource_class = "GKE cluster"
      ; reason = unlistable
      ; checked_with = "gcloud (not run)"
      }
  | Some project ->
    (match establish_scope ~project ~region:target.region with
     | Error reason -> scope_failure ~project ~region:target.region reason
     | Ok scope ->
       run
         ~scope
         ~observations:[]
         ~check:(cluster_check ~project ~region:target.region ~cluster_name))
;;

let unresolved = Sol_cli_absence.unresolved
