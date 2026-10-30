type topic_name = string

let topic_name name =
  Kafka.Topic_name.of_string name |> Result.map Kafka.Topic_name.to_string
;;

let topic_name_exn name =
  match topic_name name with
  | Ok topic -> topic
  | Error e ->
    invalid_arg ("invalid Kafka topic name " ^ Printf.sprintf "%S" name ^ ": " ^ e)
;;

let topic_name_to_string topic = topic

module type MESSAGE = sig
  type t

  val topic_name : topic_name
  val schema : string
  val partitions : int
  val key : t -> string option
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end

type 'a topic =
  { name : topic_name
  ; schema_id : int
  ; partitions : int
  ; key : 'a -> string option
  ; encode : 'a -> Yojson.Safe.t
  ; decode : Yojson.Safe.t -> ('a, string) result
  }

type topic_durability =
  | Broker_default
  | Single_broker_loss

type config =
  { brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; linger_ms : int
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type t =
  { producer : Kafka.Producer.t
  ; brokers : string list
  ; schema_registry_url : string
  ; admin_url : string
  ; topic_durability : topic_durability
  ; security : Kafka.Security.t
  }

type decode_error_policy =
  | Route_to_dlq
  | Ack_and_drop

let ensure_topic producer ~topic_name ~partitions ~topic_durability =
  let replication_factor =
    match topic_durability with
    | Broker_default -> 1
    | Single_broker_loss -> 3
  in
  Kafka.Producer.create_topic producer ~topic_name ~partitions ~replication_factor
;;

type topic_partition_metadata =
  | Topic_not_found
  | Topic_partitions of
      { partitions : int
      ; replication_factor : int
      }

let topic_has_required_replication topic_durability = function
  | Topic_not_found -> true
  | Topic_partitions { replication_factor; _ } ->
    (match topic_durability with
     | Broker_default -> true
     | Single_broker_loss -> replication_factor >= 3)
;;

type topic_partition_error =
  | Topic_admin_request_failed of string
  | Topic_admin_unexpected_status of int * string
  | Topic_admin_malformed_response of string

let topic_partition_error_to_string = function
  | Topic_admin_request_failed e -> "admin API request failed: " ^ e
  | Topic_admin_unexpected_status (status, body) ->
    Printf.sprintf "admin API HTTP %d: %s" status body
  | Topic_admin_malformed_response body -> "malformed admin API topic response: " ^ body
;;

let decode_topic_partitions body =
  let malformed = Topic_admin_malformed_response body in
  let open Result.Syntax in
  let partition_replicas (json : Yojson.Safe.t) =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "partition_id" fields, List.assoc_opt "replicas" fields with
       | Some (`Int partition_id), Some (`List (_ :: _ as replicas)) ->
         let* node_ids =
           List.fold_left
             (fun acc replica ->
                let* acc = acc in
                match replica with
                | `Assoc fields ->
                  (match List.assoc_opt "node_id" fields with
                   | Some (`Int node_id) -> Ok (node_id :: acc)
                   | Some _ | None -> Error malformed)
                | _ -> Error malformed)
             (Ok [])
             replicas
         in
         Ok (partition_id, List.rev node_ids)
       | _ -> Error malformed)
    | _ -> Error malformed
  in
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> Error malformed
  | `List (_ :: _ as parts) ->
    let* records =
      List.fold_left
        (fun acc part ->
           let* acc = acc in
           let* record = partition_replicas part in
           Ok (record :: acc))
        (Ok [])
        parts
    in
    let records = List.rev records in
    let partition_ids = List.map fst records in
    let replicas = List.map snd records in
    let distinct xs = List.length xs = List.length (List.sort_uniq Int.compare xs) in
    if distinct partition_ids && List.for_all distinct replicas
    then
      Ok
        (Topic_partitions
           { partitions = List.length records
           ; replication_factor =
               List.fold_left
                 (fun acc node_ids -> min acc (List.length node_ids))
                 max_int
                 replicas
           })
    else Error malformed
  | _ -> Error malformed
;;

let query_topic_partitions ?ca_file net ~clock ~admin_url ~topic_name =
  match
    Kafka_service_http.http_get
      ?ca_file
      net
      ~clock
      ~base_url:admin_url
      ~path:(Printf.sprintf "/v1/partitions/kafka/%s" topic_name)
  with
  | Error e -> Error (Topic_admin_request_failed e)
  | Ok (404, _) -> Ok Topic_not_found
  | Ok (200, body) -> decode_topic_partitions body
  | Ok (status, body) -> Error (Topic_admin_unexpected_status (status, body))
;;

let observe_decode_error ~ot ~topic_name =
  let decode_err_count =
    match ot with
    | None -> None
    | Some o ->
      Some
        (Obs_eio.register_counter
           o
           ~name:"sol_worker_decode_errors_total"
           ~help:
             "Total source-topic Kafka messages that failed to decode (dead-lettered or \
              acked-and-dropped, per the decode_error_policy)"
           ~label_names:[])
  in
  fun e ~raw_bytes ~disposition ->
    (match decode_err_count with
     | Some c -> c 1
     | None -> ());
    match ot with
    | None -> ()
    | Some o ->
      let message =
        match disposition with
        | `Dropped -> "sol-worker: decode error, skipping message"
        | `Dead_lettered -> "sol-worker: decode error, routing message to the DLQ"
      in
      Obs_eio.log_standalone
        o
        Obs_eio.Error
        ~fields:
          [ "error", e
          ; ( "raw_bytes_len"
            , string_of_int (Option.fold ~none:0 ~some:Bytes.length raw_bytes) )
          ; "topic", topic_name
          ]
        message
;;

let ack_and_drop_decode_error e ~raw_bytes:_ ~ack =
  Printf.eprintf "sol-worker: DECODE_ERROR skip=true error=%S\n%!" e;
  match ack () with
  | Ok () -> Kafka.Consumer.Continue
  | Error error ->
    Printf.eprintf
      "sol-worker: DECODE_ERROR skip=true ack_failed=%S; stopping for redelivery\n%!"
      (Kafka.Error.to_string error);
    Kafka.Consumer.Stop
;;
