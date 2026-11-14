# tuwunel

A Helm chart for [Tuwunel](https://github.com/matrix-construct/tuwunel), a
Matrix homeserver written in Rust. It replaces Synapse: one Tuwunel process
with its database on a persistent volume, reached through a Service and, if
you turn it on, an Ingress or a Gateway API route.

## Limitations

- **Exactly one instance.** `replicaCount` is 0 or 1 and the chart refuses
  anything above that. Tuwunel keeps its database in RocksDB on one volume, and
  a second process on that database is not supported.
- **No high availability.** If the node goes down, the server is down until the
  pod is rescheduled and its volume is attached again.
- **No database persistence with `persistence.enabled=false`.** The database
  then lives in an `emptyDir` and is lost when the pod is recreated.
- **The database outlives the release.** It lives on a PersistentVolumeClaim
  named `<fullname>-data` with `helm.sh/resource-policy: keep`, so
  `helm uninstall` leaves it in place. Delete the claim by hand when you mean it.
  To install again on the same database, set `persistence.existingClaim: <fullname>-data`.

## Requirements

- Kubernetes 1.25 or newer.
- A `ReadWriteOnce` storage class on block storage (Ceph RBD and the like).
  Do not use NFS: RocksDB needs locking and fsync guarantees that NFS does not
  give.

## Install

```console
helm repo add globalart https://globalartinc.github.io/helm-charts
helm install tuwunel globalart/tuwunel --set serverName=example.org
```

`serverName` is required. It is the domain in every Matrix ID on the server
(`@user:example.org`), and it becomes part of the data, so choose it before the
first start.

## Values

| Key | Default | Description |
|---|---|---|
| `serverName` | `""` | Required. Domain part of every Matrix ID on this server. |
| `image.repository` | `ghcr.io/matrix-construct/tuwunel` | Tuwunel image. |
| `image.tag` | `v2.0.0` | Image tag. Ignored when `image.digest` is set. |
| `image.digest` | `""` | Image digest, used instead of the tag when set. Production sets it. |
| `replicaCount` | `1` | 0 or 1. |
| `config` | `{}` | Settings under `[global]` in `tuwunel.toml`, as a nested map. |
| `extraConfigToml` | `""` | Raw TOML appended to `tuwunel.toml`. |
| `appservices.existingSecret` | `""` | Secret with appservice registration files (`*.yaml`). |
| `appservices.registrations` | `{}` | Registrations kept in values; the chart makes a Secret from them. |
| `persistence.enabled` | `true` | Create the data PersistentVolumeClaim. |
| `persistence.existingClaim` | `""` | Use an existing claim instead of `<fullname>-data`. Ignored when `persistence.enabled` is false. |
| `persistence.storageClass` | `""` | Storage class. Empty means the cluster default. |
| `persistence.size` | `20Gi` | Size of the data claim. |
| `persistence.accessModes` | `[ReadWriteOnce]` | Access modes of the data claim. |
| `warmCache.enabled` | `false` | Read the SST files in the background right after the container starts, to fill the OS page cache. |
| `warmCache.path` | `""` | Directory that `warmCache` reads. Empty means `/var/lib/tuwunel`. |
| `media.s3.enabled` | `false` | Store media in an S3-compatible bucket. |
| `media.s3.existingSecret` | `""` | Secret with the S3 access and secret keys. |
| `service.type` | `ClusterIP` | Service type. |
| `service.port` | `8008` | Service port. The container listens on the same port, and the port is named `http`. |
| `resources` | `requests: 500m / 1Gi`, `limits: 3Gi` memory | Container resources. No CPU limit by default. |
| `terminationGracePeriodSeconds` | `600` | Time the server gets to shut down cleanly. |
| `enableServiceLinks` | `false` | Keep Kubernetes from injecting `TUWUNEL_*` variables for a Service named like the release: Tuwunel reads them as config and fails to start. |
| `automountServiceAccountToken` | `false` | The server does not use the Kubernetes API. |
| `image.pullPolicy`, `imagePullSecrets` | `IfNotPresent`, `[]` | Image pull settings. |
| `probes.<name>.timeoutSeconds` | `15` | Timeout of the startup, liveness and readiness probes (`tuwunel --health-check`). |
| `ingress.enabled` | `false` | Publish through an Ingress. |
| `route.enabled` | `false` | Publish through a Gateway API HTTPRoute. Cannot be combined with `ingress.enabled`. |
| `import.enabled` | `false` | Run the Synapse import Job. Requires `replicaCount: 0`. |
| `backup.enabled` | `false` | Run the backup sidecar. Must be off while `import.enabled` is on. |
| `backup.retrySeconds` | `900` | Pause before the next attempt after a failed or skipped round. |
| `backup.waitSeconds` | `1800` | How long a round waits for the new backup to appear in the repository after the signal. |
| `backup.startupWaitSeconds` | `1800` | How long the sidecar polls the server (`/_matrix/client/versions` on `service.port`) before the first round. If the server never answers, that round is skipped. |
| `import.scratch.enabled` | `true` | Write the import database to an `emptyDir` and copy it to the volume after a successful import. See "Where the database is written". |
| `import.scratch.sizeLimit` | `8Gi` | `sizeLimit` of that `emptyDir`. The node needs this much free disk. |
| `import.scratch.medium` | `""` | Medium of that `emptyDir`: empty is the node's disk, `Memory` is allowed. |
| `import.prepare.resources` | `requests: 50m / 64Mi`, `limits: 128Mi` memory | Resources of the `prepare` init container of the import Job. |
| `monitoring.probe.enabled` | `false` | Create a blackbox Probe. |
| `monitoring.prometheusRule.enabled` | `false` | Create a PrometheusRule. |
| `nodeSelector`, `tolerations`, `affinity` | `{}`, `[]`, `{}` | Scheduling. |
| `podAnnotations`, `podLabels` | `{}` | Extra pod metadata. |
| `nameOverride`, `fullnameOverride` | `""` | Name of the resources. |

## Configuration

The chart writes `tuwunel.toml` into a Secret named `<fullname>-config` and
mounts it at `/etc/tuwunel/tuwunel.toml`. Everything in the file sits under
`[global]`.

The chart sets these keys itself: `server_name` from `serverName`,
`database_path` as `/var/lib/tuwunel`, the listener on `0.0.0.0:<service.port>`,
`appservice_dir` when appservice registrations are set, and the S3 storage
provider when `media.s3.enabled` is on. Non-empty chart values win over config;
an empty or false chart value does not override config.

`config` is a nested map with the other settings. Tuwunel silently ignores keys
it does not know, so a typo in `config` produces no error. Check the pod log
after a change.

`extraConfigToml` is appended to the file as it is, for anything `config` cannot
express. It is glued to the end of the file, so it must start with its table
header (for example `[global.http]`); otherwise its keys land in the last table.
Do not repeat a table that `config` already sets: the TOML parser rejects the
duplicate.

Helm passes every number as a float, so the chart writes whole numbers from
`config` as plain integers. Numbers from 1000000 up are rendered in exponent
form, and the chart refuses to render them. Set the whole table through
`extraConfigToml`, starting it with its `[global...]` header, and remove that
table from `config`. Numbers inside arrays are not normalized: a whole number in an array is written
as a float (`[1.0, 2.5]`). Write arrays of integers through `extraConfigToml`.

The S3 access and secret keys reach the pod as environment variables from the
Secret named in `media.s3.existingSecret`. They never go through the config file.

Appservice registrations come from `appservices.existingSecret` or from
`appservices.registrations`, and are mounted in `/etc/tuwunel/appservices`. Set
one of the two, not both.

The pod carries a checksum of the config and registration Secrets, so a change
to either restarts the pod. The checksum covers only the Secrets the chart
creates. With `appservices.existingSecret`, the content of that Secret is not
in the checksum: after you change it, restart the pod by hand with
`kubectl rollout restart statefulset/<fullname>`.

`warmCache.enabled` starts a background `cat` of the SST files in the data directory right after the container starts, so that they are in the OS page cache before the first sync. On a network volume, use it together with `config.rocksdb.direct_io: false` and `config.rocksdb.cache_capacity_mb`.

## Exposing the server

Publish the server through an Ingress or a Gateway API route, not both. The
chart refuses to render both.

**Ingress** serves the paths `/_matrix` and `/_synapse/admin` on `ingress.host`.
Add more paths with `ingress.extraPaths`. Each entry is a map with `path` and
`pathType` (default `Prefix`), and optionally `service` (a Service name in this
namespace, default: this chart's Service) and `port` (default: `service.port`).

`ingress.blockedPaths` is a list of regular expressions. The controller answers
those paths with 503 and never sends them to the server. Each expression gets
its own Ingress with the `nginx.ingress.kubernetes.io/use-regex` annotation, and
that annotation applies to every path on the host. Anchor each expression with
`^` and `$`. An invalid expression breaks the reload of the whole controller,
not only this host, so check `nginx -T` in a rehearsal before you apply it.

**Gateway API** needs `route.host`. Without `route.listenerSet.attachTo` it also
needs `route.gateway.name` and `route.gateway.namespace`, which name the Gateway
the route attaches to.

`route.listenerSet.attachTo` names an existing ListenerSet to attach the
HTTPRoute to, instead of the Gateway. The chart then creates no ListenerSet of
its own.

`route.tls.secretName` names the TLS Secret for the host. With
`route.tls.certificate.enabled`, the chart orders a certificate from the
ClusterIssuer named in `route.tls.certificate.issuer` (default `letsencrypt`),
and the Secret defaults to `tls-<fullname>`. Without it, the Secret must already
exist.

## Import from Synapse

`import.enabled` creates a one-off Job, `<fullname>-import`, that moves a stopped Synapse into the
Tuwunel database on the chart's volume. The Job reads Synapse's PostgreSQL database and never writes
to it. It is a plain Job, not a Helm hook: Helm does not wait for it and does not delete it.

The importer is not in upstream Tuwunel. It is a fork of Tuwunel 1.9.4 with the `--import-synapse`
flag, published as `ghcr.io/globalartinc/tuwunel-synapse-import`. There is no default version: set
`import.image.tag` or `import.image.digest` (the digest wins when both are set).

### Before you start

- Stop Synapse and all of its workers, and everything else that holds a connection to the Synapse
  database, the PostgreSQL metrics exporter included. The importer refuses to start while anything else
  is connected to the Synapse database, and its preflight fails.
- On production data, `import.media.fromS3` is required. Synapse's media is not on the volume, so
  without it the imported database would point at files that were never copied.
- The Tuwunel database must be empty: no earlier start of the server on this volume.
- `persistence.enabled` must be on. The Job mounts the same volume as the server.
- Create these Secrets in the release namespace. Their values never go through `values.yaml`:

| Secret | Value |
|---|---|
| `import.synapseDb.existingSecret`, key `import.synapseDb.key` (default `uri`) | Synapse database URL, `postgresql://user:password@host/dbname`. Reaches the Job as `TUWUNEL_SYNAPSE_DB`. |
| `import.signingKey.existingSecret`, key `import.signingKey.key` (default `signing.key`) | Synapse signing key (`ed25519 <id> <key>`). Mounted as a file with mode 0400 and, because `fsGroup` is set, 0440: group 1000 can read it. |
| `import.bcryptPepper.existingSecret`, key `import.bcryptPepper.key` (default `pepper`) | Synapse `password_config.pepper`, only if Synapse had one. Reaches the Job as `TUWUNEL_IMPORTED_BCRYPT_PEPPER` and, for the `prepare` init container, as `BCRYPT_PEPPER`. A single line without line breaks. |
| `import.media.fromS3.existingSecret`, keys `access-key` and `secret-key` | Credentials for the bucket with Synapse's media, only with `import.media.fromS3.enabled`. |

With `media.s3.enabled`, the Job writes the imported media straight to the same bucket the server uses,
with the same provider name, bucket and `basePath`, and takes the keys from `media.s3.existingSecret`.

### Run

```sh
helm upgrade --install tuwunel charts/tuwunel -f values.yaml \
  --set replicaCount=0 --set import.enabled=true
kubectl logs -f job/<fullname>-import -c import
```

`replicaCount` must be 0 while `import.enabled` is on: the server and the Job cannot share the
database. The chart refuses to render otherwise.

Synapse's media is not on the volume. With `import.media.fromS3.enabled`, an init container (`rclone`)
copies `local_content/` from the bucket `import.media.fromS3.bucket`, under the optional
`import.media.fromS3.prefix`, into an `emptyDir` of `import.media.emptyDirSizeLimit`, and the importer
reads the files from there. Synapse's `url_cache` previews are not imported. With `import.media.fromS3.fixCase` (on by default), the init container also links every case variant of the first directory level of each key to its file, because Synapse could have stored media on storage that ignored the case of directory names.

The import config is a Secret, `<fullname>-import`. It holds no credentials. Its `homeserver.yaml` has
`app_service_config_files: []` on purpose: appservice registrations come from `appservices.*` when the
server starts, and registering them in the import as well would be a duplicate.

An init container, `prepare`, runs first, from the same image and with the same security context as the
importer. It creates `/var/lib/tuwunel/import/`, where the importer writes its reports and which the
importer does not create itself, and it builds the `homeserver.yaml` the importer reads, `/work/homeserver.yaml`
in an `emptyDir`. The file is a copy of the one in the Secret. The importer's preflight compares
`imported_bcrypt_pepper` with the `password_config.pepper` of that file, so with
`import.bcryptPepper.existingSecret` set, `prepare` appends `password_config:` with the pepper (a YAML
single-quoted string, quotes doubled). The pepper reaches `prepare` through `secretKeyRef` only: it is
not in the arguments of any container and not in the chart's Secret, and `prepare` stops with an error if
it is empty or contains a line break. The `fetch-media` init container, when there is one, runs after `prepare`.

The Job runs once (`backoffLimit: 0`) and stops after `import.activeDeadlineSeconds`. A Job cannot be
changed or restarted in place, so a finished Job is not run again by `helm upgrade`, and an upgrade
that changes its spec fails. To run it again, delete it first:

```sh
kubectl delete job <fullname>-import
```

If the import stopped partway (a crash, a full disk), fix the cause, delete the Job and run it again.
With scratch (the default) the run starts from the beginning. With `import.scratch.enabled: false` you can
continue with `--set 'import.extraArgs={--import-resume}'`. The importer reruns the first unfinished phase and
continues from there. Further flags go through `import.extraArgs` too.

### Where the database is written

By default (`import.scratch.enabled: true`) the importer does not write RocksDB to the volume. The Job
mounts an `emptyDir`, `db-scratch`, at `/scratch` in the `import` container and `import.toml` points
`database_path` at `/scratch/db`. When the import has finished, the container copies the database to the
volume. Writing RocksDB to a network volume is slow: on Ceph RBD an import took 41 minutes (35 of them
in the rooms phase, with `Database Stall Recovered` in the log), and 4.3 minutes on a local disk. The
finished database was 688 MB, so the copy takes seconds. The reports stay on the volume, in
`/var/lib/tuwunel/import/`, as before.

- `import.scratch.sizeLimit` (default `8Gi`) caps the `emptyDir`, and the node must have that much free
  disk. If the database outgrows the limit, the pod is evicted. `import.scratch.medium: Memory` puts the
  `emptyDir` in RAM; it then counts against the memory limit of the container (`import.resources`).
- The `import` container runs a short shell script around the importer. It passes the importer the same
  arguments as without scratch, writes the importer's output to `/scratch/import.log` and to the
  container log, and takes the importer's exit code. The pepper and the database URL stay in the
  environment: the script does not print them and does not pass them as arguments.
- The script does not start if `/var/lib/tuwunel/CURRENT` exists, that is, if the volume already holds a
  database. It prints a message and exits with code 1. The import never overwrites a database.
- If the log has the line `Synapse import finished`, the import went to the end and the script copies
  `/scratch/db` to the volume with `cp -a`, then compares the number of files in `/scratch/db` and in the
  copy. The verification (`import.verify`) can make the importer exit with code 1 because of known
  differences, and the database is copied all the same. If the copy fails or the numbers differ, the
  script exits with code 1; the volume may then hold a partial database, and it must be emptied before a
  retry (the `CURRENT` check would refuse the retry).
- If the line is not there (the importer crashed, ran out of time or of disk), nothing is copied and the
  volume is not touched. A retry is safe.
- The Job exits with the importer's exit code, or with 1 if the copy failed.

The script prints these lines; look for them in `kubectl logs job/<fullname>-import -c import`:

| Line | Meaning |
|---|---|
| `import exit code: N` | The exit code of the importer. |
| `copied N files to the volume` | The import finished, the database is on the volume, the file counts match. |
| `volume left untouched: ...` | The import did not finish. Nothing was copied. |
| `import: /var/lib/tuwunel already holds a database ...` | The `CURRENT` check refused to start the importer. |

`--import-resume` does not work with scratch: the `emptyDir` is gone with the pod, so a retry starts from
the beginning. Use `import.scratch.enabled: false` to write to the volume directly, as in earlier
versions of the chart; then the script is not used and `--import-resume` works as described above.

### Reading the result

The importer writes `report.json` (what was imported, and the `skipped` list of what stays behind) and,
with `import.verify` (default), `verify.json` and `verify.txt` into `/var/lib/tuwunel/import/` on the
volume. The verification compares Synapse's database with the new one.

With `replicaCount: 0` there is no server pod, and the Job pod has finished, so `kubectl exec` and
`kubectl cp` have nothing to connect to. Read the files with a temporary pod that mounts the same
volume. It runs as user 1000, because the directory is created with mode 0700:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: tuwunel-import-reports
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  containers:
    - name: cat
      image: docker.io/rclone/rclone:1.75.2
      command: ["sleep", "3600"]
      volumeMounts:
        - {name: data, mountPath: /var/lib/tuwunel, readOnly: true}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: <fullname>-data, readOnly: true}
```

```sh
kubectl apply -f reports-pod.yaml
kubectl wait --for=condition=Ready pod/tuwunel-import-reports
kubectl exec tuwunel-import-reports -- cat /var/lib/tuwunel/import/report.json
kubectl exec tuwunel-import-reports -- cat /var/lib/tuwunel/import/verify.json
kubectl delete pod tuwunel-import-reports
```

The volume is `ReadWriteOnce`: start this pod only while no other pod uses it.

The importer skips media files it cannot read without saying so. Compare the number of media files
in `report.json` with the number of rows Synapse has for local media, and look at any gap:

```sql
SELECT count(*) FROM local_media_repository WHERE url_cache IS NULL;
```

`url_cache IS NULL` leaves out the cached URL previews, which are not imported.

To check again later, run `tuwunel --import-verify-only` by hand in a debug pod. The flag conflicts with
`--import-report`, so the chart does not support it: no value turns it on. Take the Job's pod spec
(`kubectl get job <fullname>-import -o yaml`), keep the init containers, volumes and environment, give
the Job another name, and replace the arguments of the `import` container with
`-c /etc/tuwunel-import/import.toml --import-synapse /work/homeserver.yaml --import-verify-only`.
The Synapse database must be reachable and nothing else may be connected to it, as for the import.

On production data the verification is known to report differences that are not data loss: old events,
events larger than 64 KiB, and extra state entries in empty rooms. Because of them the Job can end with
exit code 1 although the data has been moved. Do not treat the exit code as the verdict. Read the Job
log and `verify.json`, and decide by hand whether every mismatch is one of the known ones.

### After a successful import

Turn the import off and start the server:

```sh
helm upgrade tuwunel charts/tuwunel -f values.yaml \
  --set import.enabled=false --set replicaCount=1
```

This removes the Job. Keep `report.json` and `verify.json` first if you need them. Keep Synapse's
database until you are satisfied: going back means starting Synapse on it again, and anything sent to
Tuwunel in between is lost to it.

### The server image after the import

After the import, the server that runs on the volume must be built with bcrypt
support. Synapse keeps passwords as bcrypt hashes and the import carries them
over unchanged, but upstream `ghcr.io/matrix-construct/tuwunel:v2.0.0` has no
bcrypt check, so imported users cannot log in with their passwords on it. Set
the image to the build with bcrypt, `ghcr.io/globalartinc/tuwunel`, with a tag of
the form `2.0.0-bcrypt-<sha7>` (`<sha7>` is the first seven characters of the
commit it was built from):

```yaml
image:
  repository: ghcr.io/globalartinc/tuwunel
  tag: 2.0.0-bcrypt-420d753
```

If Synapse had a `password_config.pepper`, the runtime server needs the same
pepper, or no imported password will match. Pass it through `extraEnv` from the
Secret, not through `values.yaml`:

```yaml
extraEnv:
  - name: TUWUNEL_AUTHENTICATION__IMPORTED_BCRYPT_PEPPER
    valueFrom:
      secretKeyRef:
        name: synapse-pepper
        key: pepper
```

The variable name is to be confirmed: check it against the built image before
you rely on it. A Synapse without a pepper needs none of this.

## Backup and restore

The database is the only copy of every message, and the chart has no high
availability, so turn the backup on before the server takes real traffic.

### How it works

With `backup.enabled=true` the chart does three things:

1. It turns on the managed online backups of Tuwunel 2.0 in `tuwunel.toml`:
   `database.backup.path` (`backup.path`, by default `/var/lib/tuwunel/backup`
   inside the data volume), `database.backup.keep` (`backup.keep`, 7) and
   `admin.signal_execute = ["server backup-database"]`. These are RocksDB
   incremental backups: the repository holds `meta/`, `private/` and
   `shared_checksum/`, and only new files are written on each run. The chart
   sets these keys itself, and they win over the same keys in `config`.
2. It adds a `backup` sidecar (rclone image) to the pod and sets
   `shareProcessNamespace: true`, so the sidecar can see the server process. It
   runs as the same user as the server.
3. The sidecar first polls the server (`/_matrix/client/versions` on
   `service.port`, over the pod's shared network) for up to
   `backup.startupWaitSeconds`, then waits `backup.initialDelaySeconds`. If the
   server never answered, it skips the first round and logs it. Then every
   `backup.intervalSeconds` it runs a round. A round compares the newest backup
   number in the local repository (`meta/`) with the newest one in the bucket
   before it does anything to the server or to the bucket. A missing remote
   directory counts as empty. Any other failure to list the bucket fails the
   round, and nothing is written:
   - the bucket is ahead (it has a backup, and the local repository has none or
     a lower number): the round fails with `remote repository is ahead of the
     local one, refusing to create or upload backups`. The sidecar sends no
     signal, uploads nothing and deletes nothing. This is what a lost or
     recreated empty volume, or a second server with the same bucket and prefix,
     looks like. The round fails again on every retry until an operator fixes
     the cause (see "Lost or recreated volume");
   - the local repository has a backup that is not in the bucket yet (an earlier
     upload failed, or the server made a backup by other means): the sidecar
     sends no signal and uploads that backup;
   - both have the same newest number, or both are empty: everything is
     uploaded already, so the sidecar sends `SIGUSR2` to the server, which runs
     `server backup-database`, and waits up to `backup.waitSeconds` for the new
     file in `meta/`. A backup is finished when that file appears, because
     RocksDB writes it last.

   The upload of that backup:
   - runs `rclone copy` of `shared_checksum/` and `private/`, then of `meta/`,
     to `s3://<bucket>/<prefix>/db/`, so a `meta/N` is never in the bucket
     before its files;
   - checks that the `meta/` file is in the bucket;
   - removes what the server has already dropped (`backup.keep`) with one
     `rclone sync --delete-after` over the three directories.

   Every write uses `rclone --immutable`. The files of a RocksDB backup never
   change, so rclone refuses to replace one that exists with different content,
   exits with an error and deletes nothing. A backup with the same number but
   other content, for example from a different database, fails the round that
   way. The sidecar mounts the data volume read-only.

   Only after all of that does it update
   `tuwunel_backup_last_success_timestamp_seconds`. A failed round is logged
   and leaves that metric as it was, so an old value means no good copy since
   then. The sidecar tries again after `backup.retrySeconds` (900 by default)
   instead of the full interval. `tuwunel_backup_last_attempt_timestamp_seconds`
   moves on every round.

Media is not in the backup. Backups hold the database only. Media lives in the
S3 provider of `media.s3`, and that bucket is the owner of those files. Keep it
safe separately (versioning, a copy in another place).

When the server removes old backups (`backup.keep`), the cleanup removes them
from S3 as well. Versioning or object lock on the backup bucket is required in
production, not optional: the sidecar's protections (`--immutable`, the check of
the backup numbers) stop mistakes, and the bucket must stop everything else: a
bug, a wrong command or a stolen key. The sidecar does not upload when the local
repository does not contain the newest backup that is already in S3, because
the sync would delete the remote history.

