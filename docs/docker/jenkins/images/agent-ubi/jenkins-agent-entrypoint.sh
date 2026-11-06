#!/usr/bin/env bash
set -Eeuo pipefail

java_options=()

if [[ -n "${JENKINS_JAVA_OPTS:-${JAVA_OPTS:-}}" ]]; then
  read -r -a java_options <<<"${JENKINS_JAVA_OPTS:-${JAVA_OPTS:-}}"
fi

exec java \
  "${java_options[@]}" \
  -jar "${JENKINS_AGENT_FILE:-/usr/share/jenkins/agent.jar}" \
  "$@"
