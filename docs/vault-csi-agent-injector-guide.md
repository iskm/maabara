# Vault CSI Provider and Vault Agent Injector on k3s

This guide shows how the install changes if you do not want Vault Secrets Operator as the delivery method.

Same lab assumptions:

| Item | Value |
|---|---|
| Vault | `https://vault.homelab.test:8200` |
| k3s API used by Vault auth | `https://192.168.2.12:6443` |
| Vault auth mount | `kubernetes-k3s` |
| KV engine | KV v1 mounted at `kv` |
| Demo Vault path | `kv/apps/demo/config` |
| Vault CA file on workstation | `./vault-ca.crt` |

Where `./vault-ca.crt` comes from:

1. In OPNsense, open `System -> Trust -> Authorities`.
2. Export the CA that issued the Vault server certificate for `vault.homelab.test`.
3. Save that PEM file as `./vault-ca.crt` on the workstation where you run `kubectl` and `helm`.

Do not use the Vault server certificate here. Use the CA certificate that signed it.

References:

- [HashiCorp Vault CSI Provider](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/csi)
- [HashiCorp Vault Agent Injector](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector)
- [HashiCorp Vault Helm chart configuration](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm/configuration)
- [Secrets Store CSI Driver installation](https://secrets-store-csi-driver.sigs.k8s.io/getting-started/installation)

## How CSI and Agent Injector differ

Both use Vault Kubernetes auth. Both should use one Kubernetes ServiceAccount per app and one Vault role per app.

The difference is how the secret reaches the pod.

| Option | What it does | Kubernetes Secret created? | Best fit |
|---|---|---:|---|
| Vault CSI Provider | Mounts Vault secrets as files through a CSI volume | No, unless you enable sync | Apps that can read files directly |
| Vault Agent Injector | Adds Vault Agent init/sidecar containers that write rendered files | No | Apps needing templates, renewal, or rendered config files |
| Vault Secrets Operator | Syncs Vault data into Kubernetes Secret objects | Yes | Apps or Helm charts that expect Kubernetes Secrets |

For simple KV-as-files, CSI is clean. For templated config files or dynamic secrets that need renewal, Agent Injector is more flexible.

## Shared setup

The Kubernetes auth method and Vault role setup are the same for CSI and Injector.

### 1. Set variables

```bash
export VAULT_ADDR="https://vault.homelab.test:8200"
export VAULT_CACERT="./vault-ca.crt"
export K8S_HOST="https://192.168.2.12:6443"
export K8S_AUTH_PATH="kubernetes-k3s"
export KV_MOUNT="kv"
export KV_PATH="apps/demo/config"
```

Use `https://192.168.2.12:6443` because that IP is present in the k3s API certificate SAN. In this lab, `k3s1.homelab.test` resolves to the right host but is not in the certificate SAN, which caused Vault Kubernetes auth to fail with `403 permission denied`.

### 2. Verify the Vault CA file

`./vault-ca.crt` should be the OPNsense CA that issued the Vault certificate.

```bash
head -n 1 ./vault-ca.crt
openssl x509 -in ./vault-ca.crt -noout -subject -issuer -dates
curl --cacert ./vault-ca.crt https://vault.homelab.test:8200/v1/sys/health
```

The first line should be:

```text
-----BEGIN CERTIFICATE-----
```

### 3. Extract the k3s API CA

Vault needs this CA to call the Kubernetes TokenReview API.

```bash
kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > k3s-ca.crt

openssl x509 -in k3s-ca.crt -noout -subject -issuer -dates
```

If you are running this directly on the k3s server and your kubeconfig does not have `certificate-authority-data`, copy it from:

```bash
sudo cp /var/lib/rancher/k3s/server/tls/server-ca.crt ./k3s-ca.crt
sudo chown "$USER:$USER" ./k3s-ca.crt
```

### 4. Create the TokenReview service account

Vault uses this service account token to ask Kubernetes whether app ServiceAccount tokens are valid.

```bash
kubectl -n kube-system create serviceaccount vault-auth --dry-run=client -o yaml | kubectl apply -f -

kubectl create clusterrolebinding vault-auth-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kube-system:vault-auth \
  --dry-run=client -o yaml | kubectl apply -f -
```

Use a projected token for setup:

```bash
TOKEN_REVIEWER_JWT="$(kubectl -n kube-system create token vault-auth --duration=24h)"
```

If you need a token that survives restarts without rerunning setup, create a service-account-token Secret instead:

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

TOKEN_REVIEWER_JWT="$(kubectl -n kube-system get secret vault-auth-token \
  -o jsonpath='{.data.token}' | base64 -d)"
```

### 5. Configure Vault Kubernetes auth

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

### 6. Create the demo KV secret and policy

```bash
if ! vault secrets list -detailed | grep -q "^${KV_MOUNT}/"; then
  vault secrets enable -path="${KV_MOUNT}" -version=1 kv
fi

vault kv put "${KV_MOUNT}/${KV_PATH}" \
  username="demo-user" \
  password="demo-password" \
  api_key="abc123"
```

Create one policy for CSI and one for Injector. They read the same path, but keeping roles separate makes troubleshooting easier.

```bash
vault policy write k3s-csi-demo - <<EOF
path "${KV_MOUNT}/${KV_PATH}" {
  capabilities = ["read"]
}
EOF

vault policy write k3s-injector-demo - <<EOF
path "${KV_MOUNT}/${KV_PATH}" {
  capabilities = ["read"]
}
EOF
```

## Option A: Vault CSI Provider

CSI mounts Vault secret values as files. It does not create a Kubernetes Secret unless you explicitly enable sync.

The runtime chain is:

```text
Pod ServiceAccount -> Vault Kubernetes auth -> SecretProviderClass -> CSI volume -> files in pod
```

### 1. Create namespace, ServiceAccount, and Vault role

```bash
kubectl create namespace csi-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n csi-demo create serviceaccount csi-demo-app --dry-run=client -o yaml | kubectl apply -f -

vault write "auth/${K8S_AUTH_PATH}/role/csi-demo-app" \
  bound_service_account_names="csi-demo-app" \
  bound_service_account_namespaces="csi-demo" \
  policies="k3s-csi-demo" \
  ttl="15m"
```

### 2. Install the Secrets Store CSI Driver

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update

helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=false
```

`syncSecret.enabled=false` keeps this from creating Kubernetes Secret objects.

Verify:

```bash
kubectl -n kube-system get pods -l app=secrets-store-csi-driver
kubectl get crd | grep secretprovider
```

### 3. Install the Vault CSI provider

Create a namespace and put the Vault CA there:

```bash
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

kubectl -n vault create secret generic vault-ca \
  --from-file=ca.crt=./vault-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
```

Again, `./vault-ca.crt` is the OPNsense CA exported from `System -> Trust -> Authorities`.

Create `vault-csi-values.yaml`:

```yaml
global:
  externalVaultAddr: "https://vault.homelab.test:8200"

server:
  enabled: false

injector:
  enabled: false

csi:
  enabled: true
  volumes:
    - name: vault-ca
      secret:
        secretName: vault-ca
  volumeMounts:
    - name: vault-ca
      mountPath: /vault/tls
      readOnly: true
  agent:
    extraArgs:
      - "-vault-tls-ca-cert=/vault/tls/ca.crt"
```

Install:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault-csi hashicorp/vault \
  --namespace vault \
  --create-namespace \
  -f vault-csi-values.yaml
```

Verify:

```bash
kubectl -n vault get daemonset,pods
```

### 4. Create a SecretProviderClass

```bash
kubectl apply -f - <<'YAML'
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: csi-demo-vault-kv
  namespace: csi-demo
spec:
  provider: vault
  parameters:
    roleName: "csi-demo-app"
    vaultKubernetesMountPath: "kubernetes-k3s"
    vaultAddress: "https://vault.homelab.test:8200"
    vaultCACertPath: "/vault/tls/ca.crt"
    objects: |
      - objectName: "username"
        secretPath: "kv/apps/demo/config"
        secretKey: "username"
        filePermission: 0400
      - objectName: "password"
        secretPath: "kv/apps/demo/config"
        secretKey: "password"
        filePermission: 0400
      - objectName: "api_key"
        secretPath: "kv/apps/demo/config"
        secretKey: "api_key"
        filePermission: 0400
YAML
```

This is KV v1, so the path is `kv/apps/demo/config`. Do not use `kv/data/...`.

### 5. Deploy a test app

```bash
kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csi-demo-app
  namespace: csi-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: csi-demo-app
  template:
    metadata:
      labels:
        app: csi-demo-app
    spec:
      serviceAccountName: csi-demo-app
      containers:
        - name: app
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              set -eu
              test -s /mnt/secrets-store/username
              test -s /mnt/secrets-store/password
              test -s /mnt/secrets-store/api_key
              echo "CSI secret files are present"
              sleep 3600
          volumeMounts:
            - name: vault-secrets
              mountPath: /mnt/secrets-store
              readOnly: true
      volumes:
        - name: vault-secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: csi-demo-vault-kv
YAML
```

Verify without printing secret values:

```bash
kubectl -n csi-demo rollout status deploy/csi-demo-app
kubectl -n csi-demo logs deploy/csi-demo-app
POD="$(kubectl -n csi-demo get pod -l app=csi-demo-app -o jsonpath='{.items[0].metadata.name}')"
kubectl -n csi-demo exec "$POD" -- ls -l /mnt/secrets-store
```

Expected log:

```text
CSI secret files are present
```

## Option B: Vault Agent Injector

Agent Injector mutates pods that have Vault annotations. It adds Vault Agent init/sidecar containers and writes secrets to a shared in-memory volume, usually under `/vault/secrets`.

The runtime chain is:

```text
Pod annotations -> Vault Agent injected -> Kubernetes auth -> Vault -> rendered files in /vault/secrets
```

### 1. Create namespace, ServiceAccount, and Vault role

```bash
kubectl create namespace injector-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n injector-demo create serviceaccount injector-demo-app --dry-run=client -o yaml | kubectl apply -f -

vault write "auth/${K8S_AUTH_PATH}/role/injector-demo-app" \
  bound_service_account_names="injector-demo-app" \
  bound_service_account_namespaces="injector-demo" \
  policies="k3s-injector-demo" \
  ttl="15m"
```

### 2. Install only the injector

Create a namespace for the injector chart:

```bash
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
```

Create `vault-injector-values.yaml`:

```yaml
global:
  externalVaultAddr: "https://vault.homelab.test:8200"

server:
  enabled: false

csi:
  enabled: false

injector:
  enabled: true
  replicas: 1
```

Install:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault-injector hashicorp/vault \
  --namespace vault \
  --create-namespace \
  -f vault-injector-values.yaml
```

Verify:

```bash
kubectl -n vault get deploy,pods
kubectl get mutatingwebhookconfigurations | grep vault
```

Now put the Vault CA in the app namespace. The injected Vault Agent containers will mount this Secret when the pod asks for it with `vault.hashicorp.com/tls-secret`.

```bash
kubectl -n injector-demo create secret generic vault-ca \
  --from-file=ca.crt=./vault-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3. Deploy a test app

```bash
kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: injector-demo-app
  namespace: injector-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: injector-demo-app
  template:
    metadata:
      labels:
        app: injector-demo-app
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/auth-path: "auth/kubernetes-k3s"
        vault.hashicorp.com/role: "injector-demo-app"
        vault.hashicorp.com/tls-secret: "vault-ca"
        vault.hashicorp.com/ca-cert: "/vault/tls/ca.crt"
        vault.hashicorp.com/agent-inject-secret-config.env: "kv/apps/demo/config"
        vault.hashicorp.com/agent-inject-template-config.env: |
          {{- with secret "kv/apps/demo/config" -}}
          USERNAME={{ .Data.username }}
          PASSWORD={{ .Data.password }}
          API_KEY={{ .Data.api_key }}
          {{- end }}
    spec:
      serviceAccountName: injector-demo-app
      containers:
        - name: app
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              set -eu
              test -s /vault/secrets/config.env
              echo "Injector secret file is present"
              sleep 3600
YAML
```

The annotations go under `spec.template.metadata.annotations`, not on the Deployment's top-level metadata.

Verify:

```bash
kubectl -n injector-demo rollout status deploy/injector-demo-app
kubectl -n injector-demo logs deploy/injector-demo-app
kubectl -n injector-demo get pod -l app=injector-demo-app -o jsonpath='{.items[0].spec.containers[*].name}'
```

You should see the app container plus Vault Agent containers.

Expected log:

```text
Injector secret file is present
```

## What changes compared to VSO

### CSI

You add:

```text
Secrets Store CSI Driver
Vault CSI Provider
SecretProviderClass
CSI volume in the pod
```

You do not create:

```text
VaultConnection
VaultAuth
VaultStaticSecret
Kubernetes Secret destination
```

### Agent Injector

You add:

```text
Vault Agent Injector webhook
pod annotations
injected Vault Agent init/sidecar containers
rendered files under /vault/secrets
```

You do not create:

```text
VaultConnection
VaultAuth
VaultStaticSecret
Kubernetes Secret destination
SecretProviderClass
```

## Cleanup

CSI:

```bash
kubectl delete namespace csi-demo
helm uninstall vault-csi -n vault
helm uninstall csi-secrets-store -n kube-system
vault delete auth/kubernetes-k3s/role/csi-demo-app
vault policy delete k3s-csi-demo
```

Agent Injector:

```bash
kubectl delete namespace injector-demo
helm uninstall vault-injector -n vault
vault delete auth/kubernetes-k3s/role/injector-demo-app
vault policy delete k3s-injector-demo
```

Only delete the shared `vault` namespace if nothing else is using it:

```bash
kubectl delete namespace vault
```

## Notes from this lab

- Keep MTU at `1500` unless every hop supports jumbo frames. The earlier MTU `9000` setting caused TLS handshakes to hang from k3s to Vault.
- Use a Kubernetes API host or IP that is present in the k3s API cert SAN. Here that is `https://192.168.2.12:6443`, not `https://k3s1.homelab.test:6443`.
- For KV v1, use `kv/apps/demo/config`. Do not add `/data/`.
- For KV v2, policies use `/data/`; this guide is not using KV v2.
- Do not print real secret values in logs while testing.
