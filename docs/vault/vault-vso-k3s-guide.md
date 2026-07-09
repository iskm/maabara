# Vault Secrets Operator on k3s with External Vault

This guide documents the working setup in the homelab:

| Item | Value |
|---|---|
| k3s API used by Vault auth | `https://192.168.2.12:6443` |
| Vault | `https://vault.homelab.test:8200` |
| Secret style | Vault KV v1 synced by Vault Secrets Operator |
| Demo namespace | `demo` |
| Demo service account | `demo-app` |

## Top-to-bottom overview

The goal is simple: keep the real secret in Vault, then let a Kubernetes app use it without hardcoding it into a manifest or image.

In this setup, the path looks like this:

1. Vault stores the secret in a KV v1 mount.
2. The app runs in Kubernetes with its own ServiceAccount, `demo/demo-app`.
3. Vault uses Kubernetes auth to check that ServiceAccount token against the k3s API.
4. A Vault role maps `demo/demo-app` to a small Vault policy.
5. Vault Secrets Operator runs in k3s.
6. `VaultConnection` tells the operator how to reach Vault.
7. `VaultAuth` tells the operator how to log in.
8. `VaultStaticSecret` tells the operator which Vault path to read.
9. The operator creates a normal Kubernetes Secret.
10. The pod mounts that Kubernetes Secret as files.

The chain to remember:

```text
VaultConnection -> VaultAuth -> VaultStaticSecret -> Kubernetes Secret -> Pod
```

Objects used here:

| Object | Name |
|---|---|
| `VaultConnection` | `demo/vault` |
| `VaultAuth` | `demo/demo-app` |
| `VaultStaticSecret` | `demo/demo-config` |
| Kubernetes Secret | `demo/demo-config` |
| Deployment | `demo/demo-app` |

## Security note

Vault Secrets Operator writes data into Kubernetes Secret objects. That is convenient, and it works well for apps that already expect Kubernetes Secrets. It also means the secret can show up in the Kubernetes API, etcd, backups, and anywhere else Kubernetes Secrets are handled.

For secrets that should never become Kubernetes Secret objects, use Vault CSI Provider or Vault Agent Injector instead. This guide uses VSO because that was the goal for this lab.

## References

