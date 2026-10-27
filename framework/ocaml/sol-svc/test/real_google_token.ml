(** Manual verifier for a real Google service-account ID token.

    This is deliberately not part of the CI test alias: it requires a real
    provider token and Google's public JWKS. Run it only in a controlled local
    environment. It never prints the token or its claims.

    Required environment:
    - REAL_GOOGLE_TOKEN: token with the application audience;
    - REAL_GOOGLE_WRONG_AUD_TOKEN: token with a different audience;
    - REAL_GOOGLE_SUB: the token's service-account subject;
    - GOOGLE_JWKS_FILE: a local copy of https://www.googleapis.com/oauth2/v3/certs

    Expected: authorized=200, wrong_audience=401, missing=401. *)

let required name =
  match Sys.getenv_opt name with
  | Some value when value <> "" -> value
  | _ -> failwith (Printf.sprintf "missing %s" name)
;;

let () =
  let token = required "REAL_GOOGLE_TOKEN" in
  let wrong = required "REAL_GOOGLE_WRONG_AUD_TOKEN" in
  let sub = required "REAL_GOOGLE_SUB" in
  let jwks =
    In_channel.with_open_bin (required "GOOGLE_JWKS_FILE") In_channel.input_all
    |> Jose.Jwks.of_string
  in
  let identity : Auth.workload_identity_config =
    { audience = "checkout/checkout_svc"
    ; callers = [ sub, "checkout/checkout_svc" ]
    ; trusted_issuer = "https://accounts.google.com"
    ; trusted_jwks_uri = Some "https://www.googleapis.com/oauth2/v3/certs"
    ; subject_scheme = Google_oidc_service_account
    }
  in
  let call token_opt =
    let headers =
      match token_opt with
      | None -> Http.Header.of_list []
      | Some token -> Http.Header.of_list [ "authorization", "Bearer " ^ token ]
    in
    Service.For_testing.dispatch
      ~fetch_workload_jwks:(fun _ -> Ok jwks)
      ~workload_identity:identity
      ~routes:[ Route.get "/quote" (fun _ -> Response.ok "ok") ]
      (Http.Request.make ~meth:`GET ~headers "/quote")
      (Cohttp_eio.Body.of_string "")
  in
  let status = (call (Some token)).Response.status in
  let wrong_status = (call (Some wrong)).Response.status in
  let missing_status = (call None).Response.status in
  Printf.printf
    "real Google token: authorized=%d wrong_audience=%d missing=%d\n%!"
    status
    wrong_status
    missing_status;
  if status <> 200 || wrong_status <> 401 || missing_status <> 401
  then failwith "real-token identity check failed"
;;
