#!/usr/bin/env bash
set -euo pipefail

# Reuses External Secrets Operator when it is already installed (or installs it
# when absent), configures Vault Kubernetes auth for the current kubectl
# context, creates two KV v1 demo mounts/paths, and deploys the example in
# external-secrets-manifests.yaml.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export VAULT_ADDR="${VAULT_ADDR:-https://vault1.homelab.test:8200}"
export VAULT_CACERT="${VAULT_CACERT:-${SCRIPT_DIR}/vault-ca.crt}"

K8S_HOST="${K8S_HOST:-https://k3s1.homelab.test:6443}"
K8S_AUTH_PATH="${K8S_AUTH_PATH:-kubernetes-k3s}"
APP_NAMESPACE="${APP_NAMESPACE:-eso-demo}"
APP_SERVICE_ACCOUNT="${APP_SERVICE_ACCOUNT:-eso-vault-auth}"
VAULT_ROLE="${VAULT_ROLE:-eso-demo}"
VAULT_POLICY="${VAULT_POLICY:-eso-demo}"
PRIMARY_KV_MOUNT="${PRIMARY_KV_MOUNT:-kv}"
SECONDARY_KV_MOUNT="${SECONDARY_KV_MOUNT:-shared-kv}"
ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.14.0}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"

if [[ -n "${KUBECTL_CONTEXT}" ]]; then
  KUBECTL=(kubectl --context "${KUBECTL_CONTEXT}")
  HELM_CONTEXT_ARGS=(--kube-context "${KUBECTL_CONTEXT}")
else
  KUBECTL=(kubectl)
  HELM_CONTEXT_ARGS=()
fi

for command_name in kubectl helm vault base64 openssl jq; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

if [[ ! -s "${VAULT_CACERT}" ]]; then
  echo "Vault CA file not found or empty: ${VAULT_CACERT}" >&2
  exit 1
fi

echo "Kubernetes context: $("${KUBECTL[@]}" config current-context)"
echo "Vault address:      ${VAULT_ADDR}"
echo "Vault auth mount:   ${K8S_AUTH_PATH}"
echo "Kubernetes API:     ${K8S_HOST}"

"${KUBECTL[@]}" version >/dev/null
vault status >/dev/null
vault token lookup >/dev/null
openssl x509 -in "${VAULT_CACERT}" -noout -subject -issuer

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Extracting the Kubernetes API CA from the selected context..."
"${KUBECTL[@]}" config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "${WORK_DIR}/kubernetes-ca.crt"
openssl x509 -in "${WORK_DIR}/kubernetes-ca.crt" -noout -subject -issuer

echo "Creating the namespace and Vault authentication service accounts..."
"${KUBECTL[@]}" create namespace "${APP_NAMESPACE}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" -n "${APP_NAMESPACE}" create serviceaccount "${APP_SERVICE_ACCOUNT}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" -n kube-system create serviceaccount vault-auth-eso \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" create clusterrolebinding vault-auth-eso-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kube-system:vault-auth-eso \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

"${KUBECTL[@]}" apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: vault-auth-eso-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-auth-eso
type: kubernetes.io/service-account-token
YAML

echo "Waiting for Kubernetes to populate the TokenReview JWT..."
TOKEN_REVIEWER_JWT=""
for _ in {1..30}; do
  TOKEN_REVIEWER_JWT="$("${KUBECTL[@]}" -n kube-system get secret vault-auth-eso-token \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [[ -n "${TOKEN_REVIEWER_JWT}" ]] && break
  sleep 1
done
if [[ -z "${TOKEN_REVIEWER_JWT}" ]]; then
  echo "The TokenReview service-account token was not populated." >&2
  exit 1
fi

echo "Configuring Vault Kubernetes auth..."
if ! vault auth list -format=json | jq -e --arg path "${K8S_AUTH_PATH}/" 'has($path)' >/dev/null; then
  vault auth enable -path="${K8S_AUTH_PATH}" kubernetes
fi
vault write "auth/${K8S_AUTH_PATH}/config" \
  token_reviewer_jwt="${TOKEN_REVIEWER_JWT}" \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert="@${WORK_DIR}/kubernetes-ca.crt" \
  disable_iss_validation=true >/dev/null

ensure_kv_v1_mount() {
  local mount_name="$1"
  local mount_key="${mount_name}/"
  local mount_type
  local mount_version

  if ! vault secrets list -detailed -format=json \
    | jq -e --arg mount "${mount_key}" 'has($mount)' >/dev/null; then
    echo "Enabling KV v1 at ${mount_name}/..."
    vault secrets enable -path="${mount_name}" -version=1 kv >/dev/null
    return
  fi

  mount_type="$(vault secrets list -detailed -format=json \
    | jq -r --arg mount "${mount_key}" '.[$mount].type')"
  mount_version="$(vault secrets list -detailed -format=json \
    | jq -r --arg mount "${mount_key}" '.[$mount].options.version // "1"')"

  if [[ "${mount_type}" != "kv" || "${mount_version}" != "1" ]]; then
    echo "${mount_name}/ exists but is not KV v1; refusing to modify it." >&2
    exit 1
  fi
}

