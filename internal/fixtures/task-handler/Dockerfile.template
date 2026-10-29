# The handler binary is built by the repository toolchain and copied into this
# context. The base image must be at least as new as the build host's glibc.
FROM ubuntu:26.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY task_handler /usr/local/bin/task-handler
USER 65534
CMD ["/usr/local/bin/task-handler"]
