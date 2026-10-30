#!/usr/bin/env bash
set -euo pipefail

# Write test. It changes only the isolated demo path shared-kv/platform/eso,
# waits for ESO's periodic refresh, and compares the result without printing it.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export VAULT_ADDR="${VAULT_ADDR:-https://vault1.homelab.test:8200}"
export VAULT_CACERT="${VAULT_CACERT:-${SCRIPT_DIR}/vault-ca.crt}"

NAMESPACE="${APP_NAMESPACE:-eso-demo}"
TARGET_SECRET="${TARGET_SECRET:-combined-demo-config}"
SECONDARY_KV_MOUNT="${SECONDARY_KV_MOUNT:-shared-kv}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"

if [[ -n "${KUBECTL_CONTEXT}" ]]; then
  KUBECTL=(kubectl --context "${KUBECTL_CONTEXT}")
else
  KUBECTL=(kubectl)
fi

for command_name in kubectl vault base64; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

vault status >/dev/null
vault token lookup >/dev/null

PROBE="refresh-$(date +%s)"
echo "Updating the isolated Vault refresh probe..."
vault kv put "${SECONDARY_KV_MOUNT}/platform/eso" \
  region="homelab" \
  support_contact="platform-team" \
  source_order="shared-kv" \
  refresh_probe="${PROBE}" >/dev/null

echo "Waiting up to 90 seconds for ESO's 30-second refresh interval..."
for _ in {1..45}; do
  SYNCED_PROBE="$("${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${TARGET_SECRET}" \
    -o jsonpath='{.data.refresh_probe}' 2>/dev/null | base64 -d || true)"
  if [[ "${SYNCED_PROBE}" == "${PROBE}" ]]; then
    echo "PASS: the updated Vault value reached the existing Kubernetes Secret."
    exit 0
  fi
  sleep 2
done

echo "FAIL: the refresh probe did not synchronize within 90 seconds." >&2
"${KUBECTL[@]}" -n "${NAMESPACE}" describe externalsecret combined-demo-config >&2
exit 1
