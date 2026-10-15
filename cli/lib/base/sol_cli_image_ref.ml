let digest_prefix = "sha256:"
let digest_hex_length = 64

let is_lower_hex s =
  String.length s = digest_hex_length
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s
;;

let is_digest s =
  match String.rindex_opt s '@' with
  | None -> false
  | Some at ->
    let repo = String.sub s 0 at in
    let suffix = String.sub s (at + 1) (String.length s - at - 1) in
    String.length repo > 0
    && String.length suffix = String.length digest_prefix + digest_hex_length
    && String.starts_with ~prefix:digest_prefix suffix
    && is_lower_hex (String.sub suffix (String.length digest_prefix) digest_hex_length)
;;

let split_flag_value value =
  match String.index_opt value '=' with
  | Some eq when eq > 0 ->
    Some (String.sub value 0 eq), String.sub value (eq + 1) (String.length value - eq - 1)
  | _ -> None, value
;;

let resolve ~service_names refs =
  let validate (_, ref) =
    if is_digest ref
    then None
    else
      Some
        (Printf.sprintf
           "--image-ref %S is not an immutable reference; expected <repo>@sha256:<64 \
            hexadecimal digits>"
           ref)
  in
  match List.find_map validate refs with
  | Some msg -> Error msg
  | None ->
    let rec go seen acc = function
      | [] -> Ok (List.rev acc)
      | (name, ref) :: rest ->
        (match name with
         | Some service ->
           if List.mem service seen
           then
             Error (Printf.sprintf "--image-ref names service %S more than once" service)
           else if not (List.mem service service_names)
           then
             Error
               (Printf.sprintf
                  "--image-ref names service %S, which is not in the selected scope (%s)"
                  service
                  (if service_names = [] then "none" else String.concat ", " service_names))
           else go (service :: seen) ((service, ref) :: acc) rest
         | None ->
           (match service_names with
            | [ only ] -> go (only :: seen) ((only, ref) :: acc) rest
            | _ ->
              Error
                (Printf.sprintf
                   "--image-ref without a service name requires exactly one selected \
                    service; this scope selects %d (%s). Use --image-ref \
                    <service>=<ref>."
                   (List.length service_names)
                   (if service_names = []
                    then "none"
                    else String.concat ", " service_names))))
    in
    go [] [] refs
;;

let resolve_with_previous ~service_names refs previous =
  let open Result.Syntax in
  let* explicit = resolve ~service_names refs in
  let images =
    List.map
      (fun name ->
         match List.assoc_opt name explicit with
         | Some image -> name, image
         | None ->
           (match
              List.filter
                (fun (previous_name, _) -> String.equal name previous_name)
                previous
            with
            | [ (_, image) ] when is_digest image -> name, image
            | _ -> name, ""))
      service_names
  in
  let missing = List.filter (fun (_, image) -> image = "") images in
  if missing = []
  then Ok images
  else
    Error
      (Printf.sprintf
         "no immutable image reference is available for: %s; supply --image-ref for \
          these workloads (a first deploy requires a complete mapping)"
         (String.concat ", " (List.map fst missing)))
;;

let plan_is_immutable (images : string list) =
  images <> [] && List.for_all is_digest images
;;

(** The registry path a reference addresses, without its tag or digest. The pending-artifact
    report names these; they are the `<registry>/<workspace>/<unit>` repositories the target
    root creates. A registry host may carry a port, so only a `:` *after the last `/`* is a
    tag separator — `registry:5000/ws/unit` is left intact, `registry:5000/ws/unit:tag` is
    stripped at the tag. *)
let repository ref =
  match String.index_opt ref '@' with
  | Some at -> String.sub ref 0 at
  | None ->
    (match String.rindex_opt ref ':' with
     | Some colon ->
       let after_last_slash =
         match String.rindex_opt ref '/' with
         | Some slash -> colon > slash
         | None -> true
       in
       if after_last_slash then String.sub ref 0 colon else ref
     | None -> ref)
;;
