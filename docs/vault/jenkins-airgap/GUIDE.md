# Air-gapped Jenkins controller and inbound agent

This package contains two independent Ansible playbooks:

| Playbook | Managed host | Result |
|---|---|---|
| `controller.yml` | RHEL, Rocky, AlmaLinux, or another Red Hat-family system | One persistent Jenkins controller container with HTTPS |
| `agent.yml` | RHEL/UBI-compatible 8 or newer system | One persistent inbound Jenkins agent container using WebSocket |

Both playbooks support rootful Docker or Podman. They are designed for a
restricted environment with an internal registry. Images can be pulled from
that registry during an Ansible deployment, already exist in the root image
store, or be copied from the Ansible control node as archives. Systemd startup
never pulls, so a reboot does not depend on registry availability.

The runtime layout is:

```text
                           HTTPS + WebSocket
┌──────────────────────┐  <-----------------  ┌──────────────────────┐
│ Jenkins controller   │                      │ Jenkins inbound agent│
│ container            │                      │ UBI 8/9 container    │
├──────────────────────┤                      ├──────────────────────┤
│ /var/jenkins_home    │                      │ /home/jenkins/agent  │
│ server PKCS#12       │                      │ Java truststore      │
│ Java truststore      │                      │ agent secret file    │
└──────────┬───────────┘                      └──────────┬───────────┘
           │ bind mounts                                 │ bind mounts
┌──────────▼───────────┐                      ┌──────────▼───────────┐
│ RHEL controller host │                      │ RHEL agent host      │
│ systemd service      │                      │ systemd service      │
│ Docker or Podman     │                      │ Docker or Podman     │
└──────────────────────┘                      └──────────────────────┘
```

WebSocket transport means the agent initiates an outbound HTTPS connection to
the controller. Jenkins TCP agent port `50000` does not need to be published.

## What the playbooks manage

### Controller

The controller playbook:

1. Confirms that the managed host is Red Hat-family and Docker or Podman exists.
2. Installs `ca-certificates`, OpenSSL, and host `keytool` support.
3. Creates `/srv/jenkins/controller` for persistent Jenkins state.
4. Copies the HTTPS certificate, private key, and trusted CAs.
5. Adds the CAs to the RHEL host trust store.
6. Creates a PEM CA bundle for container tools and a separate Java JKS
   truststore.
7. Converts the HTTPS certificate and key into a PKCS#12 server keystore.
8. Pulls from an internal registry, loads an offline archive, or verifies a
   preloaded image.
9. Writes a protected container environment file.
10. Installs and enables `jenkins-controller.service`.
11. Waits for HTTPS and validates the server certificate.

The controller exposes HTTPS only. Plain HTTP is disabled through:

```text
--httpPort=-1
--httpsPort=8443
```

### Agent

The agent playbook:

1. Confirms that the host is RHEL/UBI-compatible version 8 or newer.
2. Installs the same certificate and Java tooling.
3. Adds the controller CA to the host, a container PEM bundle, and a dedicated
   Java truststore.
4. Stores the Jenkins inbound-agent secret in a root-owned file.
5. Pulls from an internal registry, loads an offline archive, or verifies a
   preloaded image.
6. Creates a persistent agent work directory.
7. Installs and enables `jenkins-agent.service`.
8. Runs the agent with WebSocket transport and verifies the container remains up.

The agent secret is passed to Jenkins Remoting as a file reference:

```text
-secret @/run/jenkins/secret/agent-secret
```

It is not placed in the systemd unit or process argument list as a literal.

## Image requirements

The playbooks are intentionally image-agnostic because a restricted site may
use an internally approved or prebuilt image.

### Controller image contract

The controller image must:

- run Jenkins from its normal entrypoint;
- use `/var/jenkins_home` for persistent state;
- honor `JAVA_OPTS` and `JENKINS_OPTS`;
- contain a JDK compatible with its Jenkins version; and
- contain all required plugins before entering the air gap.

The official `jenkins/jenkins` image satisfies this interface. If policy
requires a UBI/RHEL-based controller image, build or obtain an approved image
that preserves the same paths and environment interface. The playbook does not
assume a public image name.

### Agent image contract

The default service command expects an image compatible with the Jenkins
inbound-agent entrypoint. It must contain:

- Jenkins Remoting `agent.jar`;
- a compatible Java runtime;
- an entrypoint that passes command arguments to the inbound agent; and
- any build tools required by the jobs assigned to the node.

