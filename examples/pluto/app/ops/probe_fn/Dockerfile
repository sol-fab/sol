FROM ocaml/opam:ubuntu-24.04-ocaml-5.4 AS build
RUN sudo apt-get update && sudo apt-get install -y \
    librdkafka-dev libpq-dev libssl-dev libgmp-dev pkg-config && \
    sudo rm -rf /var/lib/apt/lists/*
RUN opam repository set-url default https://opam.ocaml.org && opam update
COPY --chown=opam:opam pluto.opam /workspace/
WORKDIR /workspace
RUN opam install -y --no-self-upgrade --deps-only .
COPY --chown=opam:opam . /workspace
RUN opam exec -- dune build app/ops/probe_fn/bin/main.exe

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /workspace/_build/default/app/ops/probe_fn/bin/main.exe /usr/local/bin/pluto-probe-fn
USER 65534
CMD ["/usr/local/bin/pluto-probe-fn"]
