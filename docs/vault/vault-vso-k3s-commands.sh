#!/usr/bin/env bash
set -euo pipefail

# Run this from a workstation that has kubectl, helm, and vault configured.
# It assumes k3s API is reachable at https://k3s1.homelab.test:6443 and Vault
# is reachable at https://vault.homelab.test:8200.

export VAULT_ADDR="${VAULT_ADDR:-https://vault.homelab.test:8200}"
# Use a Kubernetes API name/IP that is present in the k3s API certificate SAN.
# In this lab, k3s1.homelab.test resolves correctly but is not in the cert SAN;
# 192.168.2.12 is in the cert SAN.
export K8S_HOST="${K8S_HOST:-https://192.168.2.12:6443}"
export K8S_AUTH_PATH="${K8S_AUTH_PATH:-kubernetes-k3s}"
export APP_NAMESPACE="${APP_NAMESPACE:-demo}"
export APP_SERVICE_ACCOUNT="${APP_SERVICE_ACCOUNT:-demo-app}"
export VAULT_ROLE="${VAULT_ROLE:-demo-app}"
export VAULT_POLICY="${VAULT_POLICY:-k3s-demo-app}"
export KV_MOUNT="${KV_MOUNT:-kv}"
export KV_PATH="${KV_PATH:-apps/demo/config}"
export VAULT_CA_FILE="${VAULT_CA_FILE:-./vault-ca.crt}"

command -v kubectl >/dev/null
command -v helm >/dev/null
command -v vault >/dev/null
command -v base64 >/dev/null
command -v openssl >/dev/null

echo "Checking access to Kubernetes and Vault..."
kubectl version
vault status

echo "Extracting the k3s API CA certificate..."
kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > k3s-ca.crt
openssl x509 -in k3s-ca.crt -noout -subject -issuer

echo "Creating the application namespace and service account..."
kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${APP_NAMESPACE}" create serviceaccount "${APP_SERVICE_ACCOUNT}" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating the Vault TokenReview service account..."
kubectl -n kube-system create serviceaccount vault-auth --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding vault-auth-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kube-system:vault-auth \
  --dry-run=client -o yaml | kubectl apply -f -

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

echo "Enabling and configuring Vault Kubernetes auth..."
if ! vault auth list | grep -q "^${K8S_AUTH_PATH}/"; then
  vault auth enable -path="${K8S_AUTH_PATH}" kubernetes
fi

vault write "auth/${K8S_AUTH_PATH}/config" \
  token_reviewer_jwt="${TOKEN_REVIEWER_JWT}" \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert=@k3s-ca.crt \
  disable_iss_validation=true

echo "Creating a KV v1 mount and demo secret in Vault..."
if ! vault secrets list -detailed | grep -q "^${KV_MOUNT}/"; then
  vault secrets enable -path="${KV_MOUNT}" -version=1 kv
fi

vault kv put "${KV_MOUNT}/${KV_PATH}" \
  username="demo-user" \
  password="demo-password" \
  api_key="abc123"

cat > "/tmp/${VAULT_POLICY}.hcl" <<EOF
path "${KV_MOUNT}/${KV_PATH}" {
  capabilities = ["read"]
}
EOF

vault policy write "${VAULT_POLICY}" "/tmp/${VAULT_POLICY}.hcl"

vault write "auth/${K8S_AUTH_PATH}/role/${VAULT_ROLE}" \
  bound_service_account_names="${APP_SERVICE_ACCOUNT}" \
  bound_service_account_namespaces="${APP_NAMESPACE}" \
  policies="${VAULT_POLICY}" \
  ttl="15m"

echo "Installing Vault Secrets Operator..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --version 1.4.0 \
  --namespace vault-secrets-operator \
  --create-namespace

kubectl -n vault-secrets-operator rollout status deploy/vault-secrets-operator-controller-manager

echo "Creating the Vault CA secret for VSO..."
if [ ! -s "${VAULT_CA_FILE}" ]; then
  echo "Missing ${VAULT_CA_FILE}. Put the CA that issued https://vault.homelab.test there, then rerun this section." >&2
  exit 1
fi
openssl x509 -in "${VAULT_CA_FILE}" -noout -subject -issuer
kubectl -n "${APP_NAMESPACE}" create secret generic vault-ca \
  --from-file=ca.crt="${VAULT_CA_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Applying VSO resources and demo deployment..."
kubectl apply -f vault-vso-k3s-manifests.yaml

echo "Waiting for VSO to create the Kubernetes Secret..."
kubectl -n "${APP_NAMESPACE}" wait --for=condition=Ready vaultstaticsecret/demo-config --timeout=120s
kubectl -n "${APP_NAMESPACE}" get secret demo-config

echo "Waiting for demo app rollout..."
kubectl -n "${APP_NAMESPACE}" rollout status deploy/demo-app
kubectl -n "${APP_NAMESPACE}" logs deploy/demo-app
