# synapse-admin

[Ketesa](https://github.com/etkecc/ketesa), the successor of the etke.cc synapse-admin, served under a path of the homeserver's own host (`https://matrix.example.com/synapse-admin/`), plus a hook that registers the homeserver's first admin user.

Resources are named after the release. `fullnameOverride` names them otherwise — for a subchart of an application chart, where the release name is the application's.

## UI

```yaml
config:
  restrictBaseUrl: https://matrix.example.com
route:
  enabled: true
  host: matrix.example.com
```

`config` becomes Ketesa's `config.json`; `restrictBaseUrl` pins the UI to this homeserver.

The image serves the UI from its web root. An init container copies it into a directory named after `path` on an emptyDir, and static-web-server serves that, so neither the route nor the Ingress rewrites paths. static-web-server redirects `/synapse-admin` to `/synapse-admin/`, which the UI's relative asset paths need.

The server listens on `0.0.0.0`. Its default, `[::]`, fails on nodes without IPv6 with "Address family not supported by protocol".

## Publishing

Nothing is published by default. Gateway API and Ingress are alternatives; both may be on while moving between them. Either way only `path` (`/synapse-admin`) on the host is published, so the chart sits next to the homeserver on the host the homeserver owns.

### Gateway API

An `HTTPRoute` for `path` (`/synapse-admin`) on `route.host`. The listener of a shared host is not this chart's: the homeserver's release, or the gateway, already terminates TLS for it, and two ListenerSets with the same hostname on one gateway conflict. So by default the route joins a listener that exists.

Join the gateway's own listener:

```console
--set route.enabled=true \
--set route.host=matrix.example.com \
--set route.gateway.name=moscow-gateway \
--set route.gateway.namespace=envoy-gateway-system \
--set route.gateway.sectionName=https
```

`route.gateway.sectionName` is optional; without it the route is offered to every listener of the gateway that matches the host.

Join the ListenerSet another release made for the host, in this namespace:

```console
--set route.enabled=true \
--set route.host=matrix.example.com \
--set route.listenerSet.attachTo=matrix-synapse-listeners
```

The route takes the `https` section of that ListenerSet, or `route.gateway.sectionName` when it is set.

On a host of its own, the chart makes the listener itself, in the house shape of `conductor` and `mediacore`: a `ListenerSet` on the gateway and the route on it.

```console
--set route.enabled=true \
--set route.host=admin.example.com \
--set route.listenerSet.enabled=true \
--set route.tls.secretName=wildcard-example-com
```

- `route.tls.secretNamespace` names the namespace of a certificate that lives elsewhere. A `ReferenceGrant` in that namespace is not this chart's to create.
- `route.tls.certificate.enabled=true` orders a `Certificate` from the `route.tls.certificate.issuer` ClusterIssuer, for a name no wildcard covers.
- `route.tls.referenceGrant.enabled` (default `true`) lets the gateway read the Secret in this namespace.

`route.listenerSet.enabled` and `route.listenerSet.attachTo` exclude each other.

### Ingress

```console
--set ingress.enabled=true \
--set ingress.host=matrix.example.com
```

`ingress.host` falls back to `route.host`; `ingress.className` defaults to `nginx`, and `ingress.tls.secretName` adds a TLS section when the controller does not terminate TLS with a default certificate. The path is a plain `Prefix`: a `rewrite-target` would turn on regex matching for every path of the host with ingress-nginx, the homeserver's `/_matrix` included.

## Admin API

The UI talks to the homeserver's admin API, `/_synapse/admin`, from the browser. Where the homeserver itself is published to everyone, that API should not be: the old way is to publish the client API openly and let only the admins' networks reach `/_synapse/admin`. With `adminApi.enabled` this chart publishes `/_synapse/admin` of the homeserver next to the UI, under the same route or Ingress and so under the same restrictions:

```yaml
adminApi:
  enabled: true
  service:
    name: matrix-synapse
    port: 8008
```

The homeserver's own route or Ingress may keep a broader `/_synapse` or `/` path: the longer `/_synapse/admin` prefix wins in both ingress-nginx and Gateway API. With ingress-nginx, open the homeserver's Ingress (`nginx.ingress.kubernetes.io/whitelist-source-range: 0.0.0.0/0`) and leave this one on the controller's default allow-list, or set the allow-list here in `ingress.annotations`.

## First admin user

```yaml
admin:
  username: infra-admin
  password: ...
  synapseUrl: http://matrix-synapse:8008
  synapseConfigSecret: matrix-synapse
```

A `post-install,post-upgrade` hook runs `register_new_matrix_user` from the Synapse image against `synapseUrl`. It reads `registration_shared_secret` from the Synapse configuration in `synapseConfigSecret` (key `synapseConfigSecretKey`, `config.yaml` by default, which is where ananace/matrix-synapse keeps it). "User ID already taken" counts as success, so the hook runs on every upgrade and recreates the user if the database is replaced, without touching an existing one: a password changed in the UI stays changed.

Pick a username the server does not already use for something else. When the hook finds the name taken it does nothing, and the password in these values will not open that account.

Leave `admin.username` empty to skip the hook.
