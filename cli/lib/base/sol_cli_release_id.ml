type workload =
  { domain : string
  ; name : string
  ; primitive : string
  ; image : string
  ; config : (string * string) list
  ; secrets : (string * string) list
  ; (* What the unit **declared** it uses (`uses: [app_db]`), captured at build time. A rollback
       re-resolves these against the current target's authorities and bindings -- storing a
       *resolution* here would freeze a historical answer the rollback cannot use, which is the
       conflation this field removes (#1422). *)
    uses : string list
  ; external_secret_refs : (string * string * string) list
  ; schedule : string option
  ; scheduled_concurrency : string
  ; backoff_limit : int
  ; replicas : int
  ; availability : string
  ; consumes_kafka : bool
  ; cpu : string
  ; memory : string
  ; extra_labels : (string * string) list
  ; volumes : (string * string * string * string) list
  ; rollout : string
  ; ingress_host : string option
  ; ingress_path : string option
  ; cluster_issuer : string
  ; calls : (string * string * string * string) list
  }

type contract_fact =
  { subject : string
  ; topic : string
  ; partitions : int
  ; key : string option
  ; schema_digest : string
  }

type content =
  { workspace : string
  ; environment : string option
  ; workloads : workload list
  ; contract : contract_fact list
  }

type t = string

(* v7 records each workload's declared requirements. A v6 record cannot answer "what did this
   version require?", so the version gate refuses it by name rather than letting a rollback guess
   -- see [Sol_cli_release.stale_encoding_version_message] (#1422). *)
let encoding_version = "sol-release-v7"

let enc_string b s =
  Buffer.add_string b (Printf.sprintf "%d:" (String.length s));
  Buffer.add_string b s
;;

let enc_int b n = Buffer.add_string b (Printf.sprintf "i%d;" n)

let enc_option enc b = function
  | None -> Buffer.add_char b 'n'
  | Some v ->
    Buffer.add_char b 's';
    enc b v
;;

let enc_pairs b pairs =
  let pairs = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs in
  enc_int b (List.length pairs);
  pairs
  |> List.iter (fun (k, v) ->
    enc_string b k;
    enc_string b v)
;;

let compare4 (a1, a2, a3, a4) (b1, b2, b3, b4) =
  let c = String.compare a1 b1 in
  if c <> 0
  then c
  else (
    let c = String.compare a2 b2 in
    if c <> 0
    then c
    else (
      let c = String.compare a3 b3 in
      if c <> 0 then c else String.compare a4 b4))
;;

let compare3 (a1, a2, a3) (b1, b2, b3) =
  let c = String.compare a1 b1 in
  if c <> 0
  then c
  else (
    let c = String.compare a2 b2 in
    if c <> 0 then c else String.compare a3 b3)
;;

let enc_table b rows =
  enc_int b (List.length rows);
  rows
  |> List.iter (fun row ->
    enc_int b (List.length row);
    List.iter (enc_string b) row)
;;

let enc_workload b (w : workload) =
  enc_string b w.domain;
  enc_string b w.name;
  enc_string b w.primitive;
  enc_string b w.image;
  enc_pairs b w.config;
  enc_pairs b w.secrets;
  enc_table b (List.map (fun u -> [ u ]) (List.sort String.compare w.uses));
  enc_table
    b
    (List.map
       (fun (key, store, remote) -> [ key; store; remote ])
       (List.sort compare3 w.external_secret_refs));
  enc_option enc_string b w.schedule;
  enc_string b w.scheduled_concurrency;
  enc_int b w.backoff_limit;
  enc_int b w.replicas;
  enc_string b w.availability;
  enc_int b (if w.consumes_kafka then 1 else 0);
  enc_string b w.cpu;
  enc_string b w.memory;
  enc_pairs b w.extra_labels;
  enc_table
    b
    (List.map (fun (n, m, s, a) -> [ n; m; s; a ]) (List.sort compare4 w.volumes));
  enc_string b w.rollout;
  enc_option enc_string b w.ingress_host;
  enc_option enc_string b w.ingress_path;
  enc_string b w.cluster_issuer;
  enc_table
    b
    (List.map (fun (e, d, n, ns) -> [ e; d; n; ns ]) (List.sort compare4 w.calls))
;;

let compare_workload_spec a b =
  let by_domain = String.compare a.domain b.domain in
  if by_domain <> 0
  then by_domain
  else (
    let by_name = String.compare a.name b.name in
    if by_name <> 0 then by_name else String.compare a.primitive b.primitive)
;;

let compare_contract_fact a b = String.compare a.subject b.subject

let enc_contract_fact b (f : contract_fact) =
  enc_string b f.subject;
  enc_string b f.topic;
  enc_int b f.partitions;
  enc_option enc_string b f.key;
  enc_string b f.schema_digest
;;

let canonical_string (content : content) =
  let b = Buffer.create 256 in
  enc_string b encoding_version;
  enc_string b content.workspace;
  enc_option enc_string b content.environment;
  let workloads = List.sort compare_workload_spec content.workloads in
  enc_int b (List.length workloads);
  workloads |> List.iter (enc_workload b);
  let contract = List.sort compare_contract_fact content.contract in
  enc_int b (List.length contract);
  contract |> List.iter (enc_contract_fact b);
  Buffer.contents b
;;

type owned_object =
  { resource : string
  ; namespace : string
  ; name : string
  ; uid : string
  }

type recorded_workload =
  { spec : workload
  ; applied_by : string
  ; owned : owned_object list
  }

let boundary_encoding_version = "sol-boundary-v1"

let of_content (content : content) =
  let hex = Digest.to_hex (Digest.string (canonical_string content)) in
  "r-" ^ String.sub hex 0 16
;;

let of_recorded_boundary
      ~workspace
      ~environment
      ~contract
      (workloads : recorded_workload list)
  =
  let specs = List.map (fun w -> w.spec) workloads in
  let content_id = of_content { workspace; environment; workloads = specs; contract } in
  if List.for_all (fun w -> String.equal w.applied_by content_id) workloads
  then content_id
  else (
    let b = Buffer.create 256 in
    enc_string b boundary_encoding_version;
    enc_string b workspace;
    enc_option enc_string b environment;
    let workloads =
      List.sort (fun a c -> compare_workload_spec a.spec c.spec) workloads
    in
    enc_int b (List.length workloads);
    workloads
    |> List.iter (fun w ->
      enc_workload b w.spec;
      enc_string b w.applied_by);
    "r-" ^ String.sub (Digest.to_hex (Digest.string (Buffer.contents b))) 0 16)
;;

let of_boundary
      ~workspace
      ~environment
      ~contract
      ~(deployed : workload list)
      ~(inherited : (workload * string) list)
  =
  let applied_by =
    of_content { workspace; environment; workloads = deployed; contract }
  in
  let workloads =
    List.map (fun spec -> { spec; applied_by; owned = [] }) deployed
    @ List.map (fun (spec, applied_by) -> { spec; applied_by; owned = [] }) inherited
  in
  of_recorded_boundary ~workspace ~environment ~contract workloads
;;

let to_string (t : t) = t
let is_lower_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

let of_string s =
  let expected = "r-<16 lowercase hex>" in
  let bad () = Error (Printf.sprintf "%S is not a release id (expected %s)" s expected) in
  if String.length s <> 18
  then bad ()
  else if String.sub s 0 2 <> "r-"
  then bad ()
  else (
    let ok = ref true in
    for i = 2 to String.length s - 1 do
      if not (is_lower_hex s.[i]) then ok := false
    done;
    if !ok then Ok s else bad ())
;;
