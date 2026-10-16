open Contract

type location =
  { namespace : string
  ; name : string
  }

type declaration =
  { namespace : string
  ; ca : string
  }

type resource =
  | Configmap
  | Deployment

type observation =
  | Absent
  | Present of Yojson.Safe.t
  | Unreadable of string

(* The observer is the interface: it obtains independent Kubernetes evidence;
   the contract alone decides what that evidence establishes. *)
module type Observer = sig
  val read : resource -> location -> observation
end

let declaration ~target text =
  let sentinel = "sol-database-identity:" in
  let lines = String.split_on_char '\n' text in
  let declarations =
    List.filter_map
      (fun line ->
         match String.split_on_char ' ' (String.trim line) with
         | marker :: fields when marker = sentinel -> Some fields
         | _ -> None)
      lines
  in
  match List.rev declarations with
  | [] -> Error "deploy log contains no database identity declaration"
  | fields :: _ ->
    let pairs =
      List.filter_map
        (fun field ->
           match String.split_on_char '=' field with
           | [ key; value ] when value <> "" -> Some (key, value)
           | _ -> None)
        fields
    in
    let expected =
      [ "target"; "resource"; "namespace"; "ddl-creds"; "authority"; "ca-configmap" ]
    in
    if
      List.sort String.compare (List.map fst pairs) <> List.sort String.compare expected
      || List.length fields <> List.length expected
    then Error "database identity declaration has incomplete, duplicate or unknown fields"
    else if List.assoc "target" pairs <> target
    then Error "latest database identity declaration belongs to another target"
    else
      Ok
        { namespace = List.assoc "namespace" pairs; ca = List.assoc "ca-configmap" pairs }
;;

let field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some v -> v
     | None -> `Null)
  | _ -> `Null
;;

let path names json = List.fold_left (fun value key -> field key value) json names

let array = function
  | `List values -> Some values
  | _ -> None
;;

let validate_identity resource (location : location) json =
  field "kind" json
  = `String
      (match resource with
       | Configmap -> "ConfigMap"
       | Deployment -> "Deployment")
  && field "apiVersion" json
     = `String
         (match resource with
          | Configmap -> "v1"
          | Deployment -> "apps/v1")
  && path [ "metadata"; "namespace" ] json = `String location.namespace
  && path [ "metadata"; "name" ] json = `String location.name
;;

module Make (Observer : Observer) = struct
  let check resource location predicate =
    match Observer.read resource location with
    | Unreadable reason -> Unknown reason
    | Absent -> Fail "Kubernetes positively returned no object"
    | Present json ->
      if not (validate_identity resource location json)
      then Unknown "malformed Kubernetes object or mismatched resource identity"
      else predicate json
  ;;

  let configmap location =
    check Configmap location (fun json ->
      match field "ca_present" json with
      | `Bool true -> Pass
      | `Bool false -> Fail "ConfigMap has no nonempty ca.crt"
      | _ -> Unknown "malformed ConfigMap projection")
  ;;

  let deployment ~ca location =
    check Deployment location (fun json ->
      match array (path [ "spec"; "template"; "spec"; "volumes" ] json) with
      | None -> Unknown "pod template has no readable volumes array"
      | Some volumes ->
        let mounts =
          List.exists
            (fun volume ->
               field "name" volume = `String "db-ca"
               && path [ "configMap"; "name" ] volume = `String ca)
            volumes
        in
        if mounts
        then Pass
        else Fail "pod template has no db-ca volume referencing the declared CA")
  ;;

  let run ~declaration ~consumers =
    let declaration_claim =
      { id = "database-ca/declaration"
      ; verdict =
          (match declaration with
           | Ok _ -> Pass
           | Error reason -> Unknown reason)
      }
    in
    let configmap_namespaces =
      (match declaration with
       | Ok d -> [ d.namespace ]
       | Error _ -> [])
      @ List.map (fun (c : location) -> c.namespace) consumers
      |> List.sort_uniq String.compare
    in
    let configmaps =
      List.map
        (fun namespace ->
           { id = "database-ca/configmap/" ^ namespace
           ; verdict =
               dependent declaration (fun d -> configmap { namespace; name = d.ca })
           })
        configmap_namespaces
    in
    let workloads =
      List.map
        (fun (location : location) ->
           { id = "database-ca/deployment/" ^ location.namespace ^ "/" ^ location.name
           ; verdict = dependent declaration (fun d -> deployment ~ca:d.ca location)
           })
        consumers
    in
    (declaration_claim
     :: { id = "database-ca/selection"
        ; verdict =
            (if consumers = [] then Fail "no selected database consumers" else Pass)
        }
     :: configmaps)
    @ workloads
  ;;
end
