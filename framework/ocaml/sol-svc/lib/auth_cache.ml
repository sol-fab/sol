type entry =
  { url : string
  ; fetched_at : float
  ; jwks : Jose.Jwks.t
  }

(* A service can validate against more than one issuer: its metrics JWT and its
   workload-identity JWKS are separate URLs. Keep one entry per URL; a single slot made the
   two modes evict each other and refetch on every alternating request. *)
let cache : entry list Atomic.t = Atomic.make []
let failure : (string * float * string) option Atomic.t = Atomic.make None
let ttl_s = 300.0
let unknown_kid_refetch_interval_s = 30.0
let failure_backoff_s = 5.0
let peek url = Atomic.get cache |> List.find_opt (fun entry -> String.equal entry.url url)

let replace entry =
  let entries = Atomic.get cache in
  Atomic.set
    cache
    (entry :: List.filter (fun e -> not (String.equal e.url entry.url)) entries)
;;

let urls () =
  Atomic.get cache |> List.map (fun entry -> entry.url) |> List.sort_uniq String.compare
;;

let clear () =
  Atomic.set cache [];
  Atomic.set failure None
;;

let last_failure () = Atomic.get failure
let set_last_failure f = Atomic.set failure f
