# Jenkins controllers and agents with Dockerfiles and Ansible

This package separates image construction from host deployment:

1. A GitLab, GitHub, or other CI pipeline builds and scans immutable Jenkins
   controller and agent images.
2. The pipeline pushes those images to an internal registry.
3. Ansible prepares a Docker or Podman host, installs certificate trust,
   creates persistent bind mounts, renders systemd units, and starts Jenkins.

The design assumes an enterprise environment with multiple internal root and
intermediate CAs, including Microsoft Active Directory Certificate Services.
Both the container operating-system trust and Java trust must be correct; they
are separate trust consumers.

## Contents

| Path | Purpose |
|---|---|
| `images/controller-ubi9` | UBI 9 controller image built from an approved Jenkins WAR |
| `images/agent-ubi` | UBI 8/9 inbound-agent image built from a matching `agent.jar` |
| `images/agent-ready-ubi` | Adds tools and CAs to an existing UBI inbound-agent image |
| `ci/build-images.sh` | CI-neutral build and push script |
| `controller.yml` | Controller host deployment playbook |
| `agent.yml` | WebSocket inbound-agent deployment playbook |
| `casc/jenkins.example.yaml` | Minimal JCasC starting point |
| `vars/*.example.yml` | Documented deployment variables |

## Architecture

```text
Git repository              CI runner                 Internal registry
Dockerfiles + JCasC  --->   build, scan, sign  --->  immutable image tags
      CA files                    |                          |
                                  |                          v
Ansible control node  --------------------------------> Docker/Podman hosts
                                                           | controller: HTTPS
                                                           | agent: HTTPS WebSocket
                                                           v
                                                        clients
```

The controller serves HTTPS directly on its container port. Inbound agents use
WebSocket over that same HTTPS endpoint, so port `50000` is not required. A
reverse proxy or load balancer can be added later, but its backend protocol and
forwarded headers must match the Jenkins configuration.

## Choose a CA strategy

The Dockerfiles and playbooks support three modes:

| Mode | Use when | Rotation behavior |
|---|---|---|
| `image` | CAs are stable and every environment uses the same trust | Rebuild and redeploy images |
| `runtime` | CAs differ by environment or rotate frequently | Rerun Ansible |
| `both` | A corporate baseline is baked in and environment CAs are added later | Rebuild baseline or rerun Ansible as appropriate |

Set the controller and agent independently:

```yaml
jenkins_controller_ca_mode: runtime
jenkins_agent_ca_mode: runtime
```

### Why two truststores matter

- OS tools such as `curl`, Git, Python, package managers, and many CLIs use the
  container OS CA bundle.
- Jenkins core, plugins, and Remoting use the Java truststore selected by the
  JVM.

Adding a CA to only one frequently produces the confusing situation where
`curl` succeeds but Jenkins reports `PKIX path building failed`, or Java works
while Git fails.

### CA input contract

The CA files are assumed to be ready for use. Every input must be one clean,
PEM-encoded X.509 CA certificate with a `.pem` or `.crt` extension. Do not pass
a binary certificate, PKCS#7 file, private key, leaf server certificate, or a
bundle containing several certificates.

More than one internal CA is supported and expected in many enterprises. Add
every required root and issuing/intermediate CA as a separate file. Give each
one a unique filename at image build time and a unique `alias` in the Ansible
variables. Both Dockerfiles validate every file independently. Both playbooks
also validate every copied file with OpenSSL and reject duplicate aliases
before modifying the truststores or starting Jenkins.

For example, a Microsoft AD CS hierarchy might require both files:

```text
corp-root.crt
corp-issuing-01.crt
```

You can inspect the already-clean inputs without changing them:

```bash
openssl x509 -in corp-root.crt -noout -subject -issuer -dates -fingerprint -sha256
openssl x509 -in corp-issuing-01.crt -noout -subject -issuer -dates -fingerprint -sha256
```

## Build-time CA injection

Place all required PEM CAs in each desired build context:

```text
images/controller-ubi9/internal-cas/
images/agent-ubi/internal-cas/
images/agent-ready-ubi/internal-cas/
```

The Dockerfiles validate each CA with OpenSSL, install it under UBI's
`/etc/pki/ca-trust/source/anchors`, run `update-ca-trust`, and import it into
Java `cacerts`. An empty directory is valid.

CA certificates are public material, but their provenance still matters.
Review changes to the CA directory like code and verify fingerprints against a
separate trusted channel.

## CI image build

The CI job must supply:

