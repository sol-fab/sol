open Qual_domain

type resource =
  | Deployment
  | Job
  | Configmap

type query =
  { resource : resource
  ; namespace : string
  ; name : string
  ; requirement : string
  ; subject : string
  ; target : kube_target
  }

type command_result =
  | Exited of
      { code : int
      ; stdout : string
      ; stderr : string
      }
  | Timed_out of string
  | Signaled of int * string
  | Spawn_failed of string

type reply =
  { context : read_context
  ; result : command_result
  }

type observation =
  | Deployment_read of pod_template kube_read
  | Job_read of pod_template kube_read
  | Configmap_read of ca_configmap kube_read

let queries requirement =
  let b = ca_binding requirement in
  let make resource name =
    { resource
    ; namespace = b.namespace
    ; name
    ; requirement = instance_identity b.instance
    ; subject = b.subject
    ; target = b.target
    }
  in
  make Deployment b.workload, make Configmap b.configmap
;;

let migration_queries requirement (execution : job_identity) =
  let b = migration_ca_binding requirement in
  let make resource name =
    { resource
    ; namespace = b.namespace
    ; name
    ; requirement = instance_identity b.instance
    ; subject = b.subject
    ; target = b.target
    }
  in
  make Job execution.name, make Configmap b.configmap
;;

exception Invalid of string

let invalid message = raise (Invalid message)

let object_fields = function
  | `Assoc xs -> xs
  | _ -> invalid "expected JSON object"
;;

let field key json = List.assoc_opt key (object_fields json)

let required key json =
  match field key json with
  | Some v -> v
  | None -> invalid ("missing " ^ key)
;;

let text = function
  | `String s when String.trim s <> "" -> s
  | _ -> invalid "expected nonempty string"
;;

let string key json = text (required key json)

let list = function
  | `List xs -> xs
  | _ -> invalid "expected JSON array"
;;

let optional key json =
  match field key json with
  | None | Some `Null -> None
  | Some value -> Some value
;;

let optional_text key json = Option.map text (optional key json)

let optional_list key json =
  match optional key json with
  | None -> []
  | Some xs -> list xs
;;

let unique xs = List.length xs = List.length (List.sort_uniq compare xs)
let check_unique what xs = if not (unique xs) then invalid ("duplicate " ^ what)

let rec check_json = function
  | `Assoc fields ->
    check_unique "JSON field" (List.map fst fields);
    List.iter (fun (_, v) -> check_json v) fields
  | `List xs -> List.iter check_json xs
  | _ -> ()
;;

let parsed decode json =
  try
    check_json json;
    Ok (decode json)
  with
  | Invalid message -> Error message
;;

let metadata json =
  let metadata = required "metadata" json in
  ( string "namespace" metadata
  , string "name" metadata
  , string "uid" metadata
  , string "resourceVersion" metadata )
;;

let relative path =
  if not (canonical_path ~absolute:false path)
  then invalid "unsupported relative volume path"
  else path
;;

let absolute path =
  if path <> "/" && not (canonical_path ~absolute:true path)
  then invalid "unsupported absolute mount path"
  else path
;;

let volume json : ca_volume =
  let volume_name = string "name" json in
  match optional "configMap" json with
  | None ->
    let sources = List.filter (fun (name, _) -> name <> "name") (object_fields json) in
    if List.length sources <> 1 then invalid "missing or ambiguous volume source";
    ignore (object_fields (snd (List.hd sources)));
    if optional "projected" json <> None
    then invalid "projected volume sources are unsupported in I3";
    { volume_name; source_configmap = None; items = None }
  | Some source ->
    if
      List.exists
        (fun (key, _) -> key <> "name" && key <> "configMap")
        (object_fields json)
    then invalid "ambiguous ConfigMap volume source";
    let source_configmap = Some (string "name" source) in
    let items =
      Option.map
        (fun xs ->
           let items =
             List.map
               (fun item -> string "key" item, relative (string "path" item))
               (list xs)
           in
           check_unique "volume item key" (List.map fst items);
           check_unique "volume item path" (List.map snd items);
           items)
        (optional "items" source)
    in
    { volume_name; source_configmap; items }
;;

let mount json : ca_mount =
  let volume_name = string "name" json in
  let path = absolute (string "mountPath" json) in
  let sub_path = Option.map relative (optional_text "subPath" json) in
  let sub_path_expr = optional_text "subPathExpr" json in
  if sub_path <> None && sub_path_expr <> None
  then invalid "conflicting subPath and subPathExpr";
  { volume_name; path; sub_path; sub_path_expr }
;;

let container json =
  let container_name = string "name" json in
  let mounts = List.map mount (optional_list "volumeMounts" json) in
  check_unique "container mount path" (List.map (fun (m : ca_mount) -> m.path) mounts);
  { container_name; mounts }
