(* DEC-051/DEC-063: the target's trusted Kubernetes service-account OIDC issuer
   is discovered through the driver capability boundary. These tests exercise
   the capability present, absent, and failing closed, with the provider command
   runner injected so no real cloud CLI is invoked. *)

let check_bool msg expected actual = Windtrap.equal Windtrap.bool ~msg expected actual
let check_string msg expected actual = Windtrap.equal Windtrap.string ~msg expected actual

let target ?(fields = []) ?cluster_name ?(region = "us-east-1") provider =
  { Sol_cli_config.name = "dev/" ^ Sol_cli_provider.to_string provider ^ "/" ^ region
  ; env = "dev"
  ; provider
  ; region
  ; registry = None
  ; base_domain = None
  ; cluster_issuer = None
  ; letsencrypt_email = None
  ; cluster_name
  ; kube_context = None
  ; kubeconfig = None
  ; terraform_var_file = None
  ; observability_backend = None
  ; observability_traces_url = None
  ; destroy_retention = None
  ; alert_receiver_type = None
  ; alert_receiver_url = None
  ; alert_owner = None
  ; alert_runbook_url = None
  ; state_bucket = None
  ; cluster_endpoint_cidr = None
  ; dns_zone_ownership = None
  ; node_failure_headroom_nodes = None
  ; profile = None
  ; shape = Some Sol_cli_profile.Local
  ; provider_fields = [ Sol_cli_provider.to_string provider, fields ]
  ; secret_authorities = []
  }
;;

