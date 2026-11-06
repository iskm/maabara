# Controller build artifacts

Place the approved Jenkins WAR here as `jenkins.war`. Do not download it in
the Dockerfile: retrieve it from the internal artifact repository, verify its
provenance, and pass its SHA-256 digest as `JENKINS_WAR_SHA256` during build.

The WAR is intentionally not committed to this repository.