;;

let template_with ~api_version ~kind decode_volume json : pod_template =
  if string "apiVersion" json <> api_version || string "kind" json <> kind
  then invalid ("expected " ^ api_version ^ " " ^ kind);
  let namespace, name, uid, resource_version = metadata json in
  let spec = required "spec" (required "template" (required "spec" json)) in
  let volumes = List.map decode_volume (optional_list "volumes" spec) in
  let containers = List.map container (list (required "containers" spec)) in
  if containers = [] then invalid (kind ^ " has no containers");
  check_unique "volume name" (List.map (fun (v : ca_volume) -> v.volume_name) volumes);
  check_unique "container name" (List.map (fun c -> c.container_name) containers);
  { namespace; name; uid; resource_version; volumes; containers }
;;

let deployment = template_with ~api_version:"apps/v1" ~kind:"Deployment" volume
let job = template_with ~api_version:"batch/v1" ~kind:"Job" volume

let stored_volume json : ca_volume =
  let volume_name = string "name" json in
  let source_configmap = optional_text "source_configmap" json in
  let items =
    Option.map
      (fun xs ->
         let items =
           List.map
             (fun item -> string "key" item, relative (string "path" item))
             (list xs)
         in
         check_unique "volume item key" (List.map fst items);
         check_unique "volume item path" (List.map snd items);
         items)
      (optional "items" json)
  in
  { volume_name; source_configmap; items }
;;

let stored_deployment =
  template_with ~api_version:"apps/v1" ~kind:"Deployment" stored_volume
;;

let stored_job = template_with ~api_version:"batch/v1" ~kind:"Job" stored_volume

let configmap json : ca_configmap =
  if string "apiVersion" json <> "v1" || string "kind" json <> "ConfigMap"
  then invalid "expected v1 ConfigMap";
  let namespace, name, uid, resource_version = metadata json in
  if optional "binaryData" json <> None
  then invalid "binary ConfigMap data is unsupported in I3";
  let entries =
    match optional "data" json with
    | None -> []
    | Some data ->
      List.map
        (fun (key, value) ->
           match value with
           | `String value -> key, String.trim value <> ""
           | _ -> invalid "ConfigMap data must be strings")
        (object_fields data)
  in
  { namespace; name; uid; resource_version; entries }
;;

let native_read resource decode json =
  let expected_list, version =
    match resource with
    | Deployment -> "DeploymentList", "apps/v1"
    | Job -> "JobList", "batch/v1"
    | Configmap -> "ConfigMapList", "v1"
  in
  (* `kubectl get <resource> --field-selector ... -o json` returns the generic
     `List` envelope (`apiVersion: v1`), not the typed `JobList`/`ConfigMapList`.
     Both carry the same `items`; accept either, and check each envelope's own
     API version. *)
  let kind = optional_text "kind" json in
  if kind <> Some expected_list && kind <> Some "List"
  then Present (decode json)
  else (
    let api_version = string "apiVersion" json in
    (match kind with
     | Some expected when expected = expected_list ->
       if api_version <> version then invalid "wrong list API version"
     | Some "List" -> if api_version <> "v1" then invalid "wrong generic list API version"
     | _ -> assert false);
    let metadata = required "metadata" json in
    ignore (string "resourceVersion" metadata);
    (match optional "continue" metadata with
     | None | Some (`String "") -> ()
     | _ -> invalid "incomplete list continuation");
    (match optional "remainingItemCount" metadata with
     | None | Some (`Int 0) -> ()
     | _ -> invalid "incomplete remaining item count");
    match list (required "items" json) with
    | [] -> Absent
    | [ item ] -> Present (decode item)
    | _ -> invalid "exact namespaced read returned multiple objects")
;;

let state resource decode = function
  | Timed_out diagnostic -> Unreadable ("timeout: " ^ diagnostic)
  | Signaled (signal, diagnostic) ->
    Unreadable ("signal " ^ string_of_int signal ^ ": " ^ diagnostic)
  | Spawn_failed diagnostic -> Unreadable ("spawn failure: " ^ diagnostic)
  | Exited { code; stderr; _ } when code <> 0 ->
    Unreadable ("exit " ^ string_of_int code ^ ": " ^ stderr)
  | Exited { stdout; _ } ->
    if String.length stdout > 1024 * 1024
    then Unreadable "Kubernetes response exceeds bounded capture size"
    else (
      try
        match parsed (native_read resource decode) (Yojson.Safe.from_string stdout) with
        | Ok state -> state
        | Error message -> Unreadable message
      with
      | Yojson.Json_error _ -> Unreadable "invalid Kubernetes JSON")
;;

let classify query reply =
  let wrap state =
    { requirement = query.requirement
    ; subject = query.subject
    ; context = reply.context
    ; state
    }
  in
  match query.resource with
  | Deployment -> Deployment_read (wrap (state Deployment deployment reply.result))
  | Job -> Job_read (wrap (state Job job reply.result))
  | Configmap -> Configmap_read (wrap (state Configmap configmap reply.result))
;;

let option_json encode = function
  | None -> `Null
  | Some x -> encode x
;;

let json_string s = `String s

let metadata_json namespace name uid version =
  `Assoc
    [ "namespace", `String namespace
    ; "name", `String name
    ; "uid", `String uid
    ; "resourceVersion", `String version
    ]
;;

let template_json ~api_version ~kind (d : pod_template) =
  let volume (v : ca_volume) =
    `Assoc
      [ "name", `String v.volume_name
      ; "source_configmap", option_json json_string v.source_configmap
      ; ( "items"
        , option_json
            (fun xs ->
               `List
                 (List.map
                    (fun (key, path) ->
                       `Assoc [ "key", `String key; "path", `String path ])
                    xs))
            v.items )
      ]
  in
  let mount (m : ca_mount) =
    `Assoc
      [ "name", `String m.volume_name
      ; "mountPath", `String m.path
      ; "subPath", option_json json_string m.sub_path
      ; "subPathExpr", option_json json_string m.sub_path_expr
      ]
  in
  `Assoc
    [ "apiVersion", `String api_version
    ; "kind", `String kind
    ; "metadata", metadata_json d.namespace d.name d.uid d.resource_version
    ; ( "spec"
      , `Assoc
          [ ( "template"
            , `Assoc
                [ ( "spec"
                  , `Assoc
                      [ "volumes", `List (List.map volume d.volumes)
                      ; ( "containers"
                        , `List
                            (List.map
                               (fun c ->
                                  `Assoc
                                    [ "name", `String c.container_name
                                    ; "volumeMounts", `List (List.map mount c.mounts)
                                    ])
                               d.containers) )
                      ] )
                ] )
          ] )
    ]
