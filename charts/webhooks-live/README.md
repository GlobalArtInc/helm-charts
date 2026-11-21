# webhooks-live

[webhooks.live](https://github.com/GlobalArtInc/helm-charts/tree/main/charts/webhooks-live) is a self-hosted HTTP request catcher. An endpoint receives any request, stores it with its headers, query and body, shows it live in the interface, and can forward it or answer it with a configured response.

This chart deploys one Deployment of stateless replicas, the Services, and optionally a route or an Ingress, a ServiceMonitor, a PodDisruptionBudget, an autoscaler, a NetworkPolicy and a migration Job. Everything is configured through `WEBHOOKS_LIVE_*` environment variables built from the values below. The chart renders no ConfigMap.

## Requirements

| | |
|---|---|
| Kubernetes | 1.26 or newer |
| PostgreSQL | A database and a role for webhooks.live, reachable from the pods. The schema is created by the migration Job. |
| Secrets | The database URL in an existing Secret. In `sso` mode, the OIDC client secret in an existing Secret. |
| OIDC provider | Only for `auth.mode: sso`. Register `<publicUrl>/auth/callback` as a redirect URI of the client. |
| Gateway API | Only for `route.enabled`. With the default `route.listenerSet.enabled: true`, the gateway must support `ListenerSet`. |
| Prometheus operator | Only for `monitoring.serviceMonitor.enabled`. |

## Install

Create the Secret with the database URL. The chart never takes the URL as a value.

```console
kubectl create namespace webhooks-live
kubectl create secret generic webhooks-live-db -n webhooks-live \
  --from-literal=url='postgres://webhooks_live:<password>@postgres.example.com:5432/webhooks_live'
```

Install the chart. Set `image.tag` to a tag your registry holds; the default is the chart's `appVersion`.

```console
helm repo add globalart https://globalartinc.github.io/helm-charts
helm install webhooks-live globalart/webhooks-live -n webhooks-live \
  --set publicUrl=https://webhooks.example.com \
  --set image.repository=registry.example.com/webhooks-live \
  --set image.tag=<tag> \
  --set database.existingSecret.name=webhooks-live-db \
  --set database.existingSecret.key=url
```

To check it without publishing anything:

```console
kubectl port-forward -n webhooks-live svc/webhooks-live 8080:8080
```

## What it deploys

| Object | Name | Notes |
|---|---|---|
| Deployment | `<fullname>` | `replicaCount` replicas (2), rolling update with `maxUnavailable: 0`. Container ports `http` 8080 and `admin` 9090. |
| Service | `<fullname>` | ClusterIP on 8080. Selects the server pods. |
| Service | `<fullname>-admin` | ClusterIP on 9090, for the ServiceMonitor only. Nothing routes to it. |
| Job | `<fullname>-migrate` | Helm hook, runs `webhooks-live migrate up`. See below. |
| ServiceAccount | `<fullname>` | Created by default. |
| PodDisruptionBudget | `<fullname>` | Rendered when there is more than one replica. |
| HorizontalPodAutoscaler | `<fullname>` | Only with `autoscaling.enabled`. |
| HTTPRoute, ListenerSet, Certificate, ReferenceGrant | `<fullname>-route`, … | Only with `route.enabled`. See below. |
| Ingress | `<fullname>` | Only with `ingress.enabled`. |
| ServiceMonitor | `<fullname>` | Only with `monitoring.serviceMonitor.enabled`. |
| NetworkPolicy | `<fullname>` | Only with `networkPolicy.enabled`. |

The pods listen on fixed ports: 8080 for the public API, the UI and the captures; 9090 for `/healthz`, `/readyz` and `/metrics`. The chart does not expose the listen addresses or the `WEBHOOKS_LIVE_CONFIG` file path, because the Service, the probes and the route depend on the ports.

The fullname is cut to 53 characters, so that the suffixes `-listeners`, `-migrate` and `-admin` keep every resource name within the 63-character limit of Service and Job names.

## Migrations

The Job `<fullname>-migrate` runs the same image with `migrate up`, with the same environment and Secret references as the server. It is a Helm hook:

- runs before install and before upgrade (`pre-install,pre-upgrade`), weight `-5`, so it runs before the new pods start;
- is deleted before the next run (`before-hook-creation`) and after success (`hook-succeeded`); a failed Job stays until `migrations.ttlSecondsAfterFinished` (600 s) so its logs can be read;
- retries `migrations.backoffLimit` times (2) and is cut off after `migrations.activeDeadlineSeconds` (300 s).

The Job uses the namespace's default ServiceAccount, not the chart's. The chart's ServiceAccount is an ordinary resource, and a pre-install hook runs before ordinary resources exist. The Job needs no Kubernetes API access either way.

Because the Job runs before the rollout, old and new replicas run side by side during an upgrade. Keep each schema change backward compatible with the previous release. The chart never runs `migrate down`.

The Job does not mount the server's `extraVolumes` and `extraVolumeMounts`, so a volume meant for the server does not reach it. The Job takes its own `migrations.extraVolumes` and `migrations.extraVolumeMounts`.

To run migrations elsewhere, set `migrations.enabled: false`. The server checks the schema on start and refuses to start when the database is behind the image, so run `webhooks-live migrate up` from the same image before the release starts:

```console
helm install webhooks-live globalart/webhooks-live -n webhooks-live \
  --set migrations.enabled=false \
  --set publicUrl=https://webhooks.example.com \
  --set image.repository=registry.example.com/webhooks-live \
  --set database.existingSecret.name=webhooks-live-db \
  --set database.existingSecret.key=url
```

## Routing through the Gateway API

With `route.enabled: true`, the chart renders one HTTPRoute with two rules, both to the `<fullname>` Service on port 8080:

| Order | Match | `timeouts.request` | Values |
|---|---|---|---|
| 1 | `RegularExpression` `^/api/v1/endpoints/[^/]+/stream$` (the live stream) | `0s` | `route.timeouts.stream` |
| 2 | `PathPrefix` `/` (everything else) | `60s` | `route.timeouts.default` |

The admin port is never routed. The two timeouts take Gateway API durations: `ms`, `s`, `m` and `h` units, such as `0s`, `60s` or `1m30s`; `d` and `w` are refused by the values schema.

**The SSE timeout rule.** The live stream is a Server-Sent Events response that stays open for minutes. With a request timeout the gateway cuts it at that timeout, and the client has to reconnect. Keep `route.timeouts.stream` at `0s`, which means no request timeout, and keep `route.timeouts.default` at a finite value for ordinary requests. After an install, check that a stream stays open longer than the default timeout (`curl -N https://webhooks.example.com/api/v1/endpoints/<id>/stream` with a valid endpoint ID, for more than 60 seconds). The gateway must support `RegularExpression` path matches; that support is implementation-specific in Gateway API.

The route attaches to a ListenerSet on the gateway by default. The TLS handling is:

- `route.tls.secretName` names an existing TLS Secret for the host; the ListenerSet terminates TLS with it.
- `route.tls.certificate.enabled: true` orders a cert-manager Certificate from `route.tls.certificate.issuer` into `route.tls.secretName`, or into `tls-<fullname>` when the name is empty.
- `route.tls.referenceGrant.enabled` (default `true`) creates a ReferenceGrant so the gateway can read the Secret, unless `route.tls.secretNamespace` points at another namespace. The chart does not create grants in that namespace.
- `route.listenerSet.enabled: false` attaches the route to an existing gateway listener (`route.gateway.sectionName`) instead, and no TLS objects are rendered.

## Trusted proxies

With `route.enabled` or `ingress.enabled`, every request reaches the server from the gateway or ingress pod. `trustedProxies` tells the server which addresses to trust for `X-Forwarded-For`, which is where it takes the visitor's IP, scheme and host from. The chart fails to render with `trustedProxies` empty in either case, because without it all visitors share the proxy's address: rate limits would be shared by everyone, and the scheme and host would be wrong.

Set `trustedProxies` to the pod CIDRs of your gateway or ingress controller, for example `10.42.0.0/16`. `0.0.0.0/0` and `::/0` trust every address; with them a client can set the forwarded headers itself, so use them only on purpose.

## Publishing through an Ingress

`ingress.enabled: true` renders one Ingress with a single path `/` to the server. Live SSE needs two settings on the stream path, and a single Ingress applies its annotations to every path:

- the proxy read timeout must be raised above the longest stream you expect, because the controller otherwise closes an idle stream;
- proxy buffering must be off, or events arrive in batches.

Set them through `ingress.annotations`. The example below is for ingress-nginx; other controllers use their own annotation names.

```console
--set ingress.enabled=true \
--set ingress.className=nginx \
--set ingress.host=webhooks.example.com \
--set-string ingress.annotations."nginx\.ingress\.kubernetes\.io/proxy-read-timeout"=3600 \
--set-string ingress.annotations."nginx\.ingress\.kubernetes\.io/proxy-buffering"=off
```

With an Ingress there is no per-path timeout, so the raised read timeout applies to ordinary requests too. Prefer the route when the gateway supports it.

## Scaling and availability

- `replicaCount` (2) sets the replica count. Replicas share one database and need no sticky sessions. Rate limits count per replica, so the effective limit grows with the count.
- `pdb.enabled` (true) with `pdb.minAvailable` (1) renders a PodDisruptionBudget when there is more than one replica. With autoscaling off, `minAvailable` has to stay below `replicaCount`, or the chart fails to render.
- `antiAffinity.mode` (`soft`) prefers spreading the replicas over nodes by `antiAffinity.topologyKey`; `hard` requires it, so a pod stays Pending without a free node; `none` adds nothing. `affinity` and `topologySpreadConstraints` take full manifests and `affinity` replaces the built-in rule.
- `autoscaling.enabled` renders a HorizontalPodAutoscaler on CPU utilisation between `minReplicas` and `maxReplicas`. `replicaCount` is then not rendered.
- The shutdown is `shutdown.drain` (5s) followed by `shutdown.grace` (25s). `terminationGracePeriodSeconds` (40) leaves time for both, and the chart fails to render unless it is at least 5 seconds more than their sum.

## Monitoring

- `monitoring.serviceMonitor.enabled` renders a ServiceMonitor that scrapes `/metrics` on the `admin` port of the `<fullname>-admin` Service every `interval`. It needs the `monitoring.coreos.com/v1` API; the chart fails to render without it. Set `labels` for the label your Prometheus selects on.
- `monitoring.podAnnotations.enabled` adds `prometheus.io/scrape`, `prometheus.io/port: "9090"` and `prometheus.io/path: /metrics` to the pods, for Prometheus setups without the operator.

## NetworkPolicy

`networkPolicy.enabled` renders a NetworkPolicy for the server pods with both policy types:

`networkPolicy.enabled` renders two NetworkPolicy objects:

- `<fullname>-ingress` selects the server pods. It allows ingress to 8080 from `networkPolicy.ingress.public.from`, for example the gateway's namespace, and to 9090 from `networkPolicy.ingress.admin.from`, for example the monitoring namespace. An empty list allows any source. Kubelet probes come from the node, and some CNIs filter them; if the probes fail after enabling the policy, add the node network as an `ipBlock` to `admin.from`.
- `<fullname>-egress` selects the server pods and the migration Job pods, by their instance labels. It allows egress to DNS on 53 (UDP and TCP) to `networkPolicy.egress.dns.to`, by default the kube-dns pods in kube-system, and to the database on `networkPolicy.egress.database.port` (5432) to `networkPolicy.egress.database.to`. The database list is **required**: the chart fails to render with it empty, because without it neither the server nor the migration Job can reach PostgreSQL. Further egress rules go in `networkPolicy.egress.extra`, as raw NetworkPolicyEgressRule entries. With `forward.enabled`, the forwarding worker calls arbitrary targets, so the destinations it may reach have to be allowed in `extra`.

Once a policy selects a pod, only the rules of that policy pass traffic for the pod.

## Security

- **Non-root.** The container runs as UID 65532 (the distroless `nonroot` user) with `runAsNonRoot: true`.
- **Read-only root filesystem.** `readOnlyRootFilesystem: true`. The server writes nothing to disk, so no volume is mounted for it.
- **No privilege.** `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`. The migration Job uses the same container context.
- **No API token.** `automountServiceAccountToken: false`. The server does not call the Kubernetes API.
- **Secrets by reference only.** The database URL and the OIDC client secret are read with `secretKeyRef` from Secrets you create. The chart renders no Secret object and no value of a secret, and no `values.yaml` key takes one in plain text. `database.url` is refused by the values schema.
- **Plain values are plain.** `config`, `extraEnv` and the other values render into the manifests in plain text. Do not put a secret in them; use `extraEnvFrom` with a Secret. `config` refuses the keys the chart sets from its own values (`DATABASE_URL`, `OIDC_CLIENT_SECRET` and the rest), and the keys that point at the config file or at the fixed ports, so the database URL cannot come in through it as plain text.

## Values

`values.schema.json` rejects keys the chart does not have, so a misspelt key is reported by Helm. Numbers are written as plain digits into the environment, so a large value such as `21474836480` stays `21474836480` whether it comes from a values file, `--set` or a deployment tool that hands over floats.

| Key | Type | Default | Description |
|---|---|---|---|
| `nameOverride` | string | `""` | Overrides the chart name in resource names. |
| `fullnameOverride` | string | `""` | Overrides the full resource name. |
| `publicUrl` | string | `""` (**required**) | Public base URL starting with `http://` or `https://`, for example `https://webhooks.example.com`. Rendered as `WEBHOOKS_LIVE_PUBLIC_URL`. |
| `replicaCount` | integer | `2` | Server replicas. Not rendered with `autoscaling.enabled`. |
| `image.repository` | string | `""` (**required**) | Image repository without a tag. |
| `image.tag` | string | `""` (appVersion) | Image tag. |
| `image.digest` | string | `""` | `sha256:<64 hex>`; when set, the image is pinned to it. |
| `image.pullPolicy` | string | `IfNotPresent` | `Always`, `IfNotPresent` or `Never`. |
| `imagePullSecrets` | list | `[]` | Image pull Secrets, by name. |
| `serviceAccount.create` | bool | `true` | Create the ServiceAccount named after the release. |
| `serviceAccount.name` | string | `""` | ServiceAccount name; `default` when not created and empty. |
| `serviceAccount.annotations` | map | `{}` | Annotations of the ServiceAccount. |
| `automountServiceAccountToken` | bool | `false` | Mount the API token into the pods. |
| `database.existingSecret.name` | string | `""` (**required**) | Existing Secret with the database URL. |
| `database.existingSecret.key` | string | `""` (**required**) | Key in that Secret. Rendered as `WEBHOOKS_LIVE_DATABASE_URL`. |
| `database.poolSize` | integer | `20` | Connections per replica, `WEBHOOKS_LIVE_DB_POOL_SIZE`. At least 2; 3 or more in practice. |
| `auth.mode` | string | `open` | `open` or `sso`. |
| `auth.sessionIdle` | duration | `12h` | Session idle lifetime. |
| `auth.sessionMax` | duration | `7d` | Maximum session lifetime. |
| `auth.oidc.issuer` | string | `""` | OIDC issuer URL starting with `https://` (or `http://` for a loopback address). **Required** in `sso`. |
| `auth.oidc.clientId` | string | `""` | OIDC client ID. **Required** in `sso`. |
| `auth.oidc.scopes` | list | `[openid, email, profile]` | Scopes, rendered space-separated. Only in `sso`. |
| `auth.oidc.providerName` | string | `""` | Name on the sign-in button; empty uses a neutral label. |
| `auth.oidc.clientSecret.existingSecret.name` | string | `""` | Existing Secret with the client secret. **Required** in `sso`. |
| `auth.oidc.clientSecret.existingSecret.key` | string | `""` | Key in that Secret. **Required** in `sso`. |
| `trustedProxies` | list | `[]` | Gateway or ingress pod CIDRs whose `X-Forwarded-For` is trusted; rendered comma-separated. **Required** with `route.enabled` or `ingress.enabled`; see Trusted proxies. |
| `retention` | duration | `7d` | How long captures are kept. |
| `ringModeAllowed` | bool | `true` | Allow endpoints with `overflow: ring`. |
| `limits.maxCaptures` | integer | `500` | Captures kept per endpoint. |
| `limits.maxBodyBytes` | integer or string | `10MiB` | Largest accepted body. |
| `limits.bodyMemoryBudget` | integer or string | `256MiB` | Memory for bodies in flight per replica. |
| `limits.maxDelayed` | integer | `2000` | Delayed responses at once per replica. |
| `limits.storageCapBytes` | integer or string | `20GiB` | Storage cap for all captures. |
| `rateLimits.captureIp` | string | `30/s:60` | Captures per client IP. |
| `rateLimits.captureEndpoint` | string | `20/s:100` | Captures per endpoint. |
| `rateLimits.apiIp` | string | `20/s:40` | API requests per client IP. |
| `rateLimits.createIp` | string | `10/m:10` | Endpoint creation per client IP. |
| `forward.enabled` | bool | `true` | Run the forwarding worker. |
| `forward.concurrency` | integer | `32` | Parallel forward attempts per replica. |
| `forward.maxAttempts` | integer | `3` | Attempts per forwarded capture. |
| `forward.allowCidrs` | list | `[]` | CIDRs forwarding may reach although the SSRF guard blocks them. |
| `shutdown.drain` | duration | `5s` | Wait after SIGTERM, with readiness at 503. |
| `shutdown.grace` | duration | `25s` | Wait for in-flight work after the drain. |
| `log.filter` | string | `info` | Log filter in EnvFilter syntax. |
| `config` | map | `{}` | Extra settings: key `K` renders as `WEBHOOKS_LIVE_K`. Upper-case keys only; the chart's own keys and the config file and port keys are refused. |
| `terminationGracePeriodSeconds` | integer | `40` | Pod grace period; at least 5 seconds more than `shutdown.drain` plus `shutdown.grace`, or the chart fails. |
| `probes.startup.periodSeconds`, `.timeoutSeconds`, `.failureThreshold` | integer | `5`, `3`, `60` | Startup probe on `/readyz`: up to 300 s for the first database connection and schema check. |
| `probes.readiness.*` | integer | `10`, `3`, `3` | Readiness probe on `/readyz`. |
| `probes.liveness.*` | integer | `15`, `3`, `3` | Liveness probe on `/healthz`. |
| `resources` | object | requests `100m` CPU, `256Mi`; limit `768Mi` memory | Container resources. No CPU limit by default. |
| `podAnnotations` | map | `{}` | Annotations of the server pods. |
| `podLabels` | map | `{}` | Labels of the server pods. |
| `podSecurityContext` | object | `{}` | Pod security context of the server and migration pods. |
| `securityContext` | object | non-root 65532, read-only root, no capabilities, `RuntimeDefault` seccomp | Container security context of the server and migration containers. |
| `extraEnv` | list | `[]` | Extra EnvVar entries for both containers. |
| `extraEnvFrom` | list | `[]` | Extra envFrom sources for both containers. |
| `extraVolumes` | list | `[]` | Extra volumes for the server pods only; the migration Job has `migrations.extraVolumes`. |
| `extraVolumeMounts` | list | `[]` | Extra mounts for the server container only. |
| `nodeSelector` | map | `{}` | Node selector of the server and migration pods. |
| `tolerations` | list | `[]` | Tolerations of the server and migration pods. |
| `affinity` | object | `{}` | Full affinity of the server pods; replaces `antiAffinity` when set. |
| `antiAffinity.mode` | string | `soft` | `soft`, `hard` or `none`. |
| `antiAffinity.topologyKey` | string | `kubernetes.io/hostname` | Node label of the failure domain. |
| `topologySpreadConstraints` | list | `[]` | Topology spread constraints of the server pods. |
| `pdb.enabled` | bool | `true` | Render the PodDisruptionBudget when there is more than one replica. |
| `pdb.minAvailable` | integer or string | `1` | Count or percentage; a count has to stay below `replicaCount` when autoscaling is off. |
| `autoscaling.enabled` | bool | `false` | Render a HorizontalPodAutoscaler. |
| `autoscaling.minReplicas` | integer | `2` | Lowest replica count. |
| `autoscaling.maxReplicas` | integer | `6` | Highest replica count; at least `minReplicas`. |
| `autoscaling.targetCPUUtilizationPercentage` | integer | `70` | Target CPU utilisation, 1 to 100. |
| `migrations.enabled` | bool | `true` | Run the migration Job as a hook. |
| `migrations.backoffLimit` | integer | `2` | Retries of the Job. |
| `migrations.activeDeadlineSeconds` | integer | `300` | Time limit of the Job. |
| `migrations.ttlSecondsAfterFinished` | integer | `600` | Seconds a finished Job is kept. |
| `migrations.extraVolumes` | list | `[]` | Extra volumes for the migration Job only. |
| `migrations.extraVolumeMounts` | list | `[]` | Extra mounts for the migration container only. |
| `route.enabled` | bool | `false` | Publish through the Gateway API. |
| `route.host` | string | `""` | Public hostname. **Required** with `route.enabled`. |
| `route.gateway.name` | string | `""` | Gateway the route attaches to. **Required** with `route.enabled`. |
| `route.gateway.namespace` | string | `envoy-gateway-system` | Namespace of the Gateway. |
| `route.gateway.sectionName` | string | `""` | Listener to attach to; used only with `route.listenerSet.enabled: false`. |
| `route.listenerSet.enabled` | bool | `true` | Attach through a ListenerSet this chart creates. |
| `route.tls.secretName` | string | `""` | TLS Secret for the host. Required with the ListenerSet unless a certificate is ordered. |
| `route.tls.secretNamespace` | string | `""` | Namespace of a TLS Secret that lives elsewhere. |
| `route.tls.certificate.enabled` | bool | `false` | Order a cert-manager Certificate for the host. |
| `route.tls.certificate.issuer` | string | `""` | ClusterIssuer for that certificate. Required with `certificate.enabled`. |
| `route.tls.referenceGrant.enabled` | bool | `true` | Create the ReferenceGrant for a Secret in this namespace. |
| `route.tls.referenceGrant.name` | string | `""` | ReferenceGrant name; empty means `<fullname>-tls-read`. |
| `route.annotations` | map | `{}` | Annotations of the HTTPRoute. |
| `route.timeouts.stream` | Gateway API duration | `0s` | Request timeout of the live stream rule. Keep `0s`. Units `ms`, `s`, `m`, `h`. |
| `route.timeouts.default` | Gateway API duration | `60s` | Request timeout of every other path. Units `ms`, `s`, `m`, `h`. |
| `ingress.enabled` | bool | `false` | Publish through an Ingress. |
| `ingress.className` | string | `""` | `ingressClassName`. |
| `ingress.host` | string | `""` | Public hostname. **Required** with `ingress.enabled`. |
| `ingress.annotations` | map | `{}` | Annotations of the Ingress, for example proxy read timeout and buffering. |
| `ingress.tls.secretName` | string | `""` | TLS Secret for the host; empty renders no TLS block. |
| `monitoring.serviceMonitor.enabled` | bool | `false` | Render a ServiceMonitor for the admin port. |
| `monitoring.serviceMonitor.interval` | duration | `30s` | Scrape interval. |
| `monitoring.serviceMonitor.labels` | map | `{}` | Extra labels on the ServiceMonitor. |
| `monitoring.podAnnotations.enabled` | bool | `false` | Plain Prometheus scrape annotations on the pods. |
| `networkPolicy.enabled` | bool | `false` | Render the NetworkPolicy objects `<fullname>-ingress` and `<fullname>-egress`. Requires `egress.database.to`. |
| `networkPolicy.ingress.public.from` | list | `[]` | Sources of port 8080; empty allows any. |
| `networkPolicy.ingress.admin.from` | list | `[]` | Sources of port 9090; empty allows any. |
| `networkPolicy.egress.dns.enabled` | bool | `true` | Allow DNS. |
| `networkPolicy.egress.dns.to` | list | kube-dns in kube-system | DNS destinations. |
| `networkPolicy.egress.database.to` | list | `[]` | Database destinations. **Required** with `networkPolicy.enabled`: the chart fails to render when it is empty. |
| `networkPolicy.egress.database.port` | integer | `5432` | Database port. |
| `networkPolicy.egress.extra` | list | `[]` | Further egress rules. |
| `global` | object | `{}` | Reserved by Helm for parent charts. |

## Upgrading

- The migration Job runs before the rollout on every upgrade. A failed migration fails the upgrade, and the old pods keep serving.
- Keep schema changes backward compatible across one release, because old and new replicas run together during the rollout.
- A change to the pod template (image, environment, probes, resources) rolls the pods; `maxUnavailable: 0` keeps the old ones serving until the new ones are ready. A change to `replicaCount` only scales.
- With `migrations.enabled: false`, migrate before you upgrade the image.

## Rendering the examples

The `ci/` folder holds four values files that the chart is rendered with in tests: `open-minimal-values.yaml`, `sso-route-values.yaml`, `everything-values.yaml` and `large-numbers-values.yaml`, which passes large integers as numbers. Each uses example names only.

```console
helm lint charts/webhooks-live -f charts/webhooks-live/ci/sso-route-values.yaml
helm template webhooks-live charts/webhooks-live -f charts/webhooks-live/ci/everything-values.yaml --api-versions monitoring.coreos.com/v1
```
