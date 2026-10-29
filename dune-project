(lang dune 3.0)

(generate_opam_files false)

(package
 (name kafka-eio-service)
 (synopsis
  "Sol's Kafka policy layer: schema-registry ordering/fatality, explicit topic provisioning, Confluent wire format, decode/retry/crash routing")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  cstruct
  eio
  http
  https-eio
  kafka-eio
  obs-eio
  uri
  yojson))

(package
 (name sol-env)
 (synopsis
  "Internal: Sol's environment/config plumbing. Not part of the supported application API")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio))

(package
 (name sol-runtime)
 (synopsis
  "Internal: Sol's shared runtime plumbing. Not part of the supported application API")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio))

(package
 (name sol-retry)
 (synopsis
  "Sol's shared bounded operation-retry helper: one jittered policy vocabulary for retrying a dependency call in place")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio))

(package
 (name sol-obs)
 (synopsis
  "Sol's observability conventions: metric names, label vocabularies, Loki push shape, W3C traceparent propagation")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio
  obs-eio
  obs-loki-eio
  obs-prometheus-eio
  obs-tempo-eio))

(package
 (name sol-fn)
 (synopsis "Sol's scheduled-function application shape")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio
  lambda-eio
  obs-eio
  obs-prometheus-eio
  sol-env
  sol-obs
  sol-runtime))

(package
 (name sol-jobs)
 (synopsis "Sol's background-job application shape")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  caqti
  eio
  mtime
  obs-eio
  obs-prometheus-eio
  pg-eio
  sol-env
  sol-obs
  sol-runtime))

(package
 (name sol-task)
 (synopsis "Sol's durable task handler contract and local/cloud task runtimes")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  base64
  caqti
  cohttp-eio
  eio
  lambda-eio
  pg-eio
  sol-env
  sol-jobs
  sol-runtime
  yojson))

(package
 (name sol-outbox)
 (synopsis "Sol's Postgres transactional outbox: atomic state change and publication intent")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  caqti
  eio
  obs-eio
  obs-prometheus-eio
  pg-eio
  sol-env
  sol-obs
  sol-runtime))

(package
 (name sol-svc-core)
 (synopsis "Runtime-neutral security, lifecycle, and observation semantics for Sol HTTP services")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  jose
  yojson))

(package
 (name sol-svc)
 (synopsis "Sol's HTTP service application shape")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  base64
  cohttp-eio
  eio
  http
  https-eio
  jose
  obs-eio
  ptime
  sol-obs
  sol-svc-core
  sol-runtime
  uri
  yojson))

(package
 (name sol-worker)
 (synopsis "Sol's Kafka worker application shape")
 (depends
  (ocaml (>= 5.4.0))
  (dune (>= 3.0))
  eio
  kafka-eio
  kafka-eio-service
  obs-eio
  obs-prometheus-eio
  sol-env
  sol-obs
  sol-runtime))

(package
 (name sol)
 (allow_empty)
 (synopsis "Sol — open-source OCaml software factory for backend systems")
 (depends
  (ocaml (>= 5.4.0))
  (dune  (>= 3.0))
  eio
  eio_main
  cohttp-eio
  http
  yojson
  cmdliner
  base64
  uri
  cstruct
  kafka-eio
  obs-eio
  obs-loki-eio
  obs-prometheus-eio
  obs-tempo-eio
  https-eio
  mtime
  caqti-eio
  caqti-driver-postgresql
  pg-eio
  digestif
  aws-eio
  s3-eio
  dynamodb-eio
  lambda-eio
  otoml
  jose
  ptime
  windtrap
  (mirage-crypto-pk :with-test)
  (alcotest :with-test)
  (mirage-crypto-rng :with-test)))
