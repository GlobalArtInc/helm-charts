# conductor

[Conductor OSS](https://github.com/conductor-oss/conductor): the workflow engine, with its UI, on PostgreSQL and Elasticsearch.

One Deployment, one Service on port `8080`. The server answers the UI and the API on that port, so there is one thing to publish and one thing to protect.

## What it needs

| | | |
|---|---|---|
| PostgreSQL | required | Workflow state and queues. The database has to exist before the first start; the server creates its schema itself. |
| Elasticsearch **7.x** | required by default | Search in the UI. See below for why not 8. |
| Redis | only with `replicaCount` > 1 | The distributed lock. The chart refuses to render two replicas without it. |

### Elasticsearch has to be 7.x

The image bundles an Elasticsearch **7.17** client and no other (`conductoross/conductor:3.32.5` carries the `elasticsearch`, `postgres` and `sqlite` indexing modules; there is no `elasticsearch8` and no OpenSearch). Against an Elasticsearch 8 server the client's legacy index templates are refused with `unknown key [template] in the template`: the server still starts, and three of its five indices are left without their mappings. Against 7.17 it starts clean. Run a 7.17 cluster for this release; it cannot share one with a workload that needs 8.

Set `elasticsearch.enabled=false` to run without search; the UI then has no workflow search.

## Install

Create the database, then the secrets:

```console
kubectl create namespace conductor
kubectl create secret generic conductor-postgres -n conductor --from-literal=password='...'
```

```console
helm repo add globalart https://globalartinc.github.io/helm-charts
helm install conductor globalart/conductor -n conductor \
  --set postgres.host=postgres.example.svc \
  --set postgres.existingSecret=conductor-postgres \
  --set elasticsearch.url=http://elasticsearch:9200
```

Without `postgres.existingSecret`, pass `postgres.password` and the chart makes the Secret. The same two ways exist for Elasticsearch credentials (`elasticsearch.username` with `elasticsearch.existingSecret` or `elasticsearch.password`); the password reaches the server through an environment variable, never through the ConfigMap.

Workers in the cluster reach the API at `http://<release>-conductor.<namespace>.svc:8080/api`.

## Publishing

Nothing is published by default. **Conductor OSS has no authentication.** Whoever reaches port 8080 can read, start and terminate workflows, and `/actuator` and `/swagger-ui` are on the same port and are served by whatever route or ingress points at it. Put the gate in front: an authenticating proxy, an allow-list, or a gateway policy.

Gateway API and Ingress are alternatives; both may be on while moving between them.

### Gateway API

The house shape, as in `mediacore`: a `ListenerSet` on the shared gateway and an `HTTPRoute` on it.

```console
--set route.enabled=true \
--set route.host=conductor.example.com \
--set route.tls.secretName=wildcard-example-com
```

- `route.tls.secretNamespace` names the namespace of a certificate that lives elsewhere. A `ReferenceGrant` in that namespace is not this chart's to create.
- `route.tls.certificate.enabled=true` orders a `Certificate` from the `route.tls.certificate.issuer` ClusterIssuer, for a name no wildcard covers.
- `route.tls.referenceGrant.enabled` (default `true`) lets the gateway read the Secret in this namespace.
- `route.gateway.name` and `route.gateway.namespace` default to `moscow-gateway` in `envoy-gateway-system`.

To attach to a listener that already exists, without a `ListenerSet` (and so without the TLS settings above, which then belong to the gateway):

```console
--set route.enabled=true \
--set route.host=conductor.example.com \
--set route.listenerSet.enabled=false \
--set route.gateway.name=global \
--set route.gateway.namespace=istio-system \
--set route.gateway.sectionName=https
```

`route.gateway.sectionName` is optional. It is only used in this mode.

### Ingress

```console
--set ingress.enabled=true \
--set ingress.className=nginx \
--set ingress.host=conductor.example.com \
--set ingress.tls.secretName=tls-conductor
```

`ingress.host` falls back to `route.host`. The default `nginx.ingress.kubernetes.io/proxy-body-size` is 16m, above the 10 MB payload limit Conductor enforces; other controllers ignore it.

## More than one replica

```console
--set replicaCount=2 \
--set lock.type=redis \
--set lock.redis.address=redis://redis:6379
```

`lock.type` is `none` (default, one replica), `local_only` (one replica, in-process) or `redis`.

## Values

| Key | Default | |
|---|---|---|
| `image.repository`, `image.tag` | `conductoross/conductor`, chart `appVersion` | |
| `replicaCount` | `1` | |
| `postgres.host`, `.port`, `.database`, `.username` | `""`, `5432`, `conductor`, `conductor` | `host` is required |
| `postgres.password` / `postgres.existingSecret` + `existingSecretKey` | `""` / `""` + `password` | one of the two is required |
| `postgres.pool.maximumPoolSize`, `.minimumIdle` | `10`, `2` | Hikari, per replica |
| `elasticsearch.enabled`, `.url`, `.indexName` | `true`, `""`, `conductor` | `url` is required when enabled |
| `elasticsearch.clusterHealthColor` | `yellow` | a single node never turns green |
| `elasticsearch.indexReplicasCount` | unset | set `0` on a single node |
| `lock.type`, `lock.redis.address` | `none`, `""` | |
| `config.extra` | `{}` | extra `config.properties` lines, written after the chart's own |
| `javaOpts`, `extraEnv` | `""`, `[]` | |
| `route.*`, `ingress.*` | off | see above |
| `metrics.enabled`, `.path` | `false`, `/actuator/prometheus` | turns the Prometheus endpoint on |
| `metrics.serviceMonitor.enabled`, `.interval`, `.labels` | `false`, `30s`, `{}` | needs the Prometheus operator's CRDs |
| `probes.path` | `/health` | |
| `resources` | 1 CPU / 1500Mi requests, 2 CPU / 2500Mi limits | |
| `pdb.enabled`, `pdb.minAvailable` | `false`, `1` | |
| `podSecurityContext`, `securityContext` | `{}` | see below |

`values.schema.json` rejects keys the chart does not have, so a typo is refused by helm and named.

## Things worth knowing

- **The container runs as root.** The image starts nginx on 5000 and writes `/app/logs`; `runAsNonRoot: true` stops it. The chart sets no security context and publishes only 8080. nginx on 5000 serves the same UI and proxies the same API as 8080 does, so nothing is lost.
- **A config change rolls the pods.** The Deployment carries a checksum of the ConfigMap and of the chart-made Secrets.
- **Health is `/health`.** Startup is allowed `periodSeconds` x `failureThreshold` = 300 s, which covers the first start, when the schema is created.
- **The image is not pinned to `latest`.** `appVersion` is the tested release.