- an internally mirrored UBI base image;
- an approved `jenkins.war`;
- a matching Jenkins Remoting `agent.jar`;
- approved plugins, including Configuration as Code; and
- any baseline CA files.

Place the artifacts at:

```text
images/controller-ubi9/artifacts/jenkins.war
images/agent-ubi/artifacts/agent.jar
images/controller-ubi9/plugins/*.hpi
```

Run the portable build script from a CI job that is already authenticated to
the internal registry:

```bash
export CONTAINER_CLI=docker
export CONTROLLER_BASE_IMAGE=registry.internal.example/base/ubi9:9.6
export CONTROLLER_IMAGE=registry.internal.example/jenkins/controller:2.541.1-1
export AGENT_BASE_IMAGE=registry.internal.example/base/ubi9:9.6
export AGENT_IMAGE=registry.internal.example/jenkins/inbound-agent:2.541.1-1

./ci/build-images.sh
```

The same script works in GitLab CI, GitHub Actions, or Jenkins itself. Keep
registry credentials in the CI secret store, not the repository. Recommended
pipeline stages are:

1. Fetch approved WAR, JAR, plugins, and CA artifacts.
2. Verify vendor/internal SHA-256 checksums.
3. Build with an immutable versioned tag.
4. Scan the OS packages, application dependencies, and secrets.
5. Generate an SBOM and sign the image.
6. Push the immutable tag or digest to the internal registry.
7. Promote by digest between environments rather than rebuilding.

Avoid mutable `latest` tags for production deployments.

## Runtime CA injection with Ansible

Runtime mode performs these operations:

1. Copies each CA to the RHEL host trust anchors and runs `update-ca-trust`.
2. Copies the host's complete OS bundle—public plus internal roots—to a
   read-only file mounted over the image's OS bundle.
3. Starts a dedicated Java truststore from the host's default Java `cacerts`,
   changes its password, and imports every configured internal CA.
4. Mounts the dedicated Java truststore read-only and selects it through JVM
   properties.

This preserves public roots. Creating a new truststore containing only internal
CAs would break Jenkins access to otherwise trusted public services.

Example CA variables:

```yaml
jenkins_controller_ca_mode: runtime
jenkins_controller_trusted_ca_files:
  - alias: microsoft-corp-root-2026
    src: files/microsoft-corp-root-2026.crt
  - alias: microsoft-issuing-ca-01
    src: files/microsoft-issuing-ca-01.crt

jenkins_controller_container_os_ca_bundle_path: /etc/pki/tls/certs/ca-bundle.crt
```

The default bundle target is correct for the supplied UBI images. For a
Debian-based image, use:

```yaml
jenkins_controller_container_os_ca_bundle_path: /etc/ssl/certs/ca-certificates.crt
```

Use the corresponding `jenkins_agent_*` variables for agents. If a CA is
removed rather than rotated, delete the generated host truststore once and
rerun the playbook so it is rebuilt from the current desired set.

## Prepare Ansible

Install the collections listed in `requirements.yml`. For a disconnected
control environment, download them in connected CI and publish the archives to
the internal artifact repository:

```bash
ansible-galaxy collection install -r requirements.yml
```

The managed RHEL-family hosts need local repositories providing:

```text
ca-certificates
java-21-openjdk-headless
openssl
python3-requests
```

Those package tasks intentionally remain in the playbooks even when the images
contain the same tools: the host needs Java/keytool and certificate tooling to
prepare runtime trust, and `community.docker` needs Python Requests.

## Configure inventory and secrets

Copy the examples:

```bash
cp inventory.example.yml inventory.yml
cp vars/controller.example.yml controller-vars.yml
cp vars/agent.example.yml agent-vars.yml
ansible-vault encrypt controller-vars.yml
ansible-vault encrypt agent-vars.yml
```

Registry access is anonymous by default. If required, supply all three
registry variables through the encrypted vars file. The Docker module path
logs in only for the controlled pull and logs out afterward.

## HTTPS certificate requirements

The controller requires:

- an unencrypted PEM private key;
- a PEM certificate whose SAN contains the client-visible DNS name; and
- preferably a full-chain certificate file containing the leaf followed by
  any issuing intermediates.

Verify before deployment:

```bash
openssl x509 -in files/jenkins.example.test.fullchain.crt \
  -noout -subject -issuer -dates -ext subjectAltName
openssl pkey -in files/jenkins.example.test.key -check -noout

openssl x509 -in files/jenkins.example.test.fullchain.crt -pubkey -noout \
  | openssl pkey -pubin -outform DER | sha256sum
openssl pkey -in files/jenkins.example.test.key -pubout -outform DER \
  | sha256sum
```

