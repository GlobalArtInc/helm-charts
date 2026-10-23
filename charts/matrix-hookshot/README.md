# matrix-hookshot

[Hookshot](https://github.com/matrix-org/matrix-hookshot) as an application service next to a Synapse release in the same namespace. The upstream chart stopped at Hookshot 6.0.2; this one runs 7.x with a configuration written as values.

One Deployment and one Service with two ports: `9993`, the application service API Synapse pushes transactions to, and `9000`, the webhooks listener, published through Gateway API or an Ingress.

## Values

```yaml
config:
  bridge:
    domain: example.com
    url: http://matrix-synapse:8008
    mediaUrl: https://matrix.example.com
    port: 9993
    bindAddress: 0.0.0.0
  passFile: /data/passkey.pem
  listeners:
    - port: 9000
      bindAddress: 0.0.0.0
      resources:
        - webhooks
  generic:
    enabled: true
    urlPrefix: https://matrix.example.com/webhook
    userIdPrefix: _webhooks_
passkey: |
  -----BEGIN PRIVATE KEY-----
  ...
registration:
  secretName: matrix-appservices
  key: hookshot.yaml
route:
  enabled: true
  host: matrix.example.com
```

`config` is Hookshot's `config.yml` as is. Two things in it are tied to the chart: the files live in `/data` (`passFile: /data/passkey.pem`), and the listeners have to bind `0.0.0.0`, the ports above.

`passkey` is the key Hookshot encrypts stored service tokens with. Moving an existing bridge means moving its key, or the tokens it saved become unreadable.

The registration comes from an existing Secret, not from values: the same file has to reach Synapse, and [synapse-secrets](https://github.com/GlobalArtInc/helm-charts/tree/main/charts/synapse-secrets) keeps it in one Secret for both. Its `url` for Synapse is `http://<release>:9993`.

## Webhooks

Hookshot answers generic webhooks at `/webhook/<id>` on port `9000`, so `path` defaults to `/webhook` and is published as is.

To publish the webhooks under other paths as well, list them in `extraPaths`; each is rewritten to `path` on the way in:

```yaml
extraPaths:
  - /hookshot/webhooks
config:
  generic:
    urlPrefix: https://matrix.example.com/hookshot/webhooks
```

`generic.urlPrefix` is the address Hookshot hands out for new webhooks; point it at whichever of the published paths the senders should use. The HTTPRoute rewrites with a `URLRewrite` filter (`ReplacePrefixMatch`). The Ingress gets a `rewrite` line per extra path in `nginx.ingress.kubernetes.io/configuration-snippet`, appended to a snippet already set in `ingress.annotations`; that is ingress-nginx only and needs snippet annotations allowed by the controller. It rewrites inside the locations of this Ingress and leaves the regex mode of the host alone, which `rewrite-target` would not.

## Publishing

Nothing is published by default. Gateway API and Ingress are alternatives; both may be on while moving between them. Either way only `path` (`/webhook`) on the host is published, so the chart sits next to the homeserver on the host the homeserver owns.

### Gateway API

An `HTTPRoute` for `path` (`/webhook`) on `route.host`. The listener of a shared host is not this chart's: the homeserver's release, or the gateway, already terminates TLS for it, and two ListenerSets with the same hostname on one gateway conflict. So by default the route joins a listener that exists.

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
--set route.host=hooks.example.com \
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

The pod runs as a non-root user with a read-only root filesystem; `/tmp` is an emptyDir.