- [HashiCorp VSO installation](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/installation)
- [HashiCorp VSO API reference](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
- [HashiCorp Kubernetes auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes)

## Assumptions

Run these commands from a workstation that already has `kubectl`, `helm`, and `vault` configured.

The Vault token you use needs enough privilege to enable auth methods, write auth config, create policies, and write the test KV secret.

You can reach:

```text
https://192.168.2.12:6443
https://vault.homelab.test:8200
```

You also need the CA that issued Vault's HTTPS certificate. In this lab that is the OPNsense CA.

Where to get it:

1. In OPNsense, go to `System -> Trust -> Authorities`.
2. Export the CA that issued the Vault certificate.
3. Save it on your workstation as `./vault-ca.crt`.

The file must be PEM:

```text
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
```

## 1. Set variables

```bash
export VAULT_ADDR="https://vault.homelab.test:8200"
export K8S_HOST="https://192.168.2.12:6443"
export K8S_AUTH_PATH="kubernetes-k3s"
export APP_NAMESPACE="demo"
export APP_SERVICE_ACCOUNT="demo-app"
export VAULT_ROLE="demo-app"
export VAULT_POLICY="k3s-demo-app"
export KV_MOUNT="kv"
export KV_PATH="apps/demo/config"
export VAULT_CA_FILE="./vault-ca.crt"
```

Use a Kubernetes API name or IP that is actually present in the k3s API certificate SAN. In this lab, the API cert includes `192.168.2.12` but not `k3s1.homelab.test`, so Vault Kubernetes auth uses `https://192.168.2.12:6443`.

Check basic access:

```bash
kubectl version
vault status
curl -sS "${VAULT_ADDR}/v1/sys/health"
```

If `vault status` fails with `x509: certificate signed by unknown authority`, either set:

```bash
export VAULT_CACERT="./vault-ca.crt"
```

or install the OPNsense CA into the workstation trust store.

## 2. Extract and verify the k3s API CA

Vault needs the k3s API CA so it can call Kubernetes TokenReview securely.

From the same workstation where `kubectl` works:

```bash
kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > k3s-ca.crt

head -n 1 k3s-ca.crt
openssl x509 -in k3s-ca.crt -noout -subject -issuer -dates
```

The first line must be:

```text
-----BEGIN CERTIFICATE-----
```

If you are on the k3s server and the kubeconfig does not contain `certificate-authority-data`, use:

```bash
sudo cp /var/lib/rancher/k3s/server/tls/server-ca.crt ./k3s-ca.crt
sudo chown "$USER:$USER" ./k3s-ca.crt
```

## 3. Create the namespace and service accounts

```bash
kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${APP_NAMESPACE}" create serviceaccount "${APP_SERVICE_ACCOUNT}" --dry-run=client -o yaml | kubectl apply -f -
```

Create the service account Vault uses for TokenReview:

```bash
kubectl -n kube-system create serviceaccount vault-auth --dry-run=client -o yaml | kubectl apply -f -

kubectl create clusterrolebinding vault-auth-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kube-system:vault-auth \
  --dry-run=client -o yaml | kubectl apply -f -
```

Create a long-lived token Secret for that reviewer account:

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-auth
type: kubernetes.io/service-account-token
YAML
```

Extract the token:

```bash
TOKEN_REVIEWER_JWT="$(kubectl -n kube-system get secret vault-auth-token \
  -o jsonpath='{.data.token}' | base64 -d)"
```

## 4. Enable and configure Vault Kubernetes auth

```bash
if ! vault auth list | grep -q "^${K8S_AUTH_PATH}/"; then
  vault auth enable -path="${K8S_AUTH_PATH}" kubernetes
fi

vault write "auth/${K8S_AUTH_PATH}/config" \
  token_reviewer_jwt="${TOKEN_REVIEWER_JWT}" \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert=@k3s-ca.crt \
  disable_iss_validation=true
```

Do not use `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` here unless the Vault CLI is actually running inside a Kubernetes pod. The `@file` value is read by the local Vault CLI, not by the Vault server.

## 5. Create a KV v1 mount, secret, and policy

```bash
if ! vault secrets list -detailed | grep -q "^${KV_MOUNT}/"; then
  vault secrets enable -path="${KV_MOUNT}" -version=1 kv
fi

vault kv put "${KV_MOUNT}/${KV_PATH}" \
  username="demo-user" \
  password="demo-password" \
  api_key="abc123"
```

For KV v1, the policy path is the real path. There is no `/data/` segment.

```bash
cat > "/tmp/${VAULT_POLICY}.hcl" <<EOF
path "${KV_MOUNT}/${KV_PATH}" {
  capabilities = ["read"]
}
EOF

vault policy write "${VAULT_POLICY}" "/tmp/${VAULT_POLICY}.hcl"
```

## 6. Create the Vault role

```bash
vault write "auth/${K8S_AUTH_PATH}/role/${VAULT_ROLE}" \
  bound_service_account_names="${APP_SERVICE_ACCOUNT}" \
  bound_service_account_namespaces="${APP_NAMESPACE}" \
  policies="${VAULT_POLICY}" \
  ttl="15m"
```

This binds the Vault policy to one Kubernetes identity: service account `demo-app` in namespace `demo`.

## 7. Install Vault Secrets Operator

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --version 1.4.0 \
  --namespace vault-secrets-operator \
  --create-namespace

kubectl -n vault-secrets-operator rollout status deploy/vault-secrets-operator-controller-manager
kubectl get crds | grep secrets.hashicorp.com
```

This guide uses VSO chart `1.4.0`, which is what was installed and tested in this lab.

## 8. Give VSO the Vault server CA

The operator needs to trust Vault's HTTPS certificate.

In this lab, `./vault-ca.crt` is the OPNsense CA exported from `System -> Trust -> Authorities`.

Verify it:

```bash
head -n 1 "${VAULT_CA_FILE}"
openssl x509 -in "${VAULT_CA_FILE}" -noout -subject -issuer -dates
```

Create the Kubernetes Secret that `VaultConnection` will reference:

```bash
kubectl -n "${APP_NAMESPACE}" create secret generic vault-ca \
  --from-file=ca.crt="${VAULT_CA_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## 9. Apply VSO resources and a demo deployment

Save this as `vault-vso-k3s-manifests.yaml`:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault
  namespace: demo
spec:
  address: https://vault.homelab.test:8200
  caCertSecretRef: vault-ca
  skipTLSVerify: false
  timeout: 10s
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: demo-app
  namespace: demo
spec:
  vaultConnectionRef: vault
  method: kubernetes
  mount: kubernetes-k3s
  kubernetes:
    role: demo-app
    serviceAccount: demo-app
    tokenExpirationSeconds: 600
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: demo-config
  namespace: demo
spec:
  type: kv-v1
  mount: kv
  path: apps/demo/config
  vaultAuthRef: demo-app
  refreshAfter: 60s
  destination:
    create: true
    name: demo-config
    type: Opaque
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      serviceAccountName: demo-app
      containers:
        - name: app
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              set -eu
              test -s /run/secrets/demo/username
              test -s /run/secrets/demo/password
              test -s /run/secrets/demo/api_key
              echo "demo secret files are present"
              sleep 3600
          volumeMounts:
            - name: demo-config
              mountPath: /run/secrets/demo
              readOnly: true
      volumes:
        - name: demo-config
          secret:
            secretName: demo-config
            defaultMode: 0400
```

Apply it:

```bash
kubectl apply -f vault-vso-k3s-manifests.yaml
```

## 10. Verify it

```bash
kubectl -n demo get vaultconnection,vaultauth,vaultstaticsecret
kubectl -n demo describe vaultstaticsecret demo-config
kubectl -n demo wait --for=condition=Ready vaultstaticsecret/demo-config --timeout=120s
kubectl -n demo get secret demo-config
kubectl -n demo rollout status deploy/demo-app
kubectl -n demo logs deploy/demo-app
```

Expected log:

```text
demo secret files are present
```

List the mounted files without printing secret values:

```bash
POD="$(kubectl -n demo get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')"
kubectl -n demo exec "$POD" -- ls -l /run/secrets/demo
```

## 11. Test a Vault secret update

```bash
vault kv put kv/apps/demo/config \
  username="demo-user" \
  password="changed-password" \
  api_key="changed-key"
```

Wait at least `refreshAfter`, then check the Kubernetes Secret metadata:

```bash
kubectl -n demo get secret demo-config -o yaml
```

If the app reads mounted Secret files while it is running, kubelet updates those files after its normal sync delay. If the app only reads secrets at startup, restart the deployment when the secret changes or add `rolloutRestartTargets` to the `VaultStaticSecret`.

## Troubleshooting

If Vault says the CA PEM contains no valid certificates:

```bash
openssl x509 -in k3s-ca.crt -noout -subject
```

The file must be decoded PEM. If it starts with base64 text instead of `-----BEGIN CERTIFICATE-----`, decode it first.

If VSO cannot reach Vault:

```bash
kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager
kubectl -n demo describe vaultconnection vault
```

Check DNS and HTTPS from inside the cluster. A test pod with curl is usually faster than guessing from the outside.

If Vault auth fails:

```bash
vault read "auth/${K8S_AUTH_PATH}/config"
vault read "auth/${K8S_AUTH_PATH}/role/${VAULT_ROLE}"
kubectl -n demo get serviceaccount demo-app
```

The Vault role must bind:

```text
bound_service_account_names=demo-app
bound_service_account_namespaces=demo
```

If `VaultStaticSecret` is not ready:

```bash
kubectl -n demo describe vaultstaticsecret demo-config
kubectl -n demo get events --sort-by='.lastTimestamp'
```

For KV v1:

```yaml
type: kv-v1
mount: kv
path: apps/demo/config
```

For KV v2, the VSO resource would use `type: kv-v2` with the same logical path, but the Vault policy would use the `/data/` path. This guide is KV v1, so do not add `/data/`.

## Cleanup

```bash
kubectl delete namespace demo
helm uninstall vault-secrets-operator -n vault-secrets-operator
kubectl delete namespace vault-secrets-operator
vault delete "auth/${K8S_AUTH_PATH}/role/${VAULT_ROLE}"
vault policy delete "${VAULT_POLICY}"
```

Only disable the auth mount or delete the KV mount if nothing else uses them:

```bash
vault auth disable "${K8S_AUTH_PATH}"
vault secrets disable "${KV_MOUNT}"
```

## Gotchas from this lab

### 1. MTU 9000 broke Vault TLS from k3s

The first big problem looked like this:

```text
net/http: TLS handshake timeout
```

Earlier logs also showed:

```text
connect: no route to host
```

The misleading part was that plain HTTP could reach Vault and got this response:

```text
Client sent an HTTP request to an HTTPS server.
```

but HTTPS stalled during the TLS handshake.

The k3s nodes were set to jumbo frames:

```text
eth0 mtu 9000
flannel.1 mtu 8950
cni0 mtu 8950
```

but the whole path to Vault did not support jumbo frames. A normal 1500-byte DF ping worked:

```bash
ping -M do -s 1472 192.168.2.15
```

but a jumbo DF ping failed:

```bash
ping -M do -s 8972 192.168.2.15
```

The fix was to stop using jumbo frames for this path. Set the k3s nodes, Vault server, Proxmox bridges, OPNsense interfaces, and switch ports back to MTU 1500 unless every hop is confirmed to support 9000.

Temporary Linux test fix:

```bash
sudo ip link set dev eth0 mtu 1500
```

After MTU was fixed, `VaultConnection` became healthy.

### 2. `skipTLSVerify` did not help

`skipTLSVerify: true` only disables certificate verification. It does not fix routing, MTU, firewall, NAT, or packet loss. If the TLS handshake cannot finish, `skipTLSVerify` still fails.

### 3. k3s API certificate SAN mismatch caused Vault Kubernetes auth 403

After the network path was fixed, `VaultConnection` became healthy. `VaultStaticSecret` still failed:

```text
PUT /v1/auth/kubernetes-k3s/login
403 permission denied
```

Kubernetes TokenReview worked. The ServiceAccount token looked right:

```text
sub: system:serviceaccount:demo:demo-app
iss: https://kubernetes.default.svc.cluster.local
aud:
  - https://kubernetes.default.svc.cluster.local
  - k3s
```

The problem was the Kubernetes API address in Vault:

```text
kubernetes_host="https://k3s1.homelab.test:6443"
```

The k3s API certificate did not include `k3s1.homelab.test` in its SANs. It did include:

```text
DNS:k3s-server-01
IP Address:192.168.2.12
DNS:kubernetes.default.svc.cluster.local
```

This fixed it:

```bash
vault write auth/kubernetes-k3s/config \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT" \
  kubernetes_host="https://192.168.2.12:6443" \
  kubernetes_ca_cert=@k3s-ca.crt \
  disable_iss_validation=true
```

Using the IP worked because `192.168.2.12` was in the k3s API certificate SAN.

Longer term, either add `k3s1.homelab.test` to the k3s API certificate SANs or put the API behind a stable load balancer name that is also in the cert.

### 4. Vault CLI on k3s needed the Vault CA

After the MTU fix, `vault status` from k3s still failed with:

```text
x509: certificate signed by unknown authority
```

That was separate from VSO. The CLI just did not trust the CA yet:

```bash
export VAULT_ADDR="https://vault.homelab.test:8200"
export VAULT_CACERT="./vault-ca.crt"
vault status
```

You can also install the OPNsense CA into the node's system trust store.

### 5. The Vault CLI token may not have permission to read auth config

Reading these paths requires a privileged Vault token:

```bash
vault read auth/kubernetes-k3s/config
vault read auth/kubernetes-k3s/role/demo-app
```

Without that permission, Vault returns:

```text
403 permission denied
```

That 403 is not the same as a Kubernetes auth login 403. This one means the human/debugging token cannot read auth config. A login 403 means Vault rejected the ServiceAccount token or role binding.

### 6. Root tokens do not belong in logs or chats

A root token was used to repair the Kubernetes auth method. If a root token is pasted into chat, terminal scrollback, notes, or logs, treat it as exposed.

After emergency use, revoke or rotate it:

```bash
vault token revoke <root-token>
```

For normal work, use a narrower admin policy that can manage this auth method and the related policies without being a root token.

### 7. VSO writes Kubernetes Secrets

VSO is useful, but it creates Kubernetes Secret objects. That means secret material can be exposed through:

```text
Kubernetes API access
etcd
cluster backups
controller caches
kubectl access by authorized users
```

If that is not acceptable for an app, use Vault CSI Provider or Vault Agent Injector instead. VSO is still a good fit for apps and Helm charts that already expect ordinary Kubernetes Secrets.

### 8. KV v1 and KV v2 paths are different

This lab uses KV v1:

```text
VaultStaticSecret type: kv-v1
mount: kv
path: apps/demo/config
policy path: kv/apps/demo/config
```

KV v2 is different. Its Vault policy path uses `/data/`:

```text
secret/data/apps/demo/config
```

Do not mix the two path styles.

## Where this ended up

After the fixes:

```text
VaultConnection demo/vault:          Healthy=True, Ready=True
VaultAuth demo/demo-app:             Healthy=True, Ready=True
VaultStaticSecret demo/demo-config:  Synced=True, Healthy=True, Ready=True
Kubernetes Secret demo-config:       created
Deployment demo-app:                 1/1 available
```

The working Vault Kubernetes auth config uses:

```text
kubernetes_host="https://192.168.2.12:6443"
issuer="https://kubernetes.default.svc.cluster.local"
token_reviewer_jwt set
k3s CA PEM set
```

The working Vault role binds:

```text
bound_service_account_names="demo-app"
bound_service_account_namespaces="demo"
policies="k3s-demo-app"
```

## How to debug this next time

Work from the bottom up:

1. Can a k3s node reach Vault over HTTPS?

   ```bash
   curl -vk https://vault.homelab.test:8200/v1/sys/health
   ```

2. Can a pod reach Vault over HTTPS?

   Run a temporary curl pod and test the same URL.

3. Is `VaultConnection` healthy?

   ```bash
   kubectl -n demo get vaultconnection vault
   ```

4. Does Kubernetes TokenReview work?

   Use `kubectl create token` and the Kubernetes TokenReview API.

5. Does Vault Kubernetes auth login work manually?

   ```bash
   vault write auth/kubernetes-k3s/login role=demo-app jwt="$SA_JWT"
   ```

6. Is `VaultStaticSecret` synced?

   ```bash
   kubectl -n demo describe vaultstaticsecret demo-config
   ```

7. Did VSO create the Kubernetes Secret?

   ```bash
   kubectl -n demo get secret demo-config
   ```

8. Can the app read the Secret?

   Check pod status and logs without printing real secret values.
