# Override this with the mirrored UBI 9 image in the internal registry.
ARG BASE_IMAGE=registry.internal.example/base/ubi9:latest
FROM ${BASE_IMAGE}

ARG JENKINS_WAR_SHA256

RUN dnf -y install \
      ca-certificates \
      curl \
      dejavu-sans-fonts \
      findutils \
      fontconfig \
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
    && useradd --uid 1000 --gid 1000 --home-dir /var/jenkins_home \
         --create-home --shell /bin/bash jenkins \
    && install -d -o 1000 -g 1000 -m 0750 \
         /usr/share/jenkins /usr/share/jenkins/ref /var/jenkins_home

# Obtain this WAR from the approved internal artifact repository before build.
COPY --chown=1000:1000 artifacts/jenkins.war /usr/share/jenkins/jenkins.war
COPY --chown=1000:1000 plugins/ /usr/share/jenkins/ref/plugins/
RUN test -n "${JENKINS_WAR_SHA256}" \
    && printf '%s  %s\n' "${JENKINS_WAR_SHA256}" /usr/share/jenkins/jenkins.war \
       | sha256sum --check --strict

COPY jenkins-controller-entrypoint.sh /usr/local/bin/jenkins-controller
RUN chmod 0755 /usr/local/bin/jenkins-controller

ENV HOME=/var/jenkins_home \
    JENKINS_HOME=/var/jenkins_home \
    JENKINS_WAR=/usr/share/jenkins/jenkins.war

USER 1000:1000
WORKDIR /var/jenkins_home
EXPOSE 8080 8443
ENTRYPOINT ["/usr/local/bin/jenkins-controller"]