;;

let configmap_json (c : ca_configmap) =
  `Assoc
    [ "metadata", metadata_json c.namespace c.name c.uid c.resource_version
    ; ( "entries"
      , `List
          (List.map
             (fun (key, nonempty) ->
                `Assoc [ "key", `String key; "nonempty", `Bool nonempty ])
             c.entries) )
    ]
;;

let stored_configmap json : ca_configmap =
  let namespace, name, uid, resource_version = metadata json in
  let entries =
    List.map
      (fun entry ->
         let key = string "key" entry in
         match required "nonempty" entry with
         | `Bool value -> key, value
         | _ -> invalid "invalid key projection")
      (list (required "entries" json))
  in
  check_unique "projected ConfigMap key" (List.map fst entries);
  { namespace; name; uid; resource_version; entries }
;;

let encode observation =
  let encode resource encode read =
    let state =
      match read.state with
      | Absent -> `Assoc [ "status", `String "ABSENT" ]
      | Unreadable message ->
        `Assoc [ "status", `String "UNKNOWN"; "diagnostic", `String message ]
      | Present value -> `Assoc [ "status", `String "PRESENT"; "object", encode value ]
    in
    `Assoc
      [ "schema", `Int 1
      ; "resource", `String resource
      ; "requirement", `String read.requirement
      ; "context", read_context_json read.context
      ; "observation", state
      ]
  in
  match observation with
  | Deployment_read read ->
    encode "Deployment" (template_json ~api_version:"apps/v1" ~kind:"Deployment") read
  | Job_read read -> encode "Job" (template_json ~api_version:"batch/v1" ~kind:"Job") read
  | Configmap_read read -> encode "ConfigMap" configmap_json read
;;

let decode (captured : Qual_evidence.captured) =
  parsed
    (fun json ->
       if required "schema" json <> `Int 1
       then invalid "unsupported Kubernetes projection schema";
       let requirement = string "requirement" json in
       let context =
         match read_context_of_json (required "context" json) with
         | Ok c -> c
         | Error e -> invalid e
       in
       let state decode =
         let observation = required "observation" json in
         match string "status" observation with
         | "ABSENT" -> Absent
         | "UNKNOWN" -> Unreadable (string "diagnostic" observation)
         | "PRESENT" -> Present (decode (required "object" observation))
         | _ -> invalid "invalid observation status"
       in
       let wrap state = { requirement; subject = captured.subject; context; state } in
       match string "resource" json with
       | "Deployment" -> Deployment_read (wrap (state stored_deployment))
       | "Job" -> Job_read (wrap (state stored_job))
       | "ConfigMap" -> Configmap_read (wrap (state stored_configmap))
       | _ -> invalid "unknown Kubernetes projection resource")
    captured.payload
;;
