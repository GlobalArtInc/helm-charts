# synapse-secrets

The two things a [Synapse](https://github.com/element-hq/synapse) homeserver keeps outside its database and that a chart for Synapse itself does not manage well: the server's signing key and the registrations of its application services. It renders Secrets only; mount them into the Synapse release.

## Signing key

```yaml
signingKey:
  secretName: matrix-signing-key
  value: "ed25519 a_AbCd <base64 seed>"
```

The Secret holds one key, `signing.key`, in the format Synapse writes to its key file. It carries `helm.sh/resource-policy: keep`: deleting the release leaves it in place, because a server that loses its key is a new server to every client and every other homeserver. Remove it by hand if that is the intent.

Moving a homeserver to Kubernetes means carrying its existing key over, not letting a job generate a new one. With [ananace/matrix-synapse](https://gitlab.com/ananace/charts):

```yaml
signingkey:
  job:
    enabled: false
  existingSecret: matrix-signing-key
  existingSecretKey: signing.key
```

## Application services

```yaml
appservices:
  secretName: matrix-appservices
  registrations:
    hookshot:
      id: matrix-hookshot
      url: http://matrix-hookshot:9993
      as_token: ...
      hs_token: ...
      sender_localpart: hookshot
      namespaces:
        users:
          - regex: '@_webhooks_.*:example\.com'
            exclusive: true
```

Every entry becomes `<name>.yaml` in one Secret, written as Synapse reads a registration file. A `url: null` registration is valid: Synapse accepts the service's tokens and sends it nothing, which is how a copy of a live server can run without pushing events to the bridges of the original.

Mount the Secret and list the files; with ananace/matrix-synapse:

```yaml
synapse:
  extraVolumes:
    - name: appservices
      secret:
        secretName: matrix-appservices
  extraVolumeMounts:
    - name: appservices
      mountPath: /synapse/appservices
      readOnly: true
extraConfig:
  app_service_config_files:
    - /synapse/appservices/hookshot.yaml
```

Synapse reads registrations at start only. Changing one here does not restart it; roll the Synapse pod, for example through an annotation with a checksum of these values.

The same Secret can serve the bridge: [matrix-hookshot](https://github.com/GlobalArtInc/helm-charts/tree/main/charts/matrix-hookshot) mounts its registration from it, so the tokens live in one place.

Both names default to `<release>-signing-key` and `<release>-appservices`.
