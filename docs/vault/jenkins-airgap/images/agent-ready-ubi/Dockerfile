# This base must already be a working UBI 8/9 Jenkins inbound-agent image.
ARG BASE_IMAGE=registry.internal.example/jenkins/inbound-agent:ubi9-base
FROM ${BASE_IMAGE}

USER 0

# Keep the base image's Jenkins entrypoint and add the common build/runtime
# packages. The conditional supports full UBI (dnf) and UBI minimal (microdnf).
RUN if command -v dnf >/dev/null 2>&1; then \
      dnf -y install \
        ca-certificates curl findutils git gzip java-21-openjdk-headless \
        openssh-clients openssl procps-ng python3 python3-requests tar unzip \
        which zip \
      && dnf clean all \
      && rm -rf /var/cache/dnf; \
    elif command -v microdnf >/dev/null 2>&1; then \
      microdnf -y install \
        ca-certificates curl findutils git gzip java-21-openjdk-headless \
        openssh-clients openssl procps-ng python3 python3-requests tar unzip \
        which zip \
      && microdnf clean all; \
    else \
      echo 'The ready-made agent base must be UBI with dnf or microdnf.' >&2; \
      exit 1; \
    fi

# The playbooks use UID/GID 1000 by default. Override their variables if the
# approved ready-made image uses a different Jenkins account.
USER 1000:1000
