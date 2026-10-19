open Sol_cli_resource_binding

let external_binding =
  { resource = "events"
  ; typ = "kafka"
  ; ownership = Sol_cli_config.Ownership_external
  ; store = Some "external-kafka"
  ; credentials = []
  ; keys = [ "KAFKA_SASL_PASSWORD", "events/password"; "KAFKA_SSL_CA_CERT", "events/ca" ]
  ; connection =
      [ "KAFKA_BROKERS", "broker.example:9093"
      ; "SCHEMA_REGISTRY_URL", "https://registry.example"
      ; "REDPANDA_ADMIN_URL", "https://admin.example"
      ; "KAFKA_SASL_USERNAME", "consumer"
      ; "KAFKA_SASL_MECHANISM", "SCRAM-SHA-256"
      ]
  }
;;

let%test "Kafka selection preserves the whole external connection and authority" =
  match kafka [ external_binding ] with
  | Ok (External_kafka binding) ->
    Windtrap.equal Windtrap.string "events" binding.resource;
    Windtrap.equal Windtrap.string "external-kafka" binding.store;
    Windtrap.equal Windtrap.string "broker.example:9093" binding.brokers;
    Windtrap.equal Windtrap.string "https://registry.example" binding.schema_registry_url;
    Windtrap.equal Windtrap.string "https://admin.example" binding.admin_url;
    Windtrap.equal Windtrap.string "consumer" binding.username;
    Windtrap.equal Windtrap.string "SCRAM-SHA-256" binding.mechanism;
    Windtrap.equal Windtrap.string "events/password" binding.password;
    Windtrap.equal Windtrap.string "events/ca" binding.ca
  | _ -> Windtrap.fail "complete Kafka selection was not established"
;;

let%test "every required Kafka connection and credential source is mandatory" =
  let incomplete =
    [ { external_binding with store = None }; { external_binding with store = Some " " } ]
    @ List.concat_map
        (fun (key, _) ->
           [ { external_binding with
               connection = List.remove_assoc key external_binding.connection
             }
           ; { external_binding with
               connection =
                 (key, " ") :: List.remove_assoc key external_binding.connection
             }
           ])
        external_binding.connection
    @ List.concat_map
        (fun (key, _) ->
           [ { external_binding with keys = List.remove_assoc key external_binding.keys }
           ; { external_binding with
               keys = (key, " ") :: List.remove_assoc key external_binding.keys
             }
           ])
        external_binding.keys
  in
  List.iter
    (fun selection ->
       match kafka [ selection ] with
       | Error _ -> ()
       | Ok _ -> Windtrap.fail "incomplete Kafka contract accepted")
    incomplete
;;

let%test "Kafka cannot silently accept unsupported inputs or insecure endpoints" =
  let replace key value =
    { external_binding with
      connection = (key, value) :: List.remove_assoc key external_binding.connection
    }
  in
  List.iter
    (fun selection ->
       match kafka [ selection ] with
       | Error _ -> ()
       | Ok _ -> Windtrap.fail "invalid Kafka contract accepted")
    [ { external_binding with credentials = [ "admin", "arbitrary" ] }
    ; { external_binding with keys = ("EXTRA_KEY", "arbitrary") :: external_binding.keys }
    ; replace "KAFKA_SASL_MECHANISM" "GSSAPI"
    ; replace "SCHEMA_REGISTRY_URL" "http://registry.example"
    ; replace "REDPANDA_ADMIN_URL" "https://user:password@admin.example"
    ; replace "SCHEMA_REGISTRY_URL" "https://registry.example?token=secret"
    ; replace "KAFKA_BROKERS" "username:password@broker.example:9093"
    ; replace "KAFKA_BROKERS" "broker.example:9093/path"
    ]
;;

let%test "Kafka graph cardinality and ownership are explicit" =
  Windtrap.equal Windtrap.bool true (kafka [] = Ok No_kafka);
  let managed =
    { external_binding with
      ownership = Ownership_sol
    ; store = None
    ; keys = []
    ; connection = []
    }
  in
  Windtrap.equal Windtrap.bool true (kafka [ managed ] = Ok (Managed_kafka "events"));
  List.iter
    (fun selections ->
       match kafka selections with
       | Error _ -> ()
       | Ok _ -> Windtrap.fail "ambiguous Kafka authority accepted")
    [ [ external_binding; { external_binding with resource = "another" } ]
    ; [ { managed with keys = external_binding.keys } ]
    ; [ { managed with store = Some "competing-writer" } ]
    ]
;;
