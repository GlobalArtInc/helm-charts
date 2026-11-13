# conductor

[Conductor OSS](https://github.com/conductor-oss/conductor): the workflow engine, with its UI, on PostgreSQL and Elasticsearch.

One Deployment, one Service on port `8080`. The server answers the UI and the API on that port, so there is one thing to publish and one thing to protect.

## What it needs

| | | |
|---|---|---|
| PostgreSQL | required | Workflow state and queues. The database has to exist before the first start; the server creates its schema itself. |
| Elasticsearch **7.x** | required by default | Search in the UI. See below for why not 8. |
| Redis | only with `lock.type` `redis` | The distributed lock for several replicas. `lock.type` `postgres` uses PostgreSQL instead. The chart refuses to render two replicas without a lock. |

### Elasticsearch has to be 7.x

The image bundles an Elasticsearch **7.17** client and no other (`conductoross/conductor:3.32.5` carries the `elasticsearch`, `postgres` and `sqlite` indexing modules; there is no `elasticsearch8` and no OpenSearch). Against an Elasticsearch 8 server the client's legacy index templates are refused with `unknown key [template] in the template`: the server still starts, and three of its five indices are left without their mappings. Against 7.17 it starts clean. Run a 7.17 cluster for this release; it cannot share one with a workload that needs 8.

Set `elasticsearch.enabled=false` to run without search; the UI then has no workflow search.

### Built-in Elasticsearch

`elasticsearch.cluster.enabled=true` runs a 7.17 cluster from this chart: a StatefulSet with every node master, data and ingest eligible, a client Service `<fullname>-es` on 9200, a headless Service `<fullname>-es-headless`, and a PodDisruptionBudget (three or more replicas). When `elasticsearch.url` is empty, the server uses `http://<fullname>-es:9200`; an explicit `url` is used as is, so the cluster can be built first and the server pointed at it later. Security is off (`xpack.security.enabled=false`), as the cluster is meant to be reached from inside the namespace only. The volumes are kept when the release or the replica count shrinks (`Retain`).

```console
--set elasticsearch.cluster.enabled=true \
--set elasticsearch.cluster.replicas=3 \
--set elasticsearch.indexReplicasCount=1
```

The chart refuses two replicas, and an `indexReplicasCount` that is unset or larger than `replicas - 1`: an index whose replica cannot be placed keeps the cluster yellow, and a restarted pod is ready only when the cluster is green. While rolling, the next pod waits for green; nodes that have been ready once stay in the Service while the cluster is yellow.

Turning `elasticsearch.cluster.enabled` on in an existing release without `joinSeedHosts` does not form a cluster: `helm upgrade` does not set `cluster.initial_master_nodes`, so the new pods stay Running but not Ready. To bootstrap a new cluster inside the existing release, set `elasticsearch.cluster.extraConfig` with the key `cluster.initial_master_nodes` and a value listing the pod names `<fullname>-es-0` through `<fullname>-es-<replicas - 1>`, or reinstall the release.

#### Moving from another Elasticsearch cluster

The new nodes can join a running 7.17 cluster, so the data is carried over by shard relocation, with no reindexing. Give `cluster.name` the name of the running cluster and point `joinSeedHosts` at its headless Service, with the namespace if it is not this one:

```console
--set elasticsearch.cluster.enabled=true \
--set elasticsearch.cluster.name=conductor-elasticsearch \
--set elasticsearch.cluster.joinSeedHosts[0]=conductor-elasticsearch-master-hl \
--set elasticsearch.url=http://conductor-elasticsearch:9200 \
--set elasticsearch.indexReplicasCount=1
```

Keep `elasticsearch.url` on the old cluster until the new nodes hold their share; clear it afterwards and the server moves to `<fullname>-es`. Then drain the old nodes one at a time (`cluster.routing.allocation.exclude._name`), wait for green, and remove them. Transport (9300) has to be open between the two sets of pods.

- `cluster.initial_master_nodes` is what makes a node bootstrap a cluster of its own. The chart sets it only on `helm install` and only when `joinSeedHosts` is empty. On upgrade, and always with `joinSeedHosts`, it is absent: otherwise scaling 1 to 3 would make the new nodes elect a master among themselves and form a second cluster. The first `helm upgrade` after an install therefore changes the pod template and rolls the nodes once. Where the chart is rendered by `helm template` (not by `helm install`), the variable is always set; Elasticsearch ignores it on nodes that already hold cluster state.
- Resources carry the `-es` suffix and the labels `app.kubernetes.io/name=<chart name>-elasticsearch`, `app.kubernetes.io/component=elasticsearch`, which no selector of the server matches. The StatefulSet selector cannot be changed after the first install.
- `allowMmap: false` sets `node.store.allow_mmap=false`. It is what lets the pods start with no privileged init container and no `vm.max_map_count` set on the node, but Elasticsearch then reads index files with plain file I/O instead of memory mapping, which is slower on large indices and leans more on the page cache. Elasticsearch refuses to start with `allowMmap: true` on a node where `vm.max_map_count` is below 262144; with `false` (the default) that threshold does not matter and no privileged init container is needed.

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

`lock.type` is `none` (default, one replica), `local_only` (one replica, in-process), `redis` or `postgres` (the lock lives in the same PostgreSQL database, no extra service; it works with several replicas).

## Values

| Key | Default | |
|---|---|---|
| `image.repository`, `image.tag` | `conductoross/conductor`, chart `appVersion` | |
| `replicaCount` | `1` | |
| `postgres.host`, `.port`, `.database`, `.username` | `""`, `5432`, `conductor`, `conductor` | `host` is required |
| `postgres.password` / `postgres.existingSecret` + `existingSecretKey` | `""` / `""` + `password` | one of the two is required |
| `postgres.pool.maximumPoolSize`, `.minimumIdle` | `10`, `2` | Hikari, per replica |
| `elasticsearch.enabled`, `.url`, `.indexName` | `true`, `""`, `conductor` | `url` is required when enabled, unless `elasticsearch.cluster.enabled` |
| `elasticsearch.clusterHealthColor` | `yellow` | a single node never turns green |
| `elasticsearch.indexReplicasCount` | unset | set `0` on a single node; required, and at most `replicas - 1`, with `elasticsearch.cluster.enabled` |
| `elasticsearch.cluster.enabled` | `false` | runs Elasticsearch from this chart, see below |
| `elasticsearch.cluster.name`, `.replicas`, `.clusterDomain` | `conductor-elasticsearch`, `3`, `cluster.local` | `replicas` is 1 or an odd number from 3 |
| `elasticsearch.cluster.image.repository`, `.tag`, `.pullPolicy` | `docker.io/library/elasticsearch`, `7.17.26`, `IfNotPresent` | keep it 7.17 |
| `elasticsearch.cluster.imagePullSecrets` | `[]` | |
| `elasticsearch.cluster.heapSize`, `.javaOpts` | `512m`, `""` | `-Xms` and `-Xmx` are both `heapSize`; `javaOpts` is appended |
| `elasticsearch.cluster.resources` | 200m CPU / 1Gi requests, 1536Mi memory limit | |
| `elasticsearch.cluster.persistence.storageClass`, `.size` | `""`, `30Gi` | an empty class is the cluster default |
| `elasticsearch.cluster.antiAffinity` | `hard` | `hard`, `soft` or `none`: one Elasticsearch pod per node, by `kubernetes.io/hostname` |
| `elasticsearch.cluster.pdb.enabled`, `.minAvailable` | `true`, `2` | drawn only with three or more replicas; `minAvailable` is at most `replicas - 1` |
| `elasticsearch.cluster.joinSeedHosts` | `[]` | not empty: the nodes only join an existing cluster, see below |
| `elasticsearch.cluster.allowMmap` | `false` | see below |
| `elasticsearch.cluster.extraConfig`, `.extraEnv` | `{}`, `[]` | `extraConfig` keys become environment variables of the same name, for example `indices.query.bool.max_clause_count` |
| `elasticsearch.cluster.nodeSelector`, `.tolerations`, `.podAnnotations`, `.podLabels` | empty | |
| `elasticsearch.cluster.terminationGracePeriodSeconds` | `120` | |
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
