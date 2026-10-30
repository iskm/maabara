# External Secrets Operator with Vault KV v1

This guide configures External Secrets Operator (ESO) to combine several Vault
KV v1 paths into one Kubernetes Secret.

The example reads:

| Vault mount | Vault path | Purpose |
|---|---|---|
| `kv/` | `apps/eso/base` | Base application settings |
| `kv/` | `apps/eso/database` | Database settings |
| `shared-kv/` | `platform/eso` | Settings owned by the platform team |

All three become keys in one Kubernetes Secret:

```text
eso-demo/combined-demo-config
```

No Vault root key, unseal key, token, reviewer JWT, or application secret is
stored in these files. The setup script uses the Vault CLI's existing login or
the `VAULT_TOKEN` environment variable.

## Why ESO solves this case

A Vault `SecretStore` points at one KV mount. An `ExternalSecret` can contain
multiple ordered `dataFrom` entries, and each entry can select its own
`SecretStore` with `sourceRef.storeRef`.

```text
Vault kv/apps/eso/base ---------\
Vault kv/apps/eso/database ------+--> ExternalSecret --> one Kubernetes Secret
Vault shared-kv/platform/eso ----/
```

This gives us both forms of aggregation:

- Multiple paths inside the same KV v1 mount use the same `SecretStore`.
- Paths in other KV mounts use additional `SecretStore` objects.
- Every `dataFrom` entry still writes into the same target Secret.

ESO documents that multiple `dataFrom` entries are merged in their declared
order. If two paths contain the same key, the later entry wins. The demo proves
that behavior using `source_order`: its final value must come from
`shared-kv/platform/eso`, the last entry.

## Files

| File | Purpose |
|---|---|
| `external-secrets-manifests.yaml` | Two Vault stores, one combined ExternalSecret, and a test Deployment |
| `external-secrets-setup.sh` | Configures Vault/Kubernetes, writes isolated demo data, installs ESO, and applies the manifests |
| `external-secrets-smoke-test.sh` | Read-only validation without printing values |
| `external-secrets-refresh-test.sh` | Changes one demo value and verifies periodic synchronization |

## Assumptions

The defaults describe the load-balanced Kubernetes environment:

| Item | Default |
|---|---|
| Vault URL | `https://vault1.homelab.test:8200` |
| Kubernetes API reachable from Vault | `https://k3s1.homelab.test:6443` |
| Vault Kubernetes auth mount | `kubernetes-k3s` |
| Namespace | `eso-demo` |
| ESO authentication ServiceAccount | `eso-vault-auth` |
| Vault role and policy | `eso-demo` |
| KV v1 mounts | `kv/` and `shared-kv/` |

The Kubernetes API certificate must contain `k3s1.homelab.test` in its SANs,
and the Vault host must be able to resolve and reach that name. The script uses
the CA from the currently selected kubeconfig context for Vault TokenReview.

Required local commands:

```text
kubectl
helm
vault
jq
openssl
base64
```

The file `vault-ca.crt` must be the CA that issued Vault's HTTPS certificate.
Check it without exposing anything sensitive:

```bash
openssl x509 -in ./vault-ca.crt -noout -subject -issuer -dates
```

Make sure the intended Kubernetes context and Vault login are active:

```bash
kubectl config current-context

export VAULT_ADDR="https://vault1.homelab.test:8200"
export VAULT_CACERT="$(pwd)/vault-ca.crt"
vault status
vault token lookup
```

The Vault token needs permission to manage this Kubernetes auth mount, write
the `eso-demo` policy and role, enable the demo KV mount if absent, and write
the three demo paths.

## Run the setup

The setup is intentionally explicit and idempotent. It refuses to use an
existing mount unless that mount is KV v1.

It checks all namespaces for a deployed Helm release named `external-secrets`
before contacting the chart repository. On the current `k3s-baxter` cluster it
will reuse the existing `external-secrets-2.14.0` release in `default` and will
not download or install another copy.

```bash
chmod +x external-secrets-setup.sh \
  external-secrets-smoke-test.sh \
  external-secrets-refresh-test.sh

./external-secrets-setup.sh
```

To select a kubeconfig context without changing your global current context:

```bash
KUBECTL_CONTEXT="k3s-r730xd" ./external-secrets-setup.sh
```

The setup performs these operations:

1. Extracts the selected cluster's CA using `kubectl config view --minify`.
2. Creates a dedicated TokenReview ServiceAccount and binding.
3. Configures `auth/kubernetes-k3s` in Vault to use the selected cluster API URL.
4. Confirms `kv/` and `shared-kv/` are KV v1 mounts, creating them if absent.
5. Writes harmless values to the three isolated demo paths.
6. Creates a least-privilege policy for exactly those three paths.
7. Binds `eso-demo/eso-vault-auth` to the Vault role with audience `vault`.
8. Reuses an existing ESO Helm release, or installs chart `2.14.0` if absent.
9. Creates the Vault CA Secret and applies the example.
10. Waits for both stores, the ExternalSecret, and the demo pod.

The audience is explicit because current Vault versions require Kubernetes
roles to declare one. ESO requests a short-lived ServiceAccount token with the
same `vault` audience.

## Understand the manifests

Each store names one KV v1 mount:

```yaml
provider:
  vault:
    server: https://vault1.homelab.test:8200
    path: kv
    version: v1
```

KV v1 is important. Paths and policies do **not** contain a `/data/` segment.
For example:

```text
ESO key:     apps/eso/base
Vault path:  kv/apps/eso/base
Policy path: kv/apps/eso/base
```

The ExternalSecret selects a store for every source:

```yaml
dataFrom:
  - extract:
      key: apps/eso/base
    sourceRef:
      storeRef:
        name: vault-kv-v1
        kind: SecretStore

  - extract:
      key: apps/eso/database
    sourceRef:
      storeRef:
        name: vault-kv-v1
        kind: SecretStore

  - extract:
      key: platform/eso
    sourceRef:
      storeRef:
        name: vault-shared-kv-v1
        kind: SecretStore
```

There is no top-level `secretStoreRef` because every entry names its source.
That is what permits one ExternalSecret to cross Vault mount boundaries.

### Avoiding duplicate-key overwrites

The demo intentionally uses last-entry-wins behavior. For production, unique
key names are usually clearer. If two teams both publish a key such as
`password`, prefix one source with a rewrite:

```yaml
  - extract:
      key: platform/eso
    sourceRef:
      storeRef:
        name: vault-shared-kv-v1
        kind: SecretStore
    rewrite:
      - regexp:
          source: "^(.*)$"
          target: "platform_$1"
```

That produces keys such as `platform_password` instead of silently replacing
an earlier `password`.

## Test the result

Run the read-only test first:

```bash
./external-secrets-smoke-test.sh
```

It checks:

- both `SecretStore` objects are ready;
- the `ExternalSecret` is ready;
- the target Secret has exactly the expected merged keys;
- representative values came from all three paths;
- the intentional duplicate was resolved using the documented order; and
- the demo Deployment can mount files from the combined Secret.

The test compares secret values internally but never writes them to stdout or
stderr.

Then run the write-based refresh test:

```bash
./external-secrets-refresh-test.sh
```

It updates only `shared-kv/platform/eso`, waits for the 30-second refresh, and
confirms that the existing Kubernetes Secret changes. It leaves a harmless
timestamp-like probe value at that demo path.

## Adapt this to real paths

For each Vault KV mount:

1. Create one `SecretStore`.
2. Set `path` to the mount name and `version: v1`.
3. Add exact `read` capabilities for every source path to the Vault policy.
4. Add one `dataFrom.extract` entry per path.
5. Point `sourceRef.storeRef.name` at the correct store.
6. Decide deliberately whether duplicate keys should overwrite or be renamed.

An exact KV v1 policy looks like this:

```hcl
path "team-kv/apps/my-app/config" {
  capabilities = ["read"]
}

path "platform-kv/shared/database" {
  capabilities = ["read"]
}
```

Do not grant `list` over an entire mount unless you use `dataFrom.find` and
actually need discovery. Exact `extract` paths only need `read`.

## Troubleshooting

Start with compact status output:

```bash
kubectl -n eso-demo get secretstore,externalsecret
kubectl -n eso-demo describe secretstore vault-kv-v1
kubectl -n eso-demo describe secretstore vault-shared-kv-v1
kubectl -n eso-demo describe externalsecret combined-demo-config
kubectl -n external-secrets logs deployment/external-secrets --tail=100
```

### `403 permission denied` during Vault login

Check that all four names agree:

```text
SecretStore mountPath:              kubernetes-k3s
Vault auth mount:                   auth/kubernetes-k3s
SecretStore role:                   eso-demo
Vault role bound identity:          eso-demo/eso-vault-auth
```

Also verify the Vault auth backend contains the load-balancer URL and the
correct cluster CA:

```bash
vault read auth/kubernetes-k3s/config
vault read auth/kubernetes-k3s/role/eso-demo
```

Each independent Kubernetes cluster needs its own Vault Kubernetes auth mount.
A mount holds only one Kubernetes API URL, CA, and reviewer JWT.

### TLS or hostname errors reaching Kubernetes

Vault connects to `https://k3s1.homelab.test:6443`, not necessarily to the
kubeconfig's local alias. If this endpoint is a load balancer, it must pass
TCP/TLS through to the API server. The API server certificate must contain the
exact hostname configured in `K8S_HOST` in its SAN list.

### TLS errors reaching Vault

Confirm `vault-ca.crt` is the issuing CA, not merely the Vault leaf
certificate. Both SecretStores reference the namespaced `vault-ca` Secret.

### Store is ready but the ExternalSecret is not

That usually means authentication worked and a data path or policy is wrong.
For KV v1, use:

```text
Store path:     kv
Extract key:    apps/eso/base
Policy path:    kv/apps/eso/base
```

Do not insert `data/` anywhere.

### A key has the wrong value

Look for the same key in more than one source. `dataFrom` is ordered and later
entries take precedence. Rename keys at the source or use `rewrite.regexp` to
make ownership visible.

## Security boundary

Like VSO, ESO writes a normal Kubernetes Secret. Its contents therefore enter
the Kubernetes API, etcd, backups, controller caches, and any system authorized
to read that Secret. Enable Kubernetes encryption at rest and keep RBAC narrow.
Use CSI or Vault Agent when values must never become Kubernetes Secret objects.

## References

- [ESO Vault provider](https://external-secrets.io/latest/provider/hashicorp-vault/)
- [ESO ExternalSecret API](https://external-secrets.io/main/api/externalsecret/)
- [ESO key rewrite guide](https://external-secrets.io/latest/guides/datafrom-rewrite/)
- [ESO installation guide](https://external-secrets.io/latest/introduction/getting-started/)
- [Vault Kubernetes auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