A UBI 8/9 image built from the Jenkins inbound-agent project is suitable. A
generic UBI image or an OpenShift agent-base image may not have the expected
entrypoint. For a different image, override `jenkins_agent_command` in the
agent variables.

Pin images by immutable tag or digest. Avoid floating tags such as `latest`.

## Build the supplied UBI images

Three build contexts accompany the playbooks:

| Build context | Purpose |
|---|---|
| `images/controller-ubi9` | UBI 9 Jenkins controller built from an approved `jenkins.war` |
| `images/agent-ubi` | Custom UBI 8 or 9 inbound agent built from an approved `agent.jar` |
| `images/agent-ready-ubi` | Adds common packages to an existing UBI Jenkins inbound-agent image |

The controller and custom agent builds deliberately use artifacts already
obtained from an internal artifact repository. They do not download Jenkins
content from the internet during `docker build`.

### Build the controller

Place the approved WAR in the build context and place any approved `.hpi` or
`.jpi` files in its `plugins` directory:

```bash
cp /approved/artifacts/jenkins.war \
  jenkins-airgap/images/controller-ubi9/artifacts/jenkins.war

cd jenkins-airgap/images/controller-ubi9
war_sha256=$(sha256sum artifacts/jenkins.war | awk '{print $1}')

docker build \
  --build-arg BASE_IMAGE=registry.internal.example/base/ubi9:9.6 \
  --build-arg JENKINS_WAR_SHA256="${war_sha256}" \
  --tag registry.internal.example/jenkins/controller:lts-jdk21 \
  .

docker push registry.internal.example/jenkins/controller:lts-jdk21
```

The image runs as UID/GID `1000`, uses `/var/jenkins_home`, honors `JAVA_OPTS`
and `JENKINS_OPTS`, and seeds missing plugins into a new persistent home. The
WAR checksum argument is mandatory, so an unverified artifact cannot build.

### Build a custom UBI 8/9 agent

Use the Remoting JAR matching the controller. It can be sourced internally from
the controller's `/jnlpJars/agent.jar` endpoint or the approved artifact store:

```bash
cp /approved/artifacts/agent.jar \
  jenkins-airgap/images/agent-ubi/artifacts/agent.jar

cd jenkins-airgap/images/agent-ubi
agent_sha256=$(sha256sum artifacts/agent.jar | awk '{print $1}')

docker build \
  --build-arg BASE_IMAGE=registry.internal.example/base/ubi9:9.6 \
  --build-arg JENKINS_AGENT_JAR_SHA256="${agent_sha256}" \
  --tag registry.internal.example/jenkins/inbound-agent:ubi9 \
  .

docker push registry.internal.example/jenkins/inbound-agent:ubi9
```

For UBI 8, change `BASE_IMAGE` and the output tag. The selected UBI repositories
must provide Java 21; current Jenkins releases require Java 21 or newer for the
controller and Remoting agents.

### Extend a ready-made UBI agent

When the internal registry already contains a functioning Jenkins inbound
agent, use the thin extension Dockerfile:

```bash
cd jenkins-airgap/images/agent-ready-ubi

docker build \
  --build-arg BASE_IMAGE=registry.internal.example/jenkins/inbound-agent:ubi9-base \
  --tag registry.internal.example/jenkins/inbound-agent:ubi9-tools \
  .

docker push registry.internal.example/jenkins/inbound-agent:ubi9-tools
```

This variant preserves the ready-made image's entrypoint and adds CA tooling,
OpenSSL, Java 21, Git, SSH, Python Requests, archive tools, and basic process
utilities. Confirm that its Jenkins user is UID/GID `1000`, or override
`jenkins_agent_uid` and `jenkins_agent_gid` in the playbook variables.

Podman can replace Docker in these examples with equivalent `podman build` and
`podman push` commands.

### Why the playbooks still install packages

The Dockerfiles install runtime packages inside the containers. The package
tasks in both playbooks intentionally remain: they install `ca-certificates`,
OpenSSL, Java/keytool, and Python Requests on the managed host so Ansible can
build truststores, validate certificates, and use `community.docker`. Keeping
those tasks provides a preventative prerequisite check even when images have
already been fully prepared.

## Use an internal registry

The examples use fully qualified internal names:

```yaml
jenkins_controller_image: "registry.internal.example/jenkins/controller:lts-jdk21"
jenkins_controller_image_pull_policy: missing
jenkins_controller_image_archive: ""
```

The pull policy controls what happens during the Ansible run:

