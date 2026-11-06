# Agent build artifacts

Place the approved Jenkins Remoting JAR here as `agent.jar`. Prefer the copy
served by the exact controller version at `/jnlpJars/agent.jar`, transferred
through the approved internal artifact process.

Pass its SHA-256 digest as `JENKINS_AGENT_JAR_SHA256` during build. The JAR is
intentionally not committed to this repository.