The last two hashes must match.

The playbook converts the certificate and key to PKCS#12, disables plain HTTP,
and starts Jenkins on the configured container HTTPS port.

## Understand port mapping

Container publishing uses this order:

```text
HOST_BIND_ADDRESS:HOST_PORT:CONTAINER_PORT
```

The defaults produce:

```text
0.0.0.0:8443:8443
```

Important examples:

| Desired client URL | Bind address | Host port | Container port |
|---|---:|---:|---:|
| `https://jenkins.example.test:8443` | `0.0.0.0` | `8443` | `8443` |
| `https://jenkins.example.test` | `0.0.0.0` | `443` | `8443` |
| local host only | `127.0.0.1` | `8443` | `8443` |

For standard HTTPS externally with Jenkins still listening on `8443` inside:

```yaml
jenkins_controller_bind_address: 0.0.0.0
jenkins_controller_host_port: 443
jenkins_controller_container_port: 8443
jenkins_controller_url: https://jenkins.example.test
```

The DNS record must resolve to the host or load balancer, the firewall must
allow the **host** port, and the certificate SAN must match the DNS name.
Clients never connect directly to the container IP.

The playbook does not change firewall policy unless explicitly enabled:

```yaml
jenkins_controller_manage_firewall: true
jenkins_controller_firewall_zone: public
```

That option expects firewalld to be installed and running. Leave it disabled
when firewall rules are managed by another team or automation system.

Do not map `443:443` unless Jenkins is actually configured to listen on `443`
inside the container. A mismatched right-hand port commonly causes connection
refused or reset errors.

## Deploy the controller

```bash
ansible-playbook -i inventory.yml controller.yml \
  --ask-vault-pass --extra-vars @controller-vars.yml
```

The playbook:

- uses `community.docker` for Docker image operations and a documented CLI
  fallback for Podman;
- creates `/srv/jenkins/controller` as persistent Jenkins home;
- prepares host, OS-container, and Java CA trust;
- creates the HTTPS PKCS#12 keystore;
- imports the optional JCasC file;
- renders and enables `jenkins-controller.service`; and
- validates the HTTPS login endpoint with certificate verification enabled.

Check the deployment:

```bash
sudo systemctl status jenkins-controller
sudo journalctl -u jenkins-controller -n 100 --no-pager
sudo docker ps --filter name=jenkins-controller
curl --cacert files/microsoft-corp-root-2026.crt \
  https://jenkins.example.test:8443/login
```

Use `podman` instead of `docker` when selected.

## Jenkins Configuration as Code

The image must contain the Configuration as Code plugin and all plugins
referenced by the YAML. Set:

```yaml
jenkins_controller_jcasc_file: casc/jenkins.example.yaml
```

The playbook copies it to persistent Jenkins home and sets
`CASC_JENKINS_CONFIG`.

### Generate a starting JCasC file

There is no reliable universal generator independent of installed plugins.
Use a temporary controller with the exact production plugin set:

1. Install and configure the controller through the UI.
2. Open **Manage Jenkins → Configuration as Code → View Configuration**.
3. Select **Download Configuration**.
4. Remove exported credentials, tokens, private keys, and environment-specific
   values.
5. Replace secrets with environment interpolation or an approved Jenkins
   credentials provider.
6. Store the sanitized YAML in Git and review it like application code.
7. Test both **Reload existing configuration** and a complete restart in a
   disposable controller before production.

Do not alternate between UI edits and JCasC ownership of the same setting;
JCasC will restore its declared value on restart.

## Deploy an inbound agent

Create a permanent node in Jenkins with launch method **Launch agent by
connecting it to the controller**, then copy its name and secret into the
encrypted agent vars file.

```bash
ansible-playbook -i inventory.yml agent.yml \
  --ask-vault-pass --extra-vars @agent-vars.yml
```

The agent uses `-webSocket` and connects outbound to the controller HTTPS URL.
Port `50000` should remain disabled unless a legacy TCP agent explicitly needs
it.

## Reverse proxy or load balancer

Direct Jenkins HTTPS is the default here. If a proxy or load balancer fronts
Jenkins, choose one TLS model and document it:

- TLS passthrough: proxy TCP `443` to the host's published HTTPS port.
- TLS re-encryption: proxy terminates client TLS and creates a new HTTPS
  connection to Jenkins; it must trust the Jenkins certificate.
