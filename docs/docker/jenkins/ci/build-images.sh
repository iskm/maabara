#!/usr/bin/env bash
set -Eeuo pipefail

: "${CONTROLLER_BASE_IMAGE:?Set CONTROLLER_BASE_IMAGE}"
: "${CONTROLLER_IMAGE:?Set CONTROLLER_IMAGE}"
: "${AGENT_BASE_IMAGE:?Set AGENT_BASE_IMAGE}"
: "${AGENT_IMAGE:?Set AGENT_IMAGE}"

container_cli="${CONTAINER_CLI:-docker}"
package_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
controller_context="${package_root}/images/controller-ubi9"
agent_context="${package_root}/images/agent-ubi"

test -s "${controller_context}/artifacts/jenkins.war"
test -s "${agent_context}/artifacts/agent.jar"

controller_sha256="$(sha256sum "${controller_context}/artifacts/jenkins.war" | awk '{print $1}')"
agent_sha256="$(sha256sum "${agent_context}/artifacts/agent.jar" | awk '{print $1}')"

"${container_cli}" build \
  --build-arg "BASE_IMAGE=${CONTROLLER_BASE_IMAGE}" \
  --build-arg "JENKINS_WAR_SHA256=${controller_sha256}" \
  --tag "${CONTROLLER_IMAGE}" \
  "${controller_context}"

"${container_cli}" build \
  --build-arg "BASE_IMAGE=${AGENT_BASE_IMAGE}" \
  --build-arg "JENKINS_AGENT_JAR_SHA256=${agent_sha256}" \
  --tag "${AGENT_IMAGE}" \
  "${agent_context}"

"${container_cli}" push "${CONTROLLER_IMAGE}"
"${container_cli}" push "${AGENT_IMAGE}"