The S3 keys come from `backup.s3.existingSecret` (keys `access-key` and
`secret-key`) and reach the sidecar as environment variables only. The pod
shares one process namespace, and the server and the sidecar run as the same
user, so a process in the server container can read the environment of the
sidecar and with it the S3 keys. Give that key the minimum: read, write and list
in its own bucket, and nothing in other buckets or on the account.

```yaml
backup:
  enabled: true
  keep: 7
  intervalSeconds: 86400
  s3:
    endpoint: https://s3.example.org
    bucket: matrix-tuwunel-backup
    prefix: prod
    existingSecret: tuwunel-backup-s3
```

The chart refuses to render when the S3 endpoint, bucket or Secret is missing,
when `persistence.enabled` is off, when `replicaCount` is 0, or when
`backup.path` is not under `/var/lib/tuwunel/`.

The repository needs space on the data volume next to the database: the first
backup is a full copy, the next ones add only new files. Size the volume for
that.

### Check that it works

```console
kubectl logs <pod> -c backup
kubectl exec <pod> -c backup -- wget -qO- localhost:9101/metrics
```

The log has one `backup N is in DEST:...` line per good round and a `FAILED:`
line with the reason for a bad one. The metrics endpoint answers from the
start, but the success line appears only after the first good backup. The
metric lives in an `emptyDir`, so it is lost when the pod is recreated, and it
is absent again until the first good backup: after a restart that takes up to
`backup.startupWaitSeconds` plus `backup.initialDelaySeconds` plus the time of
the round. Alert on `time() - tuwunel_backup_last_success_timestamp_seconds`
and on `absent(tuwunel_backup_last_success_timestamp_seconds)`, with a `for:`
longer than that.

