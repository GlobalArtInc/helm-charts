# synapse-admin

[Ketesa](https://github.com/etkecc/ketesa), the successor of the etke.cc synapse-admin, served under a path of the homeserver's own host (`https://matrix.example.com/synapse-admin/`), plus a hook that registers the homeserver's first admin user.

## UI

```yaml
ingress:
  host: matrix.example.com
config:
  restrictBaseUrl: https://matrix.example.com
```

`config` becomes Ketesa's `config.json`; `restrictBaseUrl` pins the UI to this homeserver.

The image serves the UI from its web root. An init container copies it into a directory named after `path` on an emptyDir, and static-web-server serves that, so the Ingress is a plain `Prefix` path. A `rewrite-target` would do the same with ingress-nginx, but it turns on regex matching for every path of the host, the homeserver's `/_matrix` included. static-web-server redirects `/synapse-admin` to `/synapse-admin/`, which the UI's relative asset paths need.

The server listens on `0.0.0.0`. Its default, `[::]`, fails on nodes without IPv6 with "Address family not supported by protocol".

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