| Policy | Behavior |
|---|---|
| `missing` | Pull only when the image is absent from the root image store |
| `always` | Pull on every playbook run |
| `never` | Require a preloaded image or use an archive |

Archive mode and registry-pull mode are deliberately mutually exclusive. To
use an archive, set the policy to `never` and specify the archive path.

Anonymous registry access is the default:

```yaml
container_registry_server: ""
container_registry_username: ""
container_registry_password: ""
```

With empty values, Docker or Podman pulls anonymously. An existing root-engine
login can also be used. If authentication is later enabled, pass all three
values through the encrypted playbook variables:

```yaml
container_registry_server: "registry.internal.example"
container_registry_username: "jenkins-image-reader"
container_registry_password: "REPLACE-IN-ANSIBLE-VAULT"
```

The password-bearing module tasks run under `no_log`; the password is never
placed in the generated systemd unit, container environment, or pull command
arguments. With Docker, `community.docker.docker_login` establishes the login,
the image module performs the pull, and the playbook logs out afterward. The
CLI fallback uses a temporary Docker configuration or Podman auth file and
removes it afterward. Encrypt any vars file that supplies credentials with
`ansible-vault`.

### Image-management backend

Docker image operations use Ansible modules by default:

- `community.docker.docker_image_info` for inspection;
- `community.docker.docker_image_load` for archives;
- `community.docker.docker_image_pull` for registry pulls; and
- `community.docker.docker_login` when credentials are supplied; and
- `community.docker.docker_container_info` for the final agent health check.

The selection variable is:

```yaml
container_image_backend: auto
```

`auto` selects `community.docker` when `container_engine: docker` and selects
the CLI fallback for Podman. Set `container_image_backend: cli` only when the
Docker modules cannot be used. `container_image_backend: modules` requires
Docker and prevents an accidental Podman/`community.docker` combination.

The generated systemd service still executes the selected container engine;
that command is the long-running process systemd supervises. The fallback
setting applies to Ansible's image inspection, loading, login, and pull tasks.

If the registry uses an internal CA, include its issuing CA in the appropriate
`jenkins_*_trusted_ca_files` list. The playbook refreshes the RHEL host trust
before pulling. Some Docker configurations may additionally require the CA at
`/etc/docker/certs.d/REGISTRY_HOST[:PORT]/ca.crt`; follow the registry and
Docker standards used at the site.

The generated services retain `--pull=never`. Ansible performs the controlled
pull, validates that the image exists, and then restarts the service. This
allows existing containers to recover even while the registry is down.

## Prepare archive images when the registry is unavailable

On a connected staging system, obtain or build approved images and save them:

```bash
podman pull registry.internal.example/jenkins/controller:lts-jdk21
podman save --format oci-archive \
  --output jenkins-controller-lts-jdk21.tar \
  registry.internal.example/jenkins/controller:lts-jdk21

podman pull registry.internal.example/jenkins/inbound-agent:ubi9
podman save --format oci-archive \
  --output jenkins-inbound-agent-ubi9.tar \
  registry.internal.example/jenkins/inbound-agent:ubi9
```

Docker archives are also supported:

```bash
docker save --output jenkins-controller.tar IMAGE_NAME
docker save --output jenkins-agent.tar IMAGE_NAME
```

Transfer the archives through the site's approved media and integrity-checking
process. Record SHA-256 hashes before and after transfer:

```bash
sha256sum jenkins-controller-lts-jdk21.tar
sha256sum jenkins-inbound-agent-ubi9.tar
```

The name in `jenkins_controller_image` or `jenkins_agent_image` must exactly
match a name loaded from the archive. Check it after a manual load with:

```bash
sudo podman images
# or
sudo docker images
```

These playbooks use the root image store because systemd runs the containers as
root. An image loaded under an ordinary user's rootless Podman store is not
visible to this deployment.

## Prepare certificates

The controller needs:

- a PEM server certificate or full chain for its DNS name;
- the matching unencrypted PEM private key; and
- every internal root/intermediate CA Jenkins must trust.

The agent needs the CA chain that issued the controller certificate. Use the CA
certificate, not the controller leaf certificate, as the trust anchor.

Example verification on the Ansible control node:

```bash
openssl x509 -in files/jenkins.homelab.test.fullchain.crt \
  -noout -subject -issuer -dates -ext subjectAltName

openssl pkey -in files/jenkins.homelab.test.key -check -noout

openssl verify \
  -CAfile files/homelab-root-ca.crt \
  files/jenkins.homelab.test.fullchain.crt
```