let aws_run ?(issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE") seen argv =
  seen := argv :: !seen;
  if List.mem "describe-cluster" argv
  then Ok (issuer ^ "\n")
  else Error ("unexpected aws command: " ^ String.concat " " argv)
;;

let gcp_discovery_json issuer =
  Printf.sprintf {|{"issuer":"%s","jwks_uri":"%s/.well-known/jwks.json"}|} issuer issuer
;;

let gcp_run
      ?(issuer =
        "https://container.googleapis.com/v1/projects/my-project/locations/us-central1/clusters/prod")
      seen
      argv
  =
  seen := argv :: !seen;
  if List.mem "curl" argv
  then Ok (gcp_discovery_json issuer)
  else Error ("unexpected gcloud command: " ^ String.concat " " argv)
;;

let check_mentions ~msg ~needle = function
  | Error message -> check_bool msg true (Sol_cli_string.contains ~needle message)
  | Ok _ -> Windtrap.fail (msg ^ ": the capability reported a trusted issuer")
;;

(* ----------------------------------------------------------------- *)
(* Present: the provider reports the cluster's trusted issuer.        *)
(* ----------------------------------------------------------------- *)

let%test "issuer: aws establishes the declared cluster's trusted OIDC issuer" =
  let seen = ref [] in
  let issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE" in
  let target = target ~cluster_name:"prod" Sol_cli_provider.Aws in
  (match
     Sol_cli_provider_capabilities.aws_workload_identity_issuer
       ~run:(aws_run ~issuer seen)
       target
   with
   | Error message -> Windtrap.fail message
   | Ok discovered -> check_string "the discovered issuer" issuer discovered);
  check_bool
    "the provider is asked about the declared cluster and region"
    true
    (List.exists
       (fun argv ->
          List.mem "describe-cluster" argv
          && List.mem "prod" argv
          && List.mem "us-east-1" argv)
       !seen)
;;

let%test "issuer: gcp reads the cluster's OIDC discovery document" =
  let seen = ref [] in
  let issuer =
    "https://container.googleapis.com/v1/projects/my-project/locations/us-central1/clusters/prod"
  in
  let target =
    target
      ~cluster_name:"prod"
      ~region:"us-central1"
      ~fields:[ "project_id", "my-project" ]
      Sol_cli_provider.Gcp
  in
  (match
     Sol_cli_provider_capabilities.gcp_workload_identity_issuer
       ~run:(gcp_run ~issuer seen)
       target
   with
   | Error message -> Windtrap.fail message
   | Ok discovered -> check_string "the discovered issuer" issuer discovered);
  check_bool
    "the discovery document is requested at the cluster's well-known path"
    true
    (List.exists
       (fun argv ->
          List.exists
            (fun argument ->
               Sol_cli_string.contains
                 ~needle:"/v1/projects/my-project/locations/us-central1/clusters/prod"
                 argument
               && Sol_cli_string.contains
                    ~needle:"/.well-known/openid-configuration"
                    argument)
            argv)
       !seen);
  check_bool
    "the document is read without an operator credential, as the callee will read it"
    true
    (List.length !seen = 1
     && List.for_all
          (fun argv -> List.mem "curl" argv && not (List.mem "--config" argv))
          !seen)
;;

(* ----------------------------------------------------------------- *)
(* Absent: a driver that establishes no issuer, by definition.        *)
(* ----------------------------------------------------------------- *)

let%test "issuer: byo reports the capability absent" =
  match
    (Sol_cli_provider_capabilities.capabilities_of Sol_cli_provider.Byo)
      .workload_identity_issuer
      (target Sol_cli_provider.Byo)
  with
  | Ok _ -> Windtrap.fail "a byo target reported a trusted OIDC issuer"
  | Error message ->
    check_bool "names the driver" true (Sol_cli_string.contains ~needle:"byo" message);
    check_bool
      "names the decision"
      true
      (Sol_cli_string.contains ~needle:"DEC-051" message)
;;

(* ----------------------------------------------------------------- *)
(* Failure: missing declaration, provider failure, unusable URL.      *)
(* ----------------------------------------------------------------- *)

let%test "issuer: aws without a declared cluster_name fails closed unconsulted" =
  let run _ = Windtrap.fail "aws was consulted without a declared cluster_name" in
  check_mentions
    ~msg:"aws requires the cluster declaration"
    ~needle:"cluster_name"
    (Sol_cli_provider_capabilities.aws_workload_identity_issuer
       ~run
       (target Sol_cli_provider.Aws))
;;

let%test "issuer: the aws capability record reads the missing declaration" =
  check_mentions
    ~msg:"the aws capability record is wired to the aws discovery"
    ~needle:"cluster_name"
    ((Sol_cli_provider_capabilities.capabilities_of Sol_cli_provider.Aws)
       .workload_identity_issuer
       (target Sol_cli_provider.Aws))
;;

let%test "issuer: aws discovery failure fails closed" =
  let run argv =
    ignore argv;
    Error "Unable to locate credentials"
  in
  check_mentions
    ~msg:"the provider failure is reported"
    ~needle:"Unable to locate credentials"
    (Sol_cli_provider_capabilities.aws_workload_identity_issuer
       ~run
       (target ~cluster_name:"prod" Sol_cli_provider.Aws))
;;

let%test "issuer: aws rejects a non-HTTPS issuer" =
  let seen = ref [] in
  check_mentions
    ~msg:"an insecure issuer is refused"
    ~needle:"no usable HTTPS"
    (Sol_cli_provider_capabilities.aws_workload_identity_issuer
       ~run:(aws_run ~issuer:"http://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE" seen)
       (target ~cluster_name:"prod" Sol_cli_provider.Aws))
;;

let%test "issuer: aws rejects an issuer that is not a URL" =
  let seen = ref [] in
  check_mentions
    ~msg:"a non-URL issuer is refused"
    ~needle:"no usable HTTPS"
    (Sol_cli_provider_capabilities.aws_workload_identity_issuer
       ~run:(aws_run ~issuer:"None" seen)
       (target ~cluster_name:"prod" Sol_cli_provider.Aws))
;;

let%test "issuer: gcp requires the cluster declaration" =
  let run _ = Windtrap.fail "discovery was requested without a declared cluster_name" in
  check_mentions
    ~msg:"gcp requires the cluster declaration"
    ~needle:"cluster_name"
    (Sol_cli_provider_capabilities.gcp_workload_identity_issuer
       ~run
       (target ~fields:[ "project_id", "my-project" ] Sol_cli_provider.Gcp))
;;

let%test "issuer: gcp requires the project declaration" =
  let run _ = Windtrap.fail "discovery was requested without a declared project_id" in
  check_mentions
    ~msg:"gcp requires the project declaration"
    ~needle:"project_id"
    (Sol_cli_provider_capabilities.gcp_workload_identity_issuer
       ~run
       (target ~cluster_name:"prod" Sol_cli_provider.Gcp))
;;

let%test "issuer: gcp fails closed when the discovery document cannot be read" =
  let run argv =
    ignore argv;
    Error "curl: (6) Could not resolve host: container.googleapis.com"
  in
  check_mentions
    ~msg:"the unreadable discovery document is reported"
    ~needle:"Could not resolve host"
    (Sol_cli_provider_capabilities.gcp_workload_identity_issuer
       ~run
       (target
          ~cluster_name:"prod"
          ~fields:[ "project_id", "my-project" ]
          Sol_cli_provider.Gcp))
;;

let%test "issuer: gcp refuses an issuer that is not on the GKE API host" =
  let seen = ref [] in
  check_mentions
    ~msg:"an issuer from another host is refused"
    ~needle:"no usable HTTPS"
    (Sol_cli_provider_capabilities.gcp_workload_identity_issuer
       ~run:(gcp_run ~issuer:"https://evil.example.com/issuer" seen)
       (target
          ~cluster_name:"prod"
          ~fields:[ "project_id", "my-project" ]
          Sol_cli_provider.Gcp))
;;

let%test "issuer: gcp refuses an issuer for a different cluster on the GKE API host" =
  let seen = ref [] in
  check_mentions
    ~msg:"a discovery document for a different GKE cluster is refused"
    ~needle:"does not match the declared target cluster"
    (Sol_cli_provider_capabilities.gcp_workload_identity_issuer
       ~run:
         (gcp_run
            ~issuer:
              "https://container.googleapis.com/v1/projects/other/locations/us-central1/clusters/other"
            seen)
       (target
          ~cluster_name:"prod"
          ~region:"us-central1"
          ~fields:[ "project_id", "my-project" ]
          Sol_cli_provider.Gcp))
;;

let%test "issuer: gcp fails closed on a discovery document with no issuer" =
  let run argv =
    ignore argv;
    Ok {|{"jwks_uri":"https://container.googleapis.com/jwks.json"}|}
  in
  check_mentions
    ~msg:"a discovery document without an issuer is refused"
    ~needle:"no string issuer"
    (Sol_cli_provider_capabilities.gcp_workload_identity_issuer
       ~run
       (target
          ~cluster_name:"prod"
          ~fields:[ "project_id", "my-project" ]
          Sol_cli_provider.Gcp))
;;