The server log (`kubectl logs <pod> -c tuwunel`) shows `Created database backup`
for each backup. In the admin room, `!admin server list-backups` lists the
backups and `!admin server verify-backup` checks the newest one.

### Lost or recreated volume

If the data volume is lost and a new, empty one takes its place, the new server
starts with no backups while the bucket still holds the old history. The sidecar
sees that the bucket is ahead, fails every round with `remote repository is
ahead of the local one, refusing to create or upload backups`, and does not
create a backup, upload or delete anything. The metric
`tuwunel_backup_last_success_timestamp_seconds` stops moving. That is expected
and safe: the old history in the bucket stays as it is for as long as you take.
The chart never deletes the remote repository by itself, and you should not do it
to make the message go away.

Decide first, and do one of two things:

- Restore the data from the bucket (see "Restore" below). The volume then holds
  the newest backup, the numbers match, and the sidecar carries on.
- Start a new history on purpose: set a different `backup.s3.prefix` (for
  example `prod-2`). The old prefix stays in the bucket untouched. Remove it by
  hand later, when you no longer need it.

A second server pointed at the same bucket and prefix gets the same refusal
until it has its own prefix.

### Restore

This replaces the database with the contents of a backup. Everything written
after that backup is lost. Take a snapshot of the volume first if the current
database is still readable.