The certificate SAN must contain the exact hostname in
`jenkins_controller_url`.

The playbooks create a dedicated truststore rather than modifying the JDK
truststore inside the image. It is bind-mounted read-only and selected through
Java system properties. This keeps the image immutable and makes CA rotation
an Ansible operation.

They also bind-mount a PEM bundle and set the conventional CA variables used
by OpenSSL, curl, Git, Python Requests, and Node.js. Image-specific tools may
use a different CA setting; add that setting with the relevant
`*_extra_environment` variable.

## Install the Ansible collections

`community.general.java_cert` manages the JKS truststores and
`community.docker` manages Docker images and registry sessions. Install the
pinned minimum collection versions on the connected Ansible control system
before moving dependencies into the restricted environment:

```bash
ansible-galaxy collection download \
  -r jenkins-airgap/requirements.yml \
  --download-path ./offline-collections
```

Move those artifacts into the air gap, then install them locally:

```bash
ansible-galaxy collection install \
  offline-collections/community-general-*.tar.gz \
  offline-collections/community-docker-*.tar.gz
```

The managed hosts also need configured RHEL repositories containing:

```text
ca-certificates
java-21-openjdk-headless
openssl
python3-requests
```

No internet repository is used by the playbooks. Package installation must be
satisfied by the site's local RPM repositories or preinstalled packages.

## Inventory

Copy the example inventory:

```bash
cp jenkins-airgap/inventory.example.yml inventory-jenkins.yml
```

Edit the addresses:

```yaml
all:
  children:
    jenkins_controller:
      hosts:
        jenkins-controller-01:
          ansible_host: 192.0.2.10

    jenkins_agents:
      hosts:
        jenkins-agent-01:
          ansible_host: 192.0.2.20
```

## Controller variables

Copy the example and replace its values:

```bash
cp jenkins-airgap/vars/controller.example.yml controller.yml
ansible-vault encrypt controller.yml
```

Important settings:

```yaml
container_engine: docker
container_image_backend: auto
jenkins_controller_image: "registry.internal.example/jenkins/controller:lts-jdk21"
jenkins_controller_image_pull_policy: missing
jenkins_controller_image_archive: ""

# Anonymous by default; set all three only if the registry requires them.
container_registry_server: ""
container_registry_username: ""
container_registry_password: ""

jenkins_controller_tls_certificate_file: "files/jenkins.homelab.test.fullchain.crt"
jenkins_controller_tls_private_key_file: "files/jenkins.homelab.test.key"
jenkins_controller_trusted_ca_files:
  - alias: homelab-root
    src: files/homelab-root-ca.crt

jenkins_controller_keystore_password: "a-long-random-password"
jenkins_controller_url: "https://jenkins.homelab.test:8443"
```

Even though only the passwords are secret, encrypting the whole vars file
avoids accidental disclosure and gives one simple handling rule.

Use a 12-character-or-longer password containing letters, digits, `.`, `_`,
`~`, or `-`; this avoids ambiguous environment-file parsing. A strong value is
easy to generate with `openssl rand -hex 24`. Apply the same rule to the agent
truststore password.

## Deploy the controller

Run a syntax check and a dry run first:

```bash
ansible-playbook \
  -i inventory-jenkins.yml \
  jenkins-airgap/controller.yml \
  --syntax-check

ansible-playbook \
  -i inventory-jenkins.yml \
  jenkins-airgap/controller.yml \
  --ask-vault-pass \
  --extra-vars @controller.yml \
  --check --diff
```

Private-key and password-bearing tasks use `no_log`, but avoid saving verbose
Ansible output in broadly readable logs.

Deploy:

```bash
ansible-playbook \
  -i inventory-jenkins.yml \
  jenkins-airgap/controller.yml \
  --ask-vault-pass \
  --extra-vars @controller.yml
```

The resulting service is enabled at boot and uses `Restart=on-failure`:

```bash
sudo systemctl status jenkins-controller
sudo journalctl -u jenkins-controller -f
sudo podman ps --filter name=jenkins-controller
```

Persistent data is under `/srv/jenkins/controller`. Replacing or restarting the
container does not replace Jenkins home.

## First controller initialization

For a new home directory, complete the Jenkins setup wizard at the configured
HTTPS URL. The initial password remains inside the persistent home:

```bash
sudo cat /srv/jenkins/controller/secrets/initialAdminPassword
```

