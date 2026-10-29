open Result.Syntax

type outcome =
  | Ack
  | Retry of string

type envelope =
  { task_id : string
  ; kind : string
  ; payload : string
  ; idempotency_key : string option
  }

type error =
  | Invalid of string
  | Too_large of
      { what : string
      ; limit : int
      ; actual : int
      }

let max_message_bytes = 256 * 1024

let error_to_string = function
  | Invalid message -> message
  | Too_large { what; limit; actual } ->
    Printf.sprintf "%s is %d bytes, over the %d-byte queue limit" what actual limit
;;

let outcome_to_string = function
  | Ack -> "ack"
  | Retry message -> "retry (" ^ message ^ ")"
;;

let is_task_id_char = function
  | 'a' .. 'z' | '0' .. '9' | '-' -> true
  | _ -> false
;;

let validate_task_id task_id =
  if task_id = ""
  then Error (Invalid "task_id is empty")
  else if String.length task_id > 128
  then Error (Invalid "task_id is longer than 128 bytes")
  else if not (String.for_all is_task_id_char task_id)
  then Error (Invalid (Printf.sprintf "task_id %S must use only a-z, 0-9, and -" task_id))
  else Ok ()
;;

let is_kind_char = function
  | 'a' .. 'z' | '0' .. '9' | '_' | '.' | '-' -> true
  | _ -> false
;;

let validate_kind kind =
  if kind = ""
  then Error (Invalid "task kind is empty")
  else if String.length kind > 128
  then Error (Invalid "task kind is longer than 128 bytes")
  else if not (String.for_all is_kind_char kind)
  then
    Error
      (Invalid (Printf.sprintf "task kind %S must use only a-z, 0-9, _, ., and -" kind))
  else Ok ()
;;

let validate_idempotency_key = function
  | None -> Ok ()
  | Some "" -> Error (Invalid "idempotency_key is empty")
  | Some key when String.length key > 256 ->
    Error (Invalid "idempotency_key is longer than 256 bytes")
  | Some _ -> Ok ()
;;

let rng = Random.State.make_self_init ()
let rng_mutex = Mutex.create ()

let new_task_id () =
  Mutex.lock rng_mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock rng_mutex)
    (fun () ->
       let seed =
         Printf.sprintf
           "%f:%d:%d:%d"
           (Unix.gettimeofday ())
           (Unix.getpid ())
           (Random.State.bits rng)
           (Random.State.bits rng)
       in
       Digest.to_hex (Digest.string seed))
;;

module Envelope = struct
  type t = envelope

  let create ~kind ~payload ?task_id ?idempotency_key () =
    let* () = validate_kind kind in
    let* () = validate_idempotency_key idempotency_key in
    let* () =
      if String.length payload > max_message_bytes
      then
        Error
          (Too_large
             { what = "task payload"
             ; limit = max_message_bytes
             ; actual = String.length payload
             })
      else Ok ()
    in
    let task_id = Option.value task_id ~default:(new_task_id ()) in
    let* () = validate_task_id task_id in
    Ok { task_id; kind; payload; idempotency_key }
  ;;

  let to_json (t : t) =
    `Assoc
      ([ "task_id", `String t.task_id
       ; "kind", `String t.kind
       ; "payload", `String t.payload
       ]
       @
       match t.idempotency_key with
       | None -> []
       | Some key -> [ "idempotency_key", `String key ])
  ;;

  let encode (t : t) =
    let text = Yojson.Safe.to_string (to_json t) in
    if String.length text > max_message_bytes
    then
      Error
        (Too_large
           { what = "encoded task envelope"
           ; limit = max_message_bytes
           ; actual = String.length text
           })
    else Ok text
  ;;

  let string_field json name =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some (`String value) -> Ok value
       | Some _ -> Error (Invalid (Printf.sprintf "%s must be a string" name))
       | None -> Error (Invalid (Printf.sprintf "%s is missing" name)))
    | _ -> Error (Invalid "task envelope must be a JSON object")
  ;;

  let optional_string_field json name =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt name fields with
       | None | Some `Null -> Ok None
       | Some (`String value) -> Ok (Some value)
       | Some _ -> Error (Invalid (Printf.sprintf "%s must be a string" name)))
    | _ -> Error (Invalid "task envelope must be a JSON object")
  ;;

  let decode text =
    if String.length text > max_message_bytes
    then
      Error
        (Too_large
           { what = "task envelope"
           ; limit = max_message_bytes
           ; actual = String.length text
           })
    else (
      match Yojson.Safe.from_string text with
      | exception Yojson.Json_error message ->
        Error (Invalid ("task envelope is not JSON: " ^ message))
      | json ->
        let* task_id = string_field json "task_id" in
        let* kind = string_field json "kind" in
        let* payload = string_field json "payload" in
        let* idempotency_key = optional_string_field json "idempotency_key" in
        create ~kind ~payload ~task_id ?idempotency_key ())
  ;;
end

module type TASK = sig
  type t

  val workspace : string
  val kind : t -> string
  val kinds : string list
  val encode : t -> string
  val decode : string -> (t, string) result
  val handle : task_id:string -> ?idempotency_key:string -> t -> outcome
end