1. Stop the server. Scale the StatefulSet by hand, because the chart refuses
   `replicaCount: 0` while the backup is on, and wait until the pod is gone
   (the volume is `ReadWriteOnce`):

   ```console
   kubectl scale statefulset/<fullname> --replicas=0
   kubectl wait --for=delete pod/<fullname>-0 --timeout=15m
   ```

2. Copy the repository from S3 onto the volume with a one-off pod. It uses the
   same user as the server and the same Secret with the S3 keys:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: tuwunel-restore-fetch
   spec:
     restartPolicy: Never
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       runAsGroup: 1000
       fsGroup: 1000
     containers:
       - name: rclone
         image: docker.io/rclone/rclone:1.75.2
         command: ["rclone", "sync", "DEST:<bucket>/<prefix>/db/", "/var/lib/tuwunel/backup", "--checksum", "--transfers", "8"]
         env:
           - {name: HOME, value: /tmp}
           - {name: RCLONE_CONFIG_DEST_TYPE, value: s3}
           - {name: RCLONE_CONFIG_DEST_PROVIDER, value: Other}
           - {name: RCLONE_CONFIG_DEST_ENDPOINT, value: "<endpoint>"}
           - {name: RCLONE_CONFIG_DEST_NO_CHECK_BUCKET, value: "true"}
           - name: RCLONE_CONFIG_DEST_ACCESS_KEY_ID
             valueFrom: {secretKeyRef: {name: <existingSecret>, key: access-key}}
           - name: RCLONE_CONFIG_DEST_SECRET_ACCESS_KEY
             valueFrom: {secretKeyRef: {name: <existingSecret>, key: secret-key}}
         volumeMounts:
           - {name: data, mountPath: /var/lib/tuwunel}
           - {name: tmp, mountPath: /tmp}
     volumes:
       - name: data
         persistentVolumeClaim: {claimName: <fullname>-data}
       - name: tmp
         emptyDir: {}
   ```

   Wait for `Succeeded` (`kubectl logs`, then `kubectl delete pod`). With an
   empty `backup.s3.prefix` the repository is at `DEST:<bucket>/db/`: write the
   source in the command as that, not as `DEST:<bucket>//db/`, which is a
   different path.