In an air gap, the controller cannot download plugins. Bake the exact plugin
set into the image beforehand, or provide a tested JCasC file and preinstalled
plugins. The optional `jenkins_controller_jcasc_file` variable copies a JCasC
file into Jenkins home and sets `CASC_JENKINS_CONFIG`.

Set the built-in node's executor count to `0`. Jenkins recommends running
builds on agents rather than on the controller.

## Register the inbound agent

Before deploying the agent container:

1. Open **Manage Jenkins → Nodes**.
2. Create a permanent agent using the desired `jenkins_agent_name`.
3. Select **Launch agent by connecting it to the controller**.
4. Set its remote root directory to `/home/jenkins/agent`.
5. Save it and copy the generated inbound-agent secret.

The name in Jenkins must exactly match `jenkins_agent_name`.

## Agent variables

Copy and encrypt the example:

```bash
cp jenkins-airgap/vars/agent.example.yml agent.yml
ansible-vault encrypt agent.yml
```

Important settings:

```yaml
container_engine: docker
container_image_backend: auto
jenkins_agent_image: "registry.internal.example/jenkins/inbound-agent:ubi9"
jenkins_agent_image_pull_policy: missing
jenkins_agent_image_archive: ""

# Anonymous by default; set all three only if the registry requires them.
container_registry_server: ""
container_registry_username: ""
container_registry_password: ""

jenkins_controller_url: "https://jenkins.homelab.test:8443"
jenkins_agent_name: "ubi9-agent-01"
jenkins_agent_secret: "the-secret-from-the-node-page"

jenkins_agent_trusted_ca_files:
  - alias: homelab-root
    src: files/homelab-root-ca.crt

jenkins_agent_truststore_password: "another-long-random-password"
```

## Deploy the agent

```bash
ansible-playbook \
  -i inventory-jenkins.yml \
  jenkins-airgap/agent.yml \
  --syntax-check

ansible-playbook \
  -i inventory-jenkins.yml \
  jenkins-airgap/agent.yml \
  --ask-vault-pass \
  --extra-vars @agent.yml
```

The service is enabled at boot and uses `Restart=always`. Remoting also retries
its WebSocket connection when the controller is temporarily unavailable.

Check it without displaying credentials:

```bash
sudo systemctl status jenkins-agent
sudo journalctl -u jenkins-agent -f
sudo podman ps --filter name=jenkins-agent
```

The node should become online in the Jenkins UI.

## Docker and Podman selection

Docker is the default and uses `community.docker` image modules:

```yaml
container_engine: docker
container_image_backend: auto
```

The Docker daemon must already be installed, enabled, and usable by root. The
generated systemd unit adds an explicit dependency on `docker.service`.

For Podman:

```yaml
container_engine: podman
container_image_backend: auto
```

Podman is daemonless, so its unit depends only on network readiness. In `auto`
mode, Podman uses the documented raw-engine fallback because
`community.docker` communicates with the Docker API.

## Additional bind mounts

Controller example:

```yaml
jenkins_controller_extra_bind_mounts:
  - source: /srv/jenkins/shared
    target: /opt/jenkins/shared
    options: ro,Z
```

Agent example:

```yaml
jenkins_agent_extra_bind_mounts:
  - source: /srv/build-cache
    target: /home/jenkins/.cache
    options: Z
```

`:Z` gives the path a private SELinux label suitable for one container. Use
`:z` only when the same path is intentionally shared between containers.

Do not mount `/var/run/docker.sock` or the Podman socket by default. A job with
access to an engine socket effectively has control of the host. If builds must
create containers, use a purpose-built isolated agent and document that trust
boundary explicitly.

## Custom agent entrypoints

The default command is represented as a readable list:

```yaml
jenkins_agent_command:
  - -url
  - "${JENKINS_CONTROLLER_URL_ARG}"
  - -webSocket
  - -secret
  - "@/run/jenkins/secret/agent-secret"
  - -name
  - "${JENKINS_AGENT_NAME_ARG}"
  - -workDir
  - "${JENKINS_AGENT_WORKDIR_ARG}"
```

Override that list if an approved ready-made image uses a different CLI. Keep
the secret-file form if the image supports it. The `_ARG` variables avoid
triggering the inbound-agent entrypoint's legacy environment handling in
addition to the explicit command arguments.

## Updates and rollback

For an update:

1. Test the new controller and agent images outside production.
2. Export and verify a Jenkins-home backup.
3. Push the new immutable image tag to the internal registry, or transfer its
   archive and record the hash.