ensure_kv_v1_mount "${PRIMARY_KV_MOUNT}"
ensure_kv_v1_mount "${SECONDARY_KV_MOUNT}"

echo "Writing harmless demo values to three Vault paths..."
vault kv put "${PRIMARY_KV_MOUNT}/apps/eso/base" \
  app_username="demo-user" \
  log_level="info" \
  source_order="base" >/dev/null

vault kv put "${PRIMARY_KV_MOUNT}/apps/eso/database" \
  database_host="database.internal" \
  database_port="5432" \
  database_username="demo-db-user" \
  database_password="demo-db-password" \
  source_order="database" >/dev/null

vault kv put "${SECONDARY_KV_MOUNT}/platform/eso" \
  region="homelab" \
  support_contact="platform-team" \
  source_order="shared-kv" \
  refresh_probe="initial" >/dev/null

cat > "${WORK_DIR}/policy.hcl" <<EOF
path "${PRIMARY_KV_MOUNT}/apps/eso/base" {
  capabilities = ["read"]
}

path "${PRIMARY_KV_MOUNT}/apps/eso/database" {
  capabilities = ["read"]
}

path "${SECONDARY_KV_MOUNT}/platform/eso" {
  capabilities = ["read"]
}
EOF

vault policy write "${VAULT_POLICY}" "${WORK_DIR}/policy.hcl" >/dev/null
vault write "auth/${K8S_AUTH_PATH}/role/${VAULT_ROLE}" \
  bound_service_account_names="${APP_SERVICE_ACCOUNT}" \
  bound_service_account_namespaces="${APP_NAMESPACE}" \
  audience="vault" \
  policies="${VAULT_POLICY}" \
  ttl="15m" >/dev/null

echo "Checking for an existing External Secrets Operator installation..."
ESO_RELEASE="$(helm "${HELM_CONTEXT_ARGS[@]}" list -A -o json \
  | jq -r '[.[] | select(.name == "external-secrets" and .status == "deployed")][0] // empty')"

if [[ -n "${ESO_RELEASE}" ]]; then
  ESO_NAMESPACE="$(jq -r '.namespace' <<<"${ESO_RELEASE}")"
  ESO_CHART="$(jq -r '.chart' <<<"${ESO_RELEASE}")"
  echo "Reusing installed ESO release ${ESO_CHART} in namespace ${ESO_NAMESPACE}."
else
  echo "ESO is absent; installing chart ${ESO_CHART_VERSION}..."
  helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null
  helm repo update external-secrets >/dev/null
  helm "${HELM_CONTEXT_ARGS[@]}" upgrade --install external-secrets \
    external-secrets/external-secrets \
    --version "${ESO_CHART_VERSION}" \
    --namespace external-secrets \
    --create-namespace \
    --set installCRDs=true \
    --wait \
    --timeout 5m
fi

echo "Creating the Vault CA Secret without printing its contents..."
"${KUBECTL[@]}" -n "${APP_NAMESPACE}" create secret generic vault-ca \
  --from-file=ca.crt="${VAULT_CACERT}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

if [[ "${APP_NAMESPACE}" != "eso-demo" || "${APP_SERVICE_ACCOUNT}" != "eso-vault-auth" \
   || "${K8S_AUTH_PATH}" != "kubernetes-k3s" || "${VAULT_ROLE}" != "eso-demo" \
   || "${PRIMARY_KV_MOUNT}" != "kv" || "${SECONDARY_KV_MOUNT}" != "shared-kv" \
   || "${VAULT_ADDR}" != "https://vault1.homelab.test:8200" ]]; then
  echo "The manifest contains readable demo defaults, but one or more setup variables were overridden." >&2
  echo "Update external-secrets-manifests.yaml to match those overrides before applying it." >&2
  exit 1
fi

echo "Applying the SecretStores, ExternalSecret, and demo Deployment..."
"${KUBECTL[@]}" apply -f "${SCRIPT_DIR}/external-secrets-manifests.yaml"

"${KUBECTL[@]}" -n "${APP_NAMESPACE}" wait \
  --for=condition=Ready secretstore/vault-kv-v1 --timeout=120s
"${KUBECTL[@]}" -n "${APP_NAMESPACE}" wait \
  --for=condition=Ready secretstore/vault-shared-kv-v1 --timeout=120s
"${KUBECTL[@]}" -n "${APP_NAMESPACE}" wait \
  --for=condition=Ready externalsecret/combined-demo-config --timeout=120s
"${KUBECTL[@]}" -n "${APP_NAMESPACE}" rollout status deployment/eso-demo-app --timeout=120s

echo "Setup complete. Run ./external-secrets-smoke-test.sh next."