3. Restore the database with a one-off pod of the server image. It reads the
   same config Secret (`<fullname>-config`) and the same volume. Restore is
   selected only by the command line, never by the config file:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: tuwunel-restore
   spec:
     restartPolicy: Never
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       runAsGroup: 1000
       fsGroup: 1000
     containers:
       - name: tuwunel
         image: ghcr.io/matrix-construct/tuwunel:v2.0.0
         args: ["-c", "/etc/tuwunel/tuwunel.toml", "--restore-backup", "--maintenance", "--execute", "server shutdown"]
         env:
           - {name: TUWUNEL_CONFIG, value: /etc/tuwunel/tuwunel.toml}
         volumeMounts:
           - {name: data, mountPath: /var/lib/tuwunel}
           - {name: config, mountPath: /etc/tuwunel/tuwunel.toml, subPath: tuwunel.toml, readOnly: true}
           - {name: tmp, mountPath: /tmp}
     volumes:
       - name: data
         persistentVolumeClaim: {claimName: <fullname>-data}
       - name: config
         secret: {secretName: <fullname>-config}
       - name: tmp
         emptyDir: {}
   ```

   `--restore-backup` alone restores the newest backup. To pick one, put its
   ID from `list-backups` right after it (`"--restore-backup", "3"`). Maintenance
   mode keeps the process from serving clients, and `server shutdown` stops it
   when the restore is done. Read `kubectl logs tuwunel-restore` for
   `Restored database backup`, then delete the pod.

4. Start the server again and check it:

   ```console
   kubectl scale statefulset/<fullname> --replicas=1
   kubectl logs <fullname>-0 -c tuwunel
   ```

   The sidecar keeps adding backups to the same repository.

This procedure follows `docs/backups.md` of Tuwunel 2.0.0, which gives the
command `tuwunel --config ... --restore-backup --maintenance --execute "server
shutdown"`. Rehearse it on a copy before you need it. Three points the
documentation does not settle, so check them in the rehearsal:

- The repository sits inside `database_path`, and the restore writes into the
  same directory. The documentation does not say whether the restore leaves the
  other files and directories there alone. Look that `backup/` is still in the
  volume afterwards. If it is gone, fetch it from S3 again.
- If your config uses `appservices` or a media S3 provider, the one-off pod may
  need the same mounts and environment as the main container (the appservices
  Secret, the `TUWUNEL_STORAGE_PROVIDER__*` variables). Copy them from the
  StatefulSet if the server refuses to start in step 3.
- To restore without a running cluster, the documentation also has a manual
  recovery from the repository files (`shared_checksum/*.sst` renamed to
  `######.sst`, plus the files of one numbered backup).

## Monitoring

Documented together with the template that implements it.
