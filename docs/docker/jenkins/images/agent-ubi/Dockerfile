# Point this at an internal UBI 8 or UBI 9 mirror. Both use the same build.
ARG BASE_IMAGE=registry.internal.example/base/ubi9:latest
FROM ${BASE_IMAGE}

ARG JENKINS_AGENT_JAR_SHA256

RUN dnf -y install \
      ca-certificates \
      curl \
      findutils \
      git \
      gzip \
      java-21-openjdk-headless \
      openssh-clients \
      openssl \
      procps-ng \
      python3 \
      python3-requests \
      shadow-utils \
      tar \
      unzip \
      which \
      zip \
    && dnf clean all \
    && rm -rf /var/cache/dnf \
    && groupadd --gid 1000 jenkins \
    && useradd --uid 1000 --gid 1000 --home-dir /home/jenkins \
         --create-home --shell /bin/bash jenkins \
    && install -d -o 1000 -g 1000 -m 0750 \
         /home/jenkins/agent /usr/share/jenkins

# Obtain agent.jar from the matching controller or internal artifact repository.
COPY --chown=1000:1000 artifacts/agent.jar /usr/share/jenkins/agent.jar
COPY internal-cas/ /tmp/internal-cas/
RUN test -n "${JENKINS_AGENT_JAR_SHA256}" \
    && printf '%s  %s\n' "${JENKINS_AGENT_JAR_SHA256}" /usr/share/jenkins/agent.jar \
       | sha256sum --check --strict \
    && find /tmp/internal-cas -type f \( -name '*.crt' -o -name '*.pem' \) -print0 \
       | while IFS= read -r -d '' cert; do \
           openssl x509 -in "${cert}" -noout; \
           alias="internal-$(basename "${cert%.*}" | tr -c 'A-Za-z0-9_.-' '-')"; \
           install -m 0644 "${cert}" "/etc/pki/ca-trust/source/anchors/${alias}.crt"; \
           keytool -importcert -noprompt -trustcacerts -cacerts \
             -storepass changeit -alias "${alias}" -file "${cert}"; \
         done \
    && update-ca-trust \
    && rm -rf /tmp/internal-cas

COPY jenkins-agent-entrypoint.sh /usr/local/bin/jenkins-agent
RUN chmod 0755 /usr/local/bin/jenkins-agent

ENV HOME=/home/jenkins \
    JENKINS_AGENT_FILE=/usr/share/jenkins/agent.jar

USER 1000:1000
WORKDIR /home/jenkins/agent
ENTRYPOINT ["/usr/local/bin/jenkins-agent"]
