#!/usr/bin/env bash
set -Eeuo pipefail

java_options=()
jenkins_options=()

if [[ -n "${JAVA_OPTS:-}" ]]; then
  read -r -a java_options <<<"${JAVA_OPTS}"
fi

if [[ -n "${JENKINS_OPTS:-}" ]]; then
  read -r -a jenkins_options <<<"${JENKINS_OPTS}"
fi

# Seed only files that are absent from the persistent Jenkins home. This makes
# image-baked plugins available on first start without overwriting live state.
cp --archive --no-clobber /usr/share/jenkins/ref/. "${JENKINS_HOME}/"

exec java \
  -Duser.home="${JENKINS_HOME}" \
  "${java_options[@]}" \
  -jar "${JENKINS_WAR}" \
  "${jenkins_options[@]}" \
  "$@"