4. Change the immutable image tags in the encrypted vars files.
5. Run the playbooks.

The unit removes and recreates only the container. Persistent bind mounts
remain untouched.

To roll back, restore a compatible Jenkins-home backup if required, select the
previous image tag, and rerun the controller playbook. Jenkins core and plugin
downgrades are not always safe; backups are part of the rollback plan.

## Troubleshooting

### Image not found

The playbooks run rootful containers. Inspect the root image store:

```bash
sudo podman image inspect IMAGE_NAME
# or
sudo docker image inspect IMAGE_NAME
```

If an archive loads under a different tag, either retag it or update the image
variable.

### Internal registry pull fails

Run the same operation through the root engine used by the service:

```bash
sudo podman pull registry.internal.example/jenkins/inbound-agent:ubi9
# or
sudo docker pull registry.internal.example/jenkins/inbound-agent:ubi9
```

An authentication error means all three `container_registry_*` variables need
to be supplied, or the existing root engine login is invalid. An `x509:
certificate signed by unknown authority` error means the registry CA is not
available to the host/container engine. Confirm DNS, proxy exclusions, the
registry port, and the complete CA chain. Avoid insecure-registry exceptions.

### Controller HTTPS does not start

```bash
sudo journalctl -u jenkins-controller -n 100 --no-pager
sudo openssl pkcs12 \
  -info \
  -in /etc/jenkins-controller/tls/server.p12 \
  -noout
```

Check that the certificate matches the private key and the container UID/GID
can read the bind-mounted keystores.

### `PKIX path building failed`

Verify the CA alias in the generated truststore:

```bash
sudo keytool -list \
  -keystore /etc/jenkins-agent/tls/truststore.jks
```

Then confirm that `JENKINS_JAVA_OPTS` is present inside the agent container:

```bash
sudo podman exec jenkins-agent-AGENT_NAME env | grep '^JENKINS_JAVA_OPTS='
```

Do not print the complete environment from either container because additional
variables may contain credentials.

### Agent container runs but the node remains offline

Check:

- controller URL and DNS resolution from the agent host;
- certificate SAN and trust chain;
- exact node-name match;
- whether the inbound secret was rotated when the node was recreated;
- that the image supports `-webSocket`; and
- controller and agent Jenkins Remoting compatibility.

```bash
sudo journalctl -u jenkins-agent -n 100 --no-pager
curl --cacert files/homelab-root-ca.crt \
  https://jenkins.homelab.test:8443/login
```

### Service restart loop

```bash
sudo systemctl status jenkins-agent
sudo systemctl show jenkins-agent \
  -p NRestarts -p ExecMainStatus -p ActiveState -p SubState
```

Systemd intentionally retries indefinitely. Fix the underlying image,
certificate, DNS, secret, or controller problem rather than disabling restart.

## Security notes

- Encrypt variable files containing keystore passwords and agent secrets.
- Keep controller and agent hosts separated when practical.
- Set controller executors to zero.
- Do not give ordinary build jobs access to the controller home.
- Do not expose port 50000 when all agents use WebSocket.
- Limit the controller HTTPS port in the host firewall to the networks that
  actually need Jenkins; the playbook does not alter site firewall policy.
- Do not mount the container-engine socket into general-purpose agents.
- Pin and scan images before moving them into the air gap.
- Back up `/srv/jenkins/controller` and test restoration regularly.
- Rotate the agent secret if its protected file or Ansible Vault is exposed.
- Treat the controller private key and Jenkins home as high-value secrets.

## References

- [Jenkins Docker installation and custom CA guidance](https://www.jenkins.io/doc/book/installing/docker/)
- [Jenkins inbound-agent image](https://github.com/jenkinsci/docker-agents/blob/master/README_inbound-agent.md)
- [Jenkins exposed services and WebSocket agents](https://www.jenkins.io/doc/book/security/services/)
- [Jenkins controller isolation](https://www.jenkins.io/doc/book/security/controller-isolation/)
- [Jenkins HTTPS startup options](https://www.jenkins.io/doc/book/installing/initial-settings/)
- [Ansible `community.general.java_cert`](https://docs.ansible.com/projects/ansible/latest/collections/community/general/java_cert_module.html)
- [Ansible `community.docker.docker_image_pull`](https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_image_pull_module.html)
- [Ansible `community.docker.docker_image_load`](https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_image_load_module.html)
- [Ansible `community.docker.docker_login`](https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_login_module.html)
