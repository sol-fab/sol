(* Test-only helper: print the release-boundary ConfigMaps a workspace would have written at
   apply, so an offline fake cluster can serve the recorded UID evidence the removal paths
   require (docs/architecture/ownership.md). It builds the record through the real
   serializer and digest (Sol_cli_release) rather than a hand-written fixture, so the record
   cannot drift from the CLI's own format. Not shipped; used by the internal/ci lifecycle
   harness alongside print_providers.exe / print_readiness_invocations.exe. *)

let fail message =
  prerr_endline ("print_release_record: " ^ message);
  exit 1
;;

let owned_of_arg value =
  match String.split_on_char ':' value with
  | [ resource; namespace; name; uid ]
    when resource <> "" && namespace <> "" && name <> "" && uid <> "" ->
    { Sol_cli_release_id.resource; namespace; name; uid }
  | _ -> fail (Printf.sprintf "each --own is RESOURCE:NAMESPACE:NAME:UID, got %S" value)
;;

(* The workload spec is not what the removal path reads (it reads [owned]); it only has to be
   a consistent spec so the record's content-addressed id rederives. *)
let workload_of_owned (o : Sol_cli_release_id.owned_object) : Sol_cli_release_id.workload =
  { domain = "test"
  ; name = o.name
  ; primitive = "svc"
  ; image = "registry.example.com/test/" ^ o.name ^ ":abc123"
  ; config = []
  ; secrets = []
  ; uses = []
  ; external_secret_refs = []
  ; schedule = None
  ; scheduled_concurrency = "allow"
  ; backoff_limit = 3
  ; replicas = 1
  ; availability = "single"
  ; consumes_kafka = false
  ; cpu = "100m"
  ; memory = "128Mi"
  ; extra_labels = []
  ; volumes = []
  ; rollout = "none"
  ; ingress_host = None
  ; ingress_path = None
  ; cluster_issuer = "letsencrypt-prod"
  ; calls = []
  }
;;

let () =
  let workspace = ref None
  and out = ref None
  and owned = ref [] in
  let rec parse = function
    | [] -> ()
    | "--workspace" :: value :: rest ->
      workspace := Some value;
      parse rest
    | "--out" :: value :: rest ->
      out := Some value;
      parse rest
    | "--own" :: value :: rest ->
      owned := owned_of_arg value :: !owned;
      parse rest
    | arg :: _ -> fail (Printf.sprintf "unexpected argument %S" arg)
  in
  parse (List.tl (Array.to_list Sys.argv));
  let workspace =
    match !workspace with
    | Some workspace -> workspace
    | None -> fail "--workspace is required"
  in
  let out =
    match !out with
    | Some out -> out
    | None -> fail "--out is required"
  in
  let owned = List.rev !owned in
  let specs = List.map workload_of_owned owned in
  (* A direct deploy: every workload was applied by this release, so the id is the plain
     content id and [of_recorded_boundary] rederives it (see Sol_cli_release_id). *)
  let release_id =
    Sol_cli_release_id.of_content
      { workspace; environment = None; workloads = specs; contract = [] }
    |> Sol_cli_release_id.to_string
  in
  let workloads =
    List.map2
      (fun spec o -> { Sol_cli_release_id.spec; applied_by = release_id; owned = [ o ] })
      specs
      owned
  in
  let record : Sol_cli_release.t =
    { release_id
    ; workspace
    ; environment = None
    ; workloads
    ; migrations = []
    ; contract = []
    ; apply_mode = Sol_cli_release.Direct
    ; encoding_version = Some Sol_cli_release_id.encoding_version
    }
  in
  let write name body =
    let oc = open_out (Filename.concat out name) in
    output_string oc body;
    close_out oc
  in
  let record_name = Sol_cli_release.configmap_name record in
  let record_body = Sol_cli_release.to_configmap_json record in
  let current_name = Sol_cli_release.current_configmap_name ~workspace in
  let current_body = Sol_cli_release.to_current_configmap_json record in
  write record_name record_body;
  write current_name current_body;
  (* Prove the seeded ConfigMaps read back through the CLI's own reader, so a harness that
     serves them cannot fail on a fixture-shaped surprise instead of the behaviour it tests. *)
  (match Sol_cli_json.decode ~what:record_name record_body with
   | Error message -> fail message
   | Ok json ->
     (match Sol_cli_release.of_kubectl_item json with
      | Ok parsed when String.equal parsed.Sol_cli_release.release_id release_id -> ()
      | Ok parsed ->
        fail
          (Printf.sprintf
             "%s rederived release %s"
             record_name
             parsed.Sol_cli_release.release_id)
      | Error message -> fail message));
  (match Sol_cli_json.decode ~what:current_name current_body with
   | Error message -> fail message
   | Ok json ->
     (match Sol_cli_json.field [ "data"; "release_id" ] json |> Sol_cli_json.string with
      | Some id when String.equal id release_id -> ()
      | _ -> fail (Printf.sprintf "%s does not name release %s" current_name release_id)));
  print_endline release_id
;;
