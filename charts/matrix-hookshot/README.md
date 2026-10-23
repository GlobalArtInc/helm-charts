# matrix-hookshot

[Hookshot](https://github.com/matrix-org/matrix-hookshot) as an application service next to a Synapse release in the same namespace. The upstream chart stopped at Hookshot 6.0.2; this one runs 7.x with a configuration written as values.

One Deployment and one Service with two ports: `9993`, the application service API Synapse pushes transactions to, and `9000`, the webhooks listener, published by an optional Ingress.

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
ingress:
  host: matrix.example.com
```

`config` is Hookshot's `config.yml` as is. Two things in it are tied to the chart: the files live in `/data` (`passFile: /data/passkey.pem`), and the listeners have to bind `0.0.0.0`, the ports above.

`passkey` is the key Hookshot encrypts stored service tokens with. Moving an existing bridge means moving its key, or the tokens it saved become unreadable.

The registration comes from an existing Secret, not from values: the same file has to reach Synapse, and [synapse-secrets](https://github.com/GlobalArtInc/helm-charts/tree/main/charts/synapse-secrets) keeps it in one Secret for both. Its `url` for Synapse is `http://<release>:9993`.

## Webhooks

Hookshot answers generic webhooks at `/webhook/<id>` on port `9000`, so `ingress.path` defaults to `/webhook` and `generic.urlPrefix` should end the same way. No rewrite is involved, which matters with ingress-nginx: a `rewrite-target` would enable regex paths for the whole host the homeserver shares.

The pod runs as a non-root user with a read-only root filesystem; `/tmp` is an emptyDir.
