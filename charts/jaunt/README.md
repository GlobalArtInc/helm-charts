# jaunt

[Jaunt](https://github.com/GlobalArtInc/jaunt) is an identity-aware access gateway for SSH. After a single sign-on through OIDC it issues short-lived SSH certificates, so people reach servers without long-lived keys, bastion hosts or VPNs. Agents on the protected hosts connect outward, so those hosts need no inbound ports.

This chart deploys `jauntd`, the control and gate daemon: one pod, one SQLite database and one certificate authority on a persistent volume. It also renders the ConfigMaps, the Services, and optionally a Job that creates the certificate authority, Gateway API routes or an Ingress, and a NetworkPolicy.

**There is no high availability yet.** The state is one SQLite file with a single writer, so the chart runs one replica with the `Recreate` strategy and refuses `replicaCount` above 1. An upgrade or a node failure means a short outage of the control port, the agents' listener and the SSH gate. Agents reconnect on their own.

## Requirements

| | |
|---|---|
| Kubernetes | 1.26 or newer |
| Image | `image.repository` is required, for example `registry.example.org/jaunt`: the chart has no default image. The tag defaults to the chart's `appVersion` and has to exist in your registry; set `image.tag` (or `image.digest`) to one you have built. See [What the image must provide](#what-the-image-must-provide). |
| OIDC provider | A confidential client with the redirect URI `<publicUrl>/v1/login/callback`. See below. |
| Secrets | Two existing Secrets: the OIDC client secret and the age identity of the certificate authorities. The chart never creates either and never takes them as values. |
| Volume | A ReadWriteOnce volume on **block storage**, 1 GiB by default. SQLite needs working file locks and `fsync`: do not put it on NFS or another network file system. |
| Gateway API | Only for `route.*`. A gateway with `ListenerSet` support that allows the ListenerSet (`allowedListeners`), and the `TLSRoute` and `TCPRoute` CRDs for the agents and the SSH gate. The examples target Gateway API 1.5 (experimental channel) with Envoy Gateway 1.8. |
| cert-manager | Only for `route.tls.certificate.enabled`. |

## What the image must provide

The chart runs the container as user and group **65532** with a read-only root filesystem and no shell. The image needs the `jauntd` binary on its `PATH` (`image.command`, default `jauntd`) and nothing else: no shell, no init system. The chart passes `--config <path> run` itself. These are the paths the chart uses, and the image must not depend on any other writable path:

| Path | What | Mounted from |
|---|---|---|
| `/etc/jaunt/config/jauntd.yaml` | The config (`JAUNT_CONFIG` and `--config`) | ConfigMap `<fullname>`, read-only |
| `/var/lib/jaunt` (`dataDir`) | `jaunt.db` and `ca/` | The volume |
| `/etc/jaunt/policy` | The policy files | ConfigMap, read-only |
| `/run/secrets/jaunt/ca/identity` | The age identity (`JAUNT_CA_KEY_FILE`) | Secret, read-only |
| `/run/secrets/jaunt/oidc/client-secret` | The OIDC client secret | Secret, read-only |
| `/etc/jaunt/trust/oidc-roots.pem` | Extra root certificates of the issuer, if `oidc.extraRootCertificates` is set | ConfigMap, read-only |
| `/tmp` | Scratch | An emptyDir of 64 MiB |

Everything the daemon writes goes to `/var/lib/jaunt`. The daemon creates `jaunt.db` with mode 0600 and the files under `ca/` with mode 0600, owned by the user that created them. **Do not change the user ID after the first `ca init`**: the new user could not read the existing `ca/` files. If you must, change the ownership of the whole volume first.

## Install

Create the two Secrets first, as described in [First run](#first-run). Then:

```console
helm repo add globalart https://globalartinc.github.io/helm-charts
helm install jaunt globalart/jaunt -n jaunt --create-namespace \
  --set image.repository=registry.example.org/jaunt \
  --set image.tag=<tag> \
  --set publicUrl=https://jaunt.example.org \
  --set sshSuffix=ssh.example.org \
  --set agentEndpoint=agents.example.org:443 \
  --set oidc.issuerUrl=https://sso.example.org \
  --set oidc.clientId=jaunt \
  --set oidc.clientSecret.name=jaunt-oidc \
  --set oidc.clientSecret.key=client-secret \
  --set ca.identitySecret.name=jaunt-ca-identity \
  --set ca.identitySecret.key=identity \
  --set ca.init.enabled=true
```

`ca.init.enabled=true` is for the very first install only; see [First run](#first-run). To check the control port without publishing anything:

```console
kubectl port-forward -n jaunt svc/jaunt 8443:8443
curl http://localhost:8443/healthz
```

## What it deploys

| Object | Name | Notes |
|---|---|---|
| Deployment | `<fullname>` | One replica, `Recreate`. Read-only root filesystem, all capabilities dropped, `RuntimeDefault` seccomp, user and group 65532, `fsGroup` 65532. No service account token. |
| Service | `<fullname>` | Ports `http` and `agents` (with `agents.enabled`). ClusterIP unless `service.type` says NodePort. |
| Service | `<fullname>-ssh` | Port `ssh`, with `sshGate.enabled`. ClusterIP, or NodePort for an external proxy. A Service of its own, so that it can be exposed differently from the other two. |
| ConfigMap | `<fullname>` | `jauntd.yaml`, rendered from the values. Its checksum is a pod annotation, so a change restarts the pod. |
| ConfigMap | `<fullname>-policy` | The policy files from `policy.files`. Not rendered with `policy.existingConfigMap`. A change does **not** restart the pod. |
| PersistentVolumeClaim | `<fullname>` | The data directory. Not rendered with `persistence.existingClaim` or without `persistence.enabled`. |
| ServiceAccount | `<fullname>` | Created by default. |
| Job | `<fullname>-ca-init` | Only with `ca.init.enabled`. |
| ListenerSet | `<fullname>-listeners` | Only with `route.listenerSet.enabled` and a route enabled. |
| HTTPRoute | `<fullname>-route`, `<fullname>-redirect` | `route.http.enabled`; the redirect with `route.http.redirect.enabled`. |
| TLSRoute | `<fullname>-agents` | `route.agents.enabled`. |
| TCPRoute | `<fullname>-ssh` | `route.ssh.enabled`. |
| Certificate | `tls-<fullname>` | The https listener's certificate, with `route.tls.certificate.enabled`. |
| Ingress | `<fullname>` | Only with `ingress.enabled`. |
| NetworkPolicy | `<fullname>` | Only with `networkPolicy.enabled`. |

There is no ServiceMonitor and no PodDisruptionBudget: `jauntd` exposes no metrics endpoint at the time of writing, and there is one replica. The audit events are JSON lines on the pod's stderr (`target` `jaunt::audit`); collect them with the cluster's log pipeline.

The chart makes no ReferenceGrant; see [The TLS Secret and the ListenerSet](#the-tls-secret-and-the-listenerset).

The fullname is cut to 53 characters so that the suffixes keep every name within Kubernetes' limits.

## The three ports

| Port name | Container port (`ports.*`) | Protocol | Purpose |
|---|---|---|---|
| `http` | 8443 | Plain HTTP | Control API, web UI, device login and the OIDC callback. TLS is terminated in front of it, by the gateway or the ingress. The probes use `GET /healthz` here. |
| `agents` | 8444 | TLS with mutual authentication | Node agents dial this. `jauntd` terminates the TLS itself, with a server certificate for the host of `agentEndpoint` and a client-certificate check against its internal CA. **Nothing in front of it may terminate TLS.** |
| `ssh` | 2222 | SSH | The SSH gate. Off by default. Needs `gateEndpoint` and the agents' listener. Above 1024 because the container is not root. |

The three numbers have to differ. `ports.*` go into `listen`, `agents_listen` and `ssh_gate.listen` of `jauntd.yaml`, and the Services and the routes refer to the ports by name. The Service ports are `service.ports.http.port`, `service.ports.agents.port` and `service.ssh.port`; they default to the container ports.

### Exposure matrix

| Port | How | TLS | PROXY protocol | Hostname |
|---|---|---|---|---|
| `http` | HTTPRoute (plus an optional redirect route) on an `HTTPS` listener; or an Ingress | Terminated by the gateway; certificate from `route.tls` | No | The host of `publicUrl` |
| `agents` | TLSRoute on a `TLS` listener, mode `Passthrough` | Passed through untouched; `jauntd` does the mutual TLS | No | SNI: the host of `agentEndpoint` |
| `ssh`, mode 1 | TCPRoute on a `TCP` listener of the gateway | None at this layer | Optional, v2, sent by the gateway (`BackendTrafficPolicy`) | None: TCP has no hostname |
| `ssh`, mode 2 | `service.ssh.type: NodePort`, reached by an external layer-4 proxy (for example haproxy) that is not part of the gateway | None at this layer | Optional, v2, sent by that proxy | None |

Each route is optional and independent, and `route.ssh` and a NodePort for the SSH gate exclude each other.

The hosts are not free values: the HTTPRoute and the Ingress use the host of `publicUrl`, and the TLSRoute uses the host of `agentEndpoint`. `route.http.host`, `ingress.host` and `route.agents.host` exist only so that you can write the same name down; the chart fails when they differ. Hosts have to be lower case.

With `route.listenerSet.enabled` (the default) the chart creates a ListenerSet on `route.gateway` with one listener per enabled route: `https`, `http` (for the redirect), `agents` and `ssh`, on the ports in `route.listenerSet.ports` (443, 80, 443 and 22). The `agents` listener is a `TLS` listener of its own, so it shares port 443 with `https` as long as the hostnames differ; the port has to match the port of `agentEndpoint`. With `route.listenerSet.enabled: false` the routes attach to listeners that already exist on the Gateway, and `route.http.sectionName`, `route.agents.sectionName` and `route.ssh.sectionName` are required, so that a route never attaches to every listener of a shared Gateway.

**The Gateway must allow the ListenerSet.** A Gateway only accepts ListenerSets its `spec.allowedListeners` lets in (for example `namespaces.from: All` or a selector that matches the release namespace). Without that the ListenerSet is not accepted and no route attaches.

**apiVersions of the routes.** `route.agents.apiVersion` and `route.ssh.apiVersion` are empty by default, and then the chart picks what the cluster serves, by the API versions Helm can see: a TLSRoute uses `gateway.networking.k8s.io/v1` when the cluster serves it and `v1alpha2` otherwise, a TCPRoute uses `v1` when served and `v1alpha2` otherwise. When Helm cannot tell (`helm template` knows no CRDs), the defaults are `v1` for the TLSRoute and `v1alpha2` for the TCPRoute, which is what a Gateway API 1.5 cluster serves. Set the value to force one. To see what your cluster serves:

```console
kubectl get crd tlsroutes.gateway.networking.k8s.io tcproutes.gateway.networking.k8s.io \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.versions[*].name}{"\n"}{end}'
```

**The http->https redirect** (`route.http.redirect.enabled`) is a second HTTPRoute with a `RequestRedirect` filter (`https`, status 301). It attaches to the chart's `http` listener with the ListenerSet, or to the Gateway listener named by `route.http.redirect.sectionName` (default `http`) without it. If the public https port is not 443, set `route.http.redirect.port`.

An `ingress.enabled` alternative exists for the http port only. The agents' listener and the SSH gate cannot go through an Ingress.

### The TLS Secret and the ListenerSet

The https listener needs a certificate Secret, `route.tls.secretName`.

- **A Secret in the release namespace** needs nothing more. With `route.tls.certificate.enabled` the chart orders it from a ClusterIssuer into `route.tls.secretName`, or into `tls-<fullname>` when the name is empty.
- **A Secret in another namespace**, for example a cluster wildcard certificate, is named with `route.tls.secretNamespace`. The chart makes **no** ReferenceGrant: the grant has to live in the namespace that owns the Secret, and a chart installed in another namespace may not create objects there. A grant for a Gateway is not inherited by a ListenerSet (GEP-1713), so the grant names the ListenerSet as the one that may refer to the Secret. Create it in the Secret's namespace:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: jaunt-tls-read
  namespace: <namespace of the Secret>
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: ListenerSet
      namespace: <release namespace>
  to:
    - group: ""
      kind: Secret
      name: <route.tls.secretName>
```

Without the grant the listener is accepted and never programmed, with a message in its status that the Secret cannot be referenced.

### SSH gate, mode 1: a TCPRoute through the gateway

`route.ssh.enabled` renders a TCPRoute on a `TCP` listener (port `route.listenerSet.ports.ssh`, 22). The backend is the Service `<fullname>-ssh` of type ClusterIP.

To pass the client's address on, the gate can require PROXY protocol v2. The chart ships no `BackendTrafficPolicy` or `ClientTrafficPolicy`; those belong to the platform:

- `sshGate.proxyProtocol: true` makes the gate **require** a v2 header on every connection. A connection without one is closed, so every path to the port, in-cluster ones included, has to send it.
- `sshGate.trustedProxies` lists the CIDR blocks of the proxies that may send it, and is required with `proxyProtocol`. For a gateway in the cluster, this is the pod CIDR of the gateway's proxy pods, as narrow as you can make it. The chart refuses a block that the daemon refuses: `/0`, an IPv4 block shorter than `/8`, an IPv6 block shorter than `/16`, an IPv4-mapped IPv6 block and an address without a prefix.
- With Envoy Gateway the proxy sends the header to the backend when a `BackendTrafficPolicy` targets the TCPRoute with `spec.proxyProtocol.version: V2`. A `ClientTrafficPolicy` is the other direction (a load balancer in front of the gateway sending the header to it) and does not set this up. The field there is `enableProxyProtocol` up to Envoy Gateway 1.7, and it is deprecated in favour of `proxyProtocol` from 1.8 and 1.9; the examples here target 1.8.2, so check `kubectl explain clienttrafficpolicy.spec` for the field your version has.
- Without `proxyProtocol`, the gate sees the proxy's address as the client, and per-client limits and audit records name the proxy.

### SSH gate, mode 2: a NodePort behind an external layer-4 proxy

When an external proxy (haproxy, a cloud load balancer) reaches the gate directly and not through the Gateway, give the SSH Service a fixed node port and let the proxy send PROXY v2:

```yaml
sshGate:
  enabled: true
  proxyProtocol: true
  trustedProxies:
    - 192.0.2.10/32

service:
  ssh:
    type: NodePort
    nodePort: 30022
    externalTrafficPolicy: Local

networkPolicy:
  enabled: true
  ingress:
    ssh:
      from:
        - ipBlock:
            cidr: 192.0.2.10/32
```

- `externalTrafficPolicy: Local` (the default) keeps the proxy's own address as the source of the connection. `trustedProxies` matches that address; with `Cluster` the node's address replaces it, the check fails and the gate closes every connection. The price of `Local` is that only the node that runs the pod answers, so list every node in the proxy and let it health-check them. For haproxy:

  ```text
  backend jaunt-ssh
    mode tcp
    server node-a 192.0.2.21:30022 send-proxy-v2 check
    server node-b 192.0.2.22:30022 send-proxy-v2 check
  ```
- `trustedProxies` is the proxy's address as the pod sees it, as narrow as possible, here a `/32`.
- The NetworkPolicy limits who can open a connection to the port at all. `ipBlock` rules for traffic arriving through a node port depend on the CNI keeping the source address, which `Local` does.
- The gate answers a connection that does not start with a PROXY header by closing it, so a client that reaches the port directly gets nothing.

## Values

Every value, with its default. The values schema is strict: an unknown top-level key fails `helm install`, except under `config`.

### Daemon

| Key | Default | Description |
|---|---|---|
| `publicUrl` | `""` | **Required.** The public https base URL of the `http` port: lower-case host, no path, no trailing slash. The OIDC redirect URI is `<publicUrl>/v1/login/callback`. |
| `sshSuffix` | `""` | **Required.** DNS suffix of the node names users type, a lowercase DNS name (the daemon accepts a single label). |
| `agentEndpoint` | `""` | **Required.** `host:port` the agents dial: a lowercase DNS name (not an IP address, not a name ending in a number) and a port from 1 to 65535. The host is the server name of the agents' certificate. |
| `gateEndpoint` | `""` | `host[:port]` clients learn as the SSH gate: a DNS name or an IPv4 address; not an IPv6 address with the gate on. Required with `sshGate.enabled`. |
| `dataDir` | `/var/lib/jaunt` | The data directory: the database `jaunt.db` and the `ca` directory. |
| `ports.http`, `ports.agents`, `ports.ssh` | `8443`, `8444`, `2222` | Container ports, three different numbers. `ssh` is at least 1024. |
| `agents.enabled` | `true` | The agents' listener. |
| `sshGate.enabled` | `false` | The SSH gate. |
| `sshGate.hostnames` | `[]` | Names clients may use for the gate: at most 64, lowercase DNS names, no repeats. Empty means the host of `gateEndpoint`, which has to be in the list. |
| `sshGate.proxyProtocol` | `false` | Require a PROXY protocol v2 header. |
| `sshGate.trustedProxies` | `[]` | Proxies allowed to send it. Required with `proxyProtocol`, refused without. |
| `oidc.issuerUrl`, `oidc.clientId` | `""` | **Required.** |
| `oidc.clientSecret.name`, `.key` | `""` | **Required.** An existing Secret and the key that holds the client secret. Mounted as a file with mode 0400. |
| `oidc.extraRootCertificates.name`, `.key` | `""` | An existing ConfigMap and key with a PEM file of extra root certificates for the issuer. |
| `ca.identitySecret.name`, `.key` | `""` | **Required.** An existing Secret and the key that holds the age identity. Mounted as a file with mode 0400. |
| `ca.init.enabled` | `false` | Render the `ca init` Job. See [First run](#first-run). |
| `ca.init.activeDeadlineSeconds`, `.ttlSecondsAfterFinished`, `.resources` | `300`, `3600`, `{}` | The Job's limits. |
| `config` | `{}` | Free-form `jauntd.yaml`, see below. |
| `policy.files` | `{}` | Policy file name -> YAML text. Names end in `.yaml` or `.yml`. |
| `policy.existingConfigMap` | `""` | Mount this ConfigMap instead. Exclusive with `policy.files`. |
| `log.filter` | `""` | `RUST_LOG` filter. Empty keeps the daemon's default, `info`. |

### Workload

| Key | Default | Description |
|---|---|---|
| `replicaCount` | `1` | 0 or 1. |
| `image.repository` | `""` | **Required.** The image without a tag. |
| `image.tag`, `.digest`, `.pullPolicy` | `""`, `""`, `IfNotPresent` | An empty tag means `appVersion`, and that tag has to exist. A digest is appended to the tag. |
| `image.command` | `[jauntd]` | The program the container runs, as a list. The chart appends `--config <path> run`. |
| `imagePullSecrets` | `[]` | |
| `serviceAccount.create`, `.name`, `.annotations` | `true`, `""`, `{}` | |
| `automountServiceAccountToken` | `false` | `jauntd` never calls the Kubernetes API. |
| `terminationGracePeriodSeconds` | `30` | The daemon's own shutdown grace is 10 s. Values below 15 are refused. |
| `probes.startup`, `.readiness`, `.liveness` | see `values.yaml` | `GET /healthz` on `http`. It answers as soon as the daemon serves and says nothing about the database. |
| `resources` | 100m / 128Mi requests, 512Mi memory limit | |
| `podSecurityContext`, `securityContext` | non-root 65532, `fsGroup` 65532, read-only root filesystem, no capabilities, `RuntimeDefault` seccomp | |
| `podAnnotations`, `podLabels`, `nodeSelector`, `tolerations`, `affinity` | empty | |
| `extraEnv`, `extraEnvFrom`, `extraVolumes`, `extraVolumeMounts` | empty | `extraEnv` may not set `JAUNT_CA_KEY`, `JAUNT_CA_KEY_FILE`, `JAUNT_OIDC_CLIENT_SECRET` or `JAUNT_CONFIG`: the chart wires those, and the daemon refuses two sources for one secret. The chart cannot look inside `extraEnvFrom`, so keep those two secrets out of any Secret or ConfigMap listed there: the pod would exit at start with the daemon's "exactly one source" error. |
| `persistence.enabled` | `true` | Without it the data directory is an emptyDir, and the certificate authority and the database are lost with the pod. |
| `persistence.existingClaim`, `.storageClass`, `.size`, `.accessModes`, `.annotations` | `""`, `""`, `1Gi`, `[ReadWriteOnce]`, `{}` | |
| `persistence.retain` | `true` | Adds `helm.sh/resource-policy: keep`, so `helm uninstall` leaves the claim in place. Reinstalling under the same name then needs `persistence.existingClaim`. |
| `service.type` | `ClusterIP` | The Service of `http` and `agents`: `ClusterIP` or `NodePort`. |
| `service.annotations` | `{}` | |
| `service.ports.http.port`, `service.ports.agents.port` | `8443`, `8444` | |
| `service.ports.<port>.nodePort` | `null` | Only with `service.type: NodePort`. |
| `service.ssh.type` | `ClusterIP` | The SSH Service: `ClusterIP` or `NodePort`. |
| `service.ssh.port`, `.nodePort` | `2222`, `null` | `nodePort` only with `NodePort`. |
| `service.ssh.externalTrafficPolicy` | `Local` | Only with `NodePort`. |
| `service.ssh.annotations` | `{}` | |

### Exposure

| Key | Default | Description |
|---|---|---|
| `route.gateway.name`, `.namespace` | `""`, `envoy-gateway-system` | The Gateway. Required when any route is on. |
| `route.listenerSet.enabled` | `true` | Create the ListenerSet. |
| `route.listenerSet.ports.https`, `.http`, `.agents`, `.ssh` | `443`, `80`, `443`, `22` | Listener ports. |
| `route.tls.secretName` | `""` | The TLS Secret of the https listener. With `certificate.enabled`, an empty name means `tls-<fullname>`. |
| `route.tls.secretNamespace` | `""` | Namespace of an existing Secret that is not the release's. The grant for it is yours to make. Not with `certificate.enabled`. |
| `route.tls.certificate.enabled`, `.issuer` | `false`, `""` | Order a cert-manager Certificate from a ClusterIssuer. |
| `route.annotations` | `{}` | Annotations on every route. |
| `route.http.enabled` | `false` | The HTTPRoute. |
| `route.http.host` | `""` | Empty means the host of `publicUrl`; if set, it has to be that host. |
| `route.http.sectionName` | `""` | Gateway listener. Required without the ListenerSet. |
| `route.http.timeouts.request` | `""` | Gateway API duration such as `60s`. Empty sets none. |
| `route.http.redirect.enabled`, `.sectionName`, `.statusCode`, `.port` | `false`, `http`, `301`, `null` | The http->https redirect route. |
| `route.agents.enabled` | `false` | The TLSRoute with passthrough. |
| `route.agents.apiVersion` | `""` | Empty picks what the cluster serves. |
| `route.agents.host` | `""` | Empty means the host of `agentEndpoint`; if set, it has to be that host. |
| `route.agents.sectionName` | `""` | Gateway listener. Required without the ListenerSet. |
| `route.ssh.enabled` | `false` | The TCPRoute. |
| `route.ssh.apiVersion` | `""` | Empty picks what the cluster serves. |
| `route.ssh.sectionName` | `""` | Gateway listener. Required without the ListenerSet. |
| `ingress.enabled`, `.className`, `.host`, `.annotations`, `.tls.secretName` | `false`, `""`, `""`, `{}`, `""` | An Ingress for the http port. The host is the host of `publicUrl`. |
| `networkPolicy.enabled` | `false` | |
| `networkPolicy.ingress.<port>.from` | `[]` | Peers allowed to reach each port. Empty admits every source. |
| `networkPolicy.egress.enabled` | `false` | Restrict egress as well. Then `egress.oidc.to` is required. |
| `networkPolicy.egress.dns`, `.oidc`, `.extra` | kube-dns, `to: []` on port 443, `[]` | DNS, the OIDC issuer, anything else. Agents connect inward, so nothing else is needed. |

### The free-form `config`

`config` is merged over the keys the chart generates from the values above: `data_dir`, `listen`, `agents_listen`, `policy_dir`, `public_url`, `ssh_suffix`, `agent_endpoint`, `gate_endpoint`, `ssh_gate` and `oidc`. Maps merge key by key, lists are replaced. Everything else goes straight into `jauntd.yaml`, so a section added to the daemon in a later release needs no chart change:

```yaml
config:
  cert_ttl_secs: 14400
  device_login: true
  policy_poll_secs: 5
  oidc:
    scopes: [openid, email, groups]
    groups_claim: groups
    require_verified_email: true
  ssh_gate:
    max_unauthenticated: 512
    write_stall_secs: 900
```

- **The chart refuses a config that sets a key it owns**: `data_dir`, `listen`, `agents_listen`, `policy_dir`, any `ssh_gate` key except `max_unauthenticated` and `write_stall_secs`, `oidc.client_secret*`, `oidc.extra_root_certificates_file`, and any key at any depth with `secret` in its name. The volumes, the probes, the Services and the secret wiring depend on them. Use `dataDir`, `ports`, `agents.enabled`, `sshGate`, `oidc.clientSecret` and `oidc.extraRootCertificates` instead. `public_url`, `ssh_suffix`, `agent_endpoint`, `gate_endpoint`, `oidc.issuer_url` and `oidc.client_id` can still be set here, and the chart checks them in the merged result.
- The daemon **rejects unknown keys** at start, so a typo fails the pod, with the message in its log, not `helm template`.
- `config` is a plain ConfigMap. Never put a secret in it. The daemon's own errors never echo secret values, and neither does the chart's.
- The default policy directory of the daemon is under the data directory; the chart mounts its own at `/etc/jaunt/policy` instead, so the volume holds no policy.
- Sections that the daemon gains later, such as `audit` and `limits`, go here as they arrive. The chart does not know their keys, and the daemon of your image has to know them: check the release notes of the image before adding one.

## First run

The daemon does not start until its certificate authorities exist. They live in `<dataDir>/ca`, three age-encrypted keys (user, host, internal), and the age identity that decrypts them stays **outside** the data directory, in a Secret.

### 1. Create the age identity Secret, without printing it

Generate the identity with [age](https://github.com/FiloSottile/age) into a file only you can read, keep a copy where you keep other recovery material, and load it into a Secret:

```console
umask 077
age-keygen -o jaunt-ca.agekey
kubectl create secret generic jaunt-ca-identity -n jaunt --from-file=identity=jaunt-ca.agekey
```

`age-keygen -o` prints the public key, not the secret, to the terminal; the secret goes only into the file. The daemon reads the file as **exactly one** identity line: comment lines (the `# created` and `# public key` lines that age-keygen writes) and blank lines are skipped, but a second identity line is an error, so do not append another key to the file. **Keep the file.** Without the identity the keys in `<dataDir>/ca` cannot be decrypted, and every issued certificate has to be re-trusted by re-creating the authority. Anyone who holds both the identity and a copy of the `ca` directory can issue certificates, so do not store them together.

Create the OIDC client secret the same way, without it ever entering a shell history or a file in the repository:

```console
kubectl create secret generic jaunt-oidc -n jaunt --from-file=client-secret=<path-to-a-file-holding-the-secret>
```

### 2. Create the authority

The chart ships a Job for this, `ca.init.enabled`, and it is safe: it is the daemon's `ca init` with the identity supplied as a **file** (`JAUNT_CA_KEY_FILE`, mounted from the Secret). That mode never generates a key, never writes an identity to the volume and prints only public data, namely the user and host CA public keys and the SHA-256 of the internal root. The daemon's other mode, `--generate-identity`, which writes a fresh secret identity into the data directory, is deliberately **not** available through the chart.

Install with `--set ca.init.enabled=true` (as above). The Job is an ordinary resource, not a Helm hook: a pre-install hook would run before the volume exists, and a post-install hook would wait for a daemon that cannot become ready without the authority, so `helm install --wait` would never get there. Practical consequences:

- The daemon pod and the Job start together. The pod fails with `cannot load the certificate authorities` until the Job has finished, and the kubelet restarts it with a back-off of up to a few minutes; then it starts.
- The Job is scheduled onto the same node as the daemon pod (a required pod affinity), so that a ReadWriteOnce volume can be mounted by both. It therefore needs `replicaCount: 1` and a volume that is not ReadWriteOncePod.
- The Job has no retries (`backoffLimit: 0`). If it fails, read its log (`kubectl logs -n jaunt job/<fullname>-ca-init`); the messages are the daemon's own and contain no secret. Delete the Job to retry after fixing the cause: `kubectl delete job -n jaunt <fullname>-ca-init`, then `helm upgrade` again.
- A Job that stays Pending (the volume is not bound, or the daemon pod it must sit next to cannot be scheduled) ends with `DeadlineExceeded` after `ca.init.activeDeadlineSeconds` (300 s). Fix the cause, delete the Job and upgrade again.
- A Job's pod template is immutable. If a later `helm upgrade` changes the chart version or the image while the Job still exists (it is kept for `ca.init.ttlSecondsAfterFinished`, 3600 s), Helm fails with a `field is immutable` error. Delete the Job first, or turn `ca.init.enabled` off.
- Read the public keys from the log. The user CA public key is what hosts, and the gate, trust.

**Turn the Job off afterwards**, on the next upgrade: `helm upgrade ... --set ca.init.enabled=false`. `ca init` refuses an initialised directory ("already initialized, nothing was changed"), so a second run fails, and an upgrade that re-creates the Job would fail with it.

If you would rather not use the Job, the same can be done by hand: scale to zero (`--set replicaCount=0`), then run a one-off pod from the same image that mounts the volume and the identity Secret exactly as the Job does and runs `jauntd --config /etc/jaunt/config/jauntd.yaml ca init`, with `JAUNT_CA_KEY_FILE` set to the mounted file; then scale back to 1.

### 3. The first admin policy

An empty policy denies everything, including the admin permissions. Put the first role in `policy.files`; the pod picks it up within `policy_poll_secs` (5 s) without a restart:

```yaml
policy:
  files:
    admins.yaml: |
      apiVersion: jaunt/v1
      kind: Role
      metadata:
        name: admins
      spec:
        members:
          users:
            - alice@example.org
        admin:
          - nodes.approve
          - sessions.read
```

The other admin permissions are `recordings.read` and `revocations.write`. The daemon refuses an invalid policy at start, and keeps the previous one when a reload fails, with the reason in its log. A reload that would leave the policy empty is refused too, so removing every file does not clear a running policy: restart the pod for that. Policy files are mounted from a ConfigMap, so a policy that grows beyond a ConfigMap (1 MiB) wants `policy.existingConfigMap` and another way to build it; the daemon itself allows 512 files and 8 MiB.

Nodes are approved with the daemon's CLI inside the pod, which has the config in its environment. The commands ask for confirmation on stdin, so use `-it`, or pass `--yes`. The approver is recorded as `cli:<USER>` and as `cli:unknown` when `USER` is not set in the process's environment, and `kubectl exec` sets none; `env` sets it if the image has it:

```console
kubectl exec -n jaunt deploy/jaunt -- jauntd node list
kubectl exec -it -n jaunt deploy/jaunt -- env USER=alice jauntd node approve <code>
kubectl exec -n jaunt deploy/jaunt -- env USER=alice jauntd node approve --yes <code>
```

An image without `env` can get a fixed value for every exec with `extraEnv: [{name: USER, value: jaunt-admin}]`; that records the same approver for everyone, so prefer the first form.

## OIDC prerequisites

- A confidential client at the issuer, with the **redirect URI `<publicUrl>/v1/login/callback`** exactly (for `publicUrl: https://jaunt.example.org`: `https://jaunt.example.org/v1/login/callback`). The daemon builds it from `public_url`; a different public name needs a different registration.
- The issuer must be reachable from the pod over HTTPS, and its certificate trusted. For a private CA, put the PEM in a ConfigMap and set `oidc.extraRootCertificates`.
- Scopes default to `openid`, `email`, `profile` and `groups`; override with `config.oidc.scopes`. `config.oidc.username_claim`, `config.oidc.groups_claim` and `config.oidc.require_verified_email` (default true) tune how a login becomes an identity.
- The daemon asks the issuer for its configuration **once, at start, before it binds a port, and does not retry** (the requests time out after 10 s and 30 s). If the issuer is unreachable at that moment, the daemon exits with code 1, and the kubelet restarts the pod with its usual back-off. After a restart of the issuer or of the network, expect the pod to recover on its own on a later attempt. A pod that is up has no dependency on the issuer until a user logs in.

## Upgrades

- The strategy is `Recreate`: the old pod stops (up to 10 s of graceful shutdown) before the new one starts, because SQLite and the volume admit one writer. Plan for an outage of the control port, the agents' listener and the SSH gate during an upgrade. Open SSH sessions through the gate end; agents reconnect.
- The daemon migrates its database on start. Take a copy of the volume (a snapshot) before upgrading to a new chart or image version, and do not roll an image back past a migration without restoring it.
- A change to the values behind `jauntd.yaml` restarts the pod (the config checksum). A change to `policy.files` does not.
- **A changed Secret does not restart the pod.** The OIDC client secret and the age identity are read at start, and the chart's checksum covers the config, not the content of a Secret. After rotating either, run `kubectl rollout restart -n jaunt deploy/jaunt`. (A `podAnnotations` entry that you change, for example a hash you compute outside, also rolls the pod.)
- `persistence.retain` keeps the claim on `helm uninstall`. Delete it by hand only when you mean to destroy the authority and the database.
- With `persistence.accessModes: [ReadWriteOnce]` a pod that moves to another node waits for the volume to detach. That is a long wait if the old node is down, and it is the price of the single writer.
- If `ca.init.enabled` is still on from the first install, see the Job notes under [First run](#first-run): delete the Job before upgrading to a new chart version.

## Security notes

- **Secrets.** The chart creates no Secret and takes no secret as a value. The OIDC client secret and the age identity are mounted as files, referenced by `client_secret_file` and `JAUNT_CA_KEY_FILE`. The volumes ask for mode 0400; with `fsGroup` set, Kubernetes shows a Secret file as mode 0440, owned by root with group 65532, so that the non-root user can read it. The daemon itself does not check the mode of either file. They never appear in the ConfigMap, the environment or the Job's arguments. The chart refuses to render when either reference is missing, refuses `extraEnv` that would supply the same secret a second time, and refuses a `config` with a secret in it.
- **What is in the volume.** The age-encrypted CA keys and the SQLite database, which holds users, nodes, sessions and certificate records. The identity is not there. Treat volume snapshots as sensitive anyway.
- **Pod hardening.** Non-root, read-only root filesystem (writable volumes: the data directory and a 64 MiB `/tmp`), no capabilities, no privilege escalation, `RuntimeDefault` seccomp, no service account token, no service links.
- **The `http` port is plain HTTP.** Publish it only through a gateway or an ingress that terminates TLS. `publicUrl` must be https, and the daemon refuses anything else. Never expose a NodePort Service of this port to the internet.
- **The `agents` port must not be terminated by a proxy.** Terminating TLS in front of it breaks the client-certificate check that tells agents from strangers. Use passthrough, as the TLSRoute does.
- **`config.client_ip_header`.** The device login can take the client address from a header. With it set, **any pod in the cluster can reach port 8443 directly and send that header itself**, which defeats the per-client limits. Two things close this: the daemon's `client_ip_trusted_proxies` option, a list of CIDR blocks from which the header is honoured (it arrives with a later daemon release; check that your image knows it before you set it, because an older daemon rejects the key), and a NetworkPolicy that lets only the gateway's pods reach the `http` port:

  ```yaml
  config:
    client_ip_header: x-forwarded-for
    client_ip_trusted_proxies:
      - 10.42.0.0/16

  networkPolicy:
    enabled: true
    ingress:
      http:
        from:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: envoy-gateway-system
  ```

  Set the header only if the gateway sets it and strips any client-supplied copy. Leave `client_ip_trusted_proxies` out until your image supports it; the NetworkPolicy works with every version.
- **PROXY protocol.** `trustedProxies` is the only thing that stops a client from claiming any source address. Keep it as narrow as the proxy fleet, and never use a block that is wider than the proxies.
- **NetworkPolicy.** `networkPolicy.enabled` restricts who reaches each port; with `egress.enabled` it also restricts what the pod reaches, which is only DNS and the OIDC issuer.
- **The image.** Pin `image.digest` in production.

## Rendering the examples

The `ci/` folder holds five values files that the chart is rendered with in tests: `minimal-values.yaml`, `gateway-values.yaml` (every route on a ListenerSet, the redirect, the Job, a NetworkPolicy), `existing-gateway-values.yaml` (routes on listeners of an existing Gateway, NodePort Services, existing claim and ConfigMap), `nodeport-ssh-values.yaml` (the SSH gate on a NodePort behind an external PROXY v2 proxy, the TLS Secret in another namespace) and `ingress-values.yaml`. Each uses example names only.

```console
helm lint charts/jaunt --strict -f charts/jaunt/ci/gateway-values.yaml
helm template jaunt charts/jaunt -n jaunt -f charts/jaunt/ci/gateway-values.yaml \
  --api-versions gateway.networking.k8s.io/v1/TLSRoute \
  --api-versions gateway.networking.k8s.io/v1alpha2/TCPRoute
```

`ci/negative-render.sh` checks that every refusal in the chart fires, with its message, and that a few configurations the daemon accepts still render. Run it from the repository root or from the chart folder:

```console
sh charts/jaunt/ci/negative-render.sh charts/jaunt
```

## Example: a first production install on a Gateway API cluster

```yaml
image:
  repository: registry.example.org/jaunt
  tag: "<tag>"

publicUrl: https://jaunt.example.org
sshSuffix: ssh.example.org
agentEndpoint: agents.example.org:443
gateEndpoint: gate.example.org:22

oidc:
  issuerUrl: https://sso.example.org
  clientId: jaunt
  clientSecret:
    name: jaunt-oidc
    key: client-secret

ca:
  identitySecret:
    name: jaunt-ca-identity
    key: identity
  init:
    enabled: true

sshGate:
  enabled: true
  proxyProtocol: true
  trustedProxies:
    - 192.0.2.10/32

service:
  ssh:
    type: NodePort
    nodePort: 30022

route:
  gateway:
    name: example-gateway
    namespace: envoy-gateway-system
  tls:
    secretName: wildcard-example-org
    secretNamespace: example-certs
  http:
    enabled: true
    redirect:
      enabled: true
  agents:
    enabled: true
```

DNS: `jaunt.example.org` and `agents.example.org` point at the gateway's address; `gate.example.org` points at the external proxy. The gateway needs `ListenerSet` support with `allowedListeners` that admit the release namespace, listeners allowed on ports 80 and 443, and a ReferenceGrant in `example-certs` for the wildcard Secret, as above.