- TLS termination with HTTP backend: requires changing Jenkins to listen on
  HTTP internally; do not send HTTP to this package's default HTTPS port.

For an HTTP-aware proxy, preserve `Host`, `X-Forwarded-Host`,
`X-Forwarded-Port`, and `X-Forwarded-Proto`, and support WebSocket upgrades.
Set the Jenkins root URL to the externally visible URL, not the container or
backend address.

## Troubleshooting HTTPS and connection resets

Work from outside inward.

### 1. Confirm DNS and the client-visible port

```bash
getent ahosts jenkins.example.test
nc -vz jenkins.example.test 8443
```

If TCP cannot connect, investigate routing, security groups, firewalld, and the
host bind address before changing Jenkins.

### 2. Inspect the host listener and published mapping

```bash
sudo ss -lntp | grep ':8443'
sudo docker port jenkins-controller
sudo docker inspect jenkins-controller --format '{{json .NetworkSettings.Ports}}'
```

Expected mapping: host `8443` to container `8443`. A listener on `127.0.0.1`
is intentionally inaccessible from remote clients.

### 3. Determine whether the port speaks HTTP or HTTPS

```bash
curl -vk https://127.0.0.1:8443/login
openssl s_client -connect 127.0.0.1:8443 \
  -servername jenkins.example.test -showcerts </dev/null
```

Common reset causes include:

- sending HTTP to an HTTPS listener or HTTPS to an HTTP listener;
- mapping the host port to the wrong container port;
- a proxy configured with `http://backend:8443` while Jenkins expects HTTPS;
- Jenkins crashing during the TLS handshake because its keystore is invalid;
- a load balancer health check using the wrong protocol;
- firewall reject rules; or
- the service repeatedly restarting.

### 4. Check service and container logs

```bash
sudo systemctl status jenkins-controller
sudo journalctl -u jenkins-controller -n 200 --no-pager
sudo docker logs --tail 200 jenkins-controller
sudo systemctl show jenkins-controller -p NRestarts -p ExecMainStatus
```

Look for `Address already in use`, PKCS#12 errors, permission denials, invalid
JCasC, or plugin dependency failures.

### 5. Validate the served chain and hostname

```bash
openssl s_client -connect jenkins.example.test:8443 \
  -servername jenkins.example.test -verify_return_error </dev/null
```

If browsers trust the root but report an incomplete chain, provide the issuing
intermediate certificates in the controller full-chain file. The private key
must match the leaf certificate and the SAN—not only the common name—must
contain the client DNS name.

### 6. Distinguish OS trust from Java trust

```bash
sudo docker exec jenkins-controller \
  curl -v https://internal-service.example.test

sudo keytool -list \
  -keystore /etc/jenkins-controller/tls/truststore.jks
```

- `curl` fails: inspect the mounted OS bundle and CA chain.
- `curl` succeeds but Jenkins reports `PKIX`: inspect `JAVA_OPTS`, the Java
  truststore path, aliases, and truststore password.
- Java succeeds but Git fails: inspect `SSL_CERT_FILE` and `GIT_SSL_CAINFO`.

### 7. Check SELinux and permissions

```bash
sudo ausearch -m AVC -ts recent
sudo ls -lZ /srv/jenkins/controller /etc/jenkins-controller/tls
```

The generated mounts use `:Z`. Keep the configured UID/GID aligned with the
image's Jenkins user.

## Operational checklist

- Pin controller, agent, base, plugin, WAR, and JAR versions.
- Keep controller and agent Java versions supported by the Jenkins release.
- Synchronize host time with NTP; TLS validation is time-sensitive.
- Configure DNS and `NO_PROXY` for internal registry and Jenkins names.
- Back up `/srv/jenkins/controller` and test restoration.
- Set controller executors to zero and run builds only on agents.
- Do not mount Docker or Podman sockets into general-purpose agents.
- Restrict the controller host port to intended networks.
- Monitor certificate expiration and CA rotation.
- Test JCasC and plugin upgrades against a restored backup before production.

## Primary references

- [Jenkins Docker and custom CA guidance](https://www.jenkins.io/doc/book/installing/docker/)
- [Jenkins Configuration as Code](https://www.jenkins.io/doc/book/managing/casc/)
- [Jenkins reverse proxy configuration](https://www.jenkins.io/doc/book/system-administration/reverse-proxy-configuration-with-jenkins/)
- [Jenkins exposed services and WebSocket agents](https://www.jenkins.io/doc/book/security/services/)
- [Jenkins Java support policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/)
