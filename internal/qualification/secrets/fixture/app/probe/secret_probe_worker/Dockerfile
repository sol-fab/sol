# A pinned, minimal probe for provider-backed secret projection. The base image is a
# multi-architecture manifest digest, so the same bytes run on EKS and GKE nodes.
FROM busybox:1.36.1@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
COPY probe.sh /www/cgi-bin/probe
COPY fingerprint.sh /www/cgi-bin/fingerprint
RUN chmod 0755 /www/cgi-bin/probe /www/cgi-bin/fingerprint \
 && : >/www/healthz \
 && : >/www/readyz
EXPOSE 8080
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
