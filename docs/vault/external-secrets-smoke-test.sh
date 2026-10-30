#!/usr/bin/env bash
set -euo pipefail

# Read-only test. It verifies readiness, the exact set of merged keys, selected
# expected demo values, and the consuming pod. It never prints secret values.

NAMESPACE="${APP_NAMESPACE:-eso-demo}"
TARGET_SECRET="${TARGET_SECRET:-combined-demo-config}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"

if [[ -n "${KUBECTL_CONTEXT}" ]]; then
  KUBECTL=(kubectl --context "${KUBECTL_CONTEXT}")
else
  KUBECTL=(kubectl)
fi

for command_name in kubectl jq base64; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

echo "Checking ESO resource readiness..."
"${KUBECTL[@]}" -n "${NAMESPACE}" wait \
  --for=condition=Ready secretstore/vault-kv-v1 --timeout=30s
"${KUBECTL[@]}" -n "${NAMESPACE}" wait \
  --for=condition=Ready secretstore/vault-shared-kv-v1 --timeout=30s
"${KUBECTL[@]}" -n "${NAMESPACE}" wait \
  --for=condition=Ready externalsecret/combined-demo-config --timeout=60s

EXPECTED_KEYS="$({
  printf '%s\n' \
    app_username \
    database_host \
    database_password \
    database_port \
    database_username \
    log_level \
    refresh_probe \
    region \
    source_order \
    support_contact
} | sort)"

ACTUAL_KEYS="$("${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${TARGET_SECRET}" -o json \
  | jq -r '.data | keys[]' | sort)"

if [[ "${ACTUAL_KEYS}" != "${EXPECTED_KEYS}" ]]; then
  echo "The target Secret does not contain the expected key set." >&2
  echo "Expected keys:" >&2
  printf '%s\n' "${EXPECTED_KEYS}" >&2
  echo "Actual keys:" >&2
  printf '%s\n' "${ACTUAL_KEYS}" >&2
  exit 1
fi

read_secret_value() {
  local key="$1"
  "${KUBECTL[@]}" -n "${NAMESPACE}" get secret "${TARGET_SECRET}" \
    -o "jsonpath={.data.${key}}" | base64 -d
}

assert_secret_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(read_secret_value "${key}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Unexpected value for key ${key}; values were not printed." >&2
    exit 1
  fi
}

assert_secret_value app_username demo-user
assert_secret_value database_host database.internal
assert_secret_value region homelab

# All three paths contain source_order. The last dataFrom entry must win.
assert_secret_value source_order shared-kv

"${KUBECTL[@]}" -n "${NAMESPACE}" rollout status deployment/eso-demo-app --timeout=60s
APP_LOGS="$("${KUBECTL[@]}" -n "${NAMESPACE}" logs deployment/eso-demo-app --tail=20)"
if [[ "${APP_LOGS}" != *"all combined secret files are present"* ]]; then
  echo "The demo application did not confirm its mounted files." >&2
  exit 1
fi

echo "PASS: three Vault paths from two KV v1 mounts were merged into one Kubernetes Secret."
echo "PASS: duplicate-key precedence and the mounted files are correct."
