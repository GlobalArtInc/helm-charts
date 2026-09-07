# mediacore

A WebRTC SFU that speaks the LiveKit protocol, and the front end that goes with
it. Two workloads out of one image:

- **sfu** — signalling on TCP `7880` (`/rtc`, `/rtc/validate`, `/healthz`, the
  room service under `/twirp/...` and a generated API page at `/swagger`), and
  **all media on one UDP port**, `7882` by default. One port, not a range.
- **front** — the page and the token endpoint, HTTP on `8080`.

Both are optional. Turn the front end off to put your own in front of the SFU;
turn the SFU off to run the page against one somewhere else.

```
                        the cluster
    ┌──────────────────────────────────────────────────┐
    │  gateway (Envoy) or ingress controller  443/tcp  │
    │    ├── /rtc*, /twirp*  ──►  sfu   :7880          │
    │    └── /                ──►  front :8080         │
    │                                                  │
    │  sfu  7882/udp  ── on the node, not through the  │
    │                    gateway and not through a     │
    │                    Service unless you ask for it │
    └──────────────────────────────────────────────────┘
          ▲                                ▲
          │ https page, wss signalling     │ microphone audio
          └──────────── browser ───────────┘
```

## Before anything else: build the image

Nothing publishes a mediacore image. `image.repository` has no default and the
chart refuses to render without one.

```console
git clone https://github.com/GlobalArtInc/mediacore
cd mediacore
podman build -t registry.example.com/mediacore:0.1.0 .
podman push registry.example.com/mediacore:0.1.0
```

The `Dockerfile` at the root builds both binaries into one image. The chart runs
the SFU from the image's own CMD and names `mediacore-front` for the front end.
It also expects `envsubst` in the image, which that Dockerfile installs
(`gettext-base`) for its own start script.

## Install

```console
helm repo add globalart https://globalartinc.github.io/helm-charts
helm install meet globalart/mediacore \
  --set image.repository=registry.example.com/mediacore \
  --set-string auth.apiSecret="$(openssl rand -hex 32)" \
  --set route.host=meet.example.com \
  --set route.tls.secretName=wildcard-example-com
```

That is the whole minimal deployment: an SFU on the node's network advertising
the node's address, a front end behind it, and one hostname carrying both.

## The three things that will bite you

### 1. Media is UDP and goes through neither the gateway nor an Ingress

An `HTTPRoute` carries HTTP, and so does an `Ingress`. Media is UDP, it is
addressed to the SFU directly, and the pod IP is not routable from a browser, so
something has to put that socket where clients can reach it. The chart offers
three ways and defaults to the first:

| | what it does | what it costs |
|---|---|---|
| `sfu.hostNetwork: true` (default) | the pod shares the node's netns and binds the media port on the node | the pod also takes `sfu.ports.signalling` on the node, so two releases collide there; PodSecurity `baseline` forbids it; needs `dnsPolicy: ClusterFirstWithHostNet`, which the chart sets |
| `sfu.hostPort: true` | only the media port is published on the node | hostPort is the CNI's job and CNIs differ — Cilium needs its host-port support on, portmap-based ones add a NAT that can rewrite the source port |
| `sfu.mediaService.enabled: true` | an ordinary UDP Service | a LoadBalancer needs a provider that forwards UDP; a NodePort lands on a *different* port number, and then you must advertise `<node ip>:<node port>` explicitly |

Whichever you pick, `udp/7882` has to be open to the clients in the node
firewall and in any cloud security group, **as UDP**. A TCP rule for that port
does nothing at all.

### 2. The advertised address is what decides whether anyone hears anything

The SFU writes an address into every ICE candidate, and that is where browsers
send their microphones. Get it wrong and nothing looks broken: people join, the
participant list is right, the mute button works, and the room is silent. No
error is logged, because packets sent to an unreachable address look exactly
like packets a firewall ate.

By default the chart reads the node's own address from the downward API
(`status.hostIP`) into the config at pod start, which is correct for
`hostNetwork` and for `hostPort`. It stops being correct the moment something
in front of the pod changes the address or the port:

```yaml
sfu:
  advertise:
    fromNodeIP: false
    addresses:
      - 203.0.113.7        # a load balancer that keeps the port
      - 198.51.100.9:31882 # a NodePort, or NAT that renumbers it
```

Addresses only — ICE candidates carry addresses, never names, and the server
refuses a hostname at startup. Both may be on at once: the node's address for
clients inside the network, a public one for everybody else.

What the server settled on is in its own log, and it is the first thing to read
when a room is silent:

```console
kubectl logs deploy/<release>-mediacore-sfu | grep "media transport ready"
... media transport ready local=0.0.0.0:7882 advertise=[203.0.113.7:7882] ...
```

Ignore the `ice socket bound` line just above it: that one reports the socket's
own view (`0.0.0.0`) and not what clients are told.

### 3. One replica, and a restart ends every call

mediacore is a single node by construction. Rooms, participants and every track
live in the memory of one process, and the two RPCs that would move a
participant between nodes — `ForwardParticipant` and `MoveParticipant` — answer
`unimplemented` on purpose. Two replicas behind one Service put half of a room
on each pod, and neither half hears the other with nothing in any log to say
why, so `sfu.replicaCount` other than 1 fails the render. If one process is not
enough, run separate releases and decide in your own application which room
lives where.

For the same reason the SFU rolls with `strategy: Recreate` and **every upgrade
of it ends every meeting in progress** — an image change, a config change, a
node drain. There is no resume: the server tells a reconnecting client that its
session is gone. Roll it when nobody is in a room, and note that the config
checksum is on the pod, so `helm upgrade --set sfu.config...` restarts the
process too. The front end has none of these limits: it holds nothing, it never
talks to the SFU, and it scales and rolls freely.

## Publishing

Two ways, and they are alternatives rather than layers. `route.enabled` (the
default) renders a `ListenerSet` on the shared gateway and an `HTTPRoute` in the
same shape as the [`route`](../route) chart; `ingress.enabled` renders one
`Ingress` instead, for a cluster that has no Gateway API. Either way it is one
hostname with `/rtc` and `/twirp` on the SFU and everything else on the front
end — the split is written once in the chart and both objects read it, so they
cannot come to disagree about which request belongs to which backend.

**One hostname, deliberately.** The front end may only be handed a scheme and a
bare host for the WebSocket — it appends `/rtc` itself and refuses a URL with a
path — and a page served from one origin may not open a WebSocket to another
without the browser refusing it silently. Splitting them across two names is the
one arrangement that cannot work.

No `Certificate` is created by default: wildcards are already issued for the
cluster's domains, so `route.tls.secretName` names an existing Secret and the
chart adds the `ReferenceGrant` the gateway needs to read it from this
namespace. Set `route.tls.certificate.enabled` only for a host no wildcard
covers.

`/swagger` is not published (`route.swagger: false`). The page carries no token
and leaks nothing, but its Try-it-out buttons act on the real room service —
`DeleteRoom` really does hang up on everyone — so it is left to a port-forward:

```console
kubectl port-forward svc/<release>-mediacore-sfu 7880:7880
```

With it off, a request to `/swagger` falls through to the front end and answers
404, which reads exactly like a broken build. That is expected.

Publishing some other way — neither of these — is `route.enabled: false` with
`ingress.enabled: false`, and then `front.wsUrl` has to be set by hand.

### With an Ingress

```console
helm install meet globalart/mediacore \
  --set image.repository=registry.example.com/mediacore \
  --set-string auth.apiSecret="$(openssl rand -hex 32)" \
  --set route.enabled=false \
  --set ingress.enabled=true \
  --set ingress.host=meet.example.com \
  --set ingress.className=nginx \
  --set ingress.tls.secretName=wildcard-example-com
```

`ingress.host` defaults to `route.host`, so a values file that already names the
host does not name it twice. `route.swagger` governs `/swagger` here too: one
split, one switch. TLS is an existing Secret **in this namespace** — an Ingress
reads no Secret from anywhere else, so a shared wildcard has to be copied here
(reflector, external-secrets, by hand) and there is no `ReferenceGrant` to make.
Leaving `ingress.tls.secretName` empty renders no `tls` block and serves the
name over plain http, on which browsers refuse to hand out a microphone at all
outside localhost.

**It does not carry media.** Nothing in this section changes anything in
["Media is UDP"](#1-media-is-udp-and-goes-through-neither-the-gateway-nor-an-ingress)
above:
`udp/7882` still goes straight to the node, `sfu.hostNetwork` still decides how
it gets there, and `sfu.advertise` still decides whether anyone hears anything.
An Ingress publishes the page and the signalling WebSocket. That is all it can
do.

**The WebSocket dies on the default timeouts.** ingress-nginx closes an upstream
connection that has been quiet for 60 seconds, and a signalling WebSocket
carries nothing while a call is simply going on, so the room works for about a
minute and then drops everybody at once — with nothing in the SFU's log, because
from its side the proxy closed the connection and that is not an error. The
chart ships the fix as a default:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

Those are ingress-nginx annotations and nothing else reads them. They are an
idle timeout rather than a limit on the length of a call — any signalling
traffic resets it — and on another controller they are inert, so set that
controller's own equivalent instead: Traefik has it on the entrypoint
(`respondingTimeouts`) and not on an annotation, an AWS ALB has
`alb.ingress.kubernetes.io/load-balancer-attributes:
idle_timeout.timeout_seconds=3600` over a default of 60, GKE takes a
`BackendConfig` with `timeoutSec` over a default of 30, and the two HAProxy
controllers each spell a tunnel timeout their own way. Prove it with a call that
sits quiet for two minutes; joining, talking and leaving never reproduces it.

**Both at once, on one name, is allowed.** It is how a live deployment moves
from the gateway to an ingress controller: both publish the hostname with the
same paths, you move the DNS record, then you turn the old one off. Two
*different* names fails the render instead, because the front end is built with
exactly one WebSocket URL and whoever arrived on the other name would get a page
whose WebSocket the browser refuses in silence. (With `front.enabled: false`
there is no page and no such URL, so two names are allowed there.)

## Secrets

`auth.apiKey` is an identifier — the `iss` of every token and the name the
secret is looked up under. `auth.apiSecret` is what signs them, at least 32
characters (`openssl rand -hex 32`); the front end refuses to start below that,
so a shorter one gives you an SFU that runs and a front end that crash-loops.

There is no default secret and the chart will not render a Secret without a
value somebody chose. Either pass `auth.apiSecret`, or point
`auth.existingSecret` at a Secret you manage and let `auth.secretKeys` name the
keys in it.

The same Secret carries the two other credentials the SFU may need, on the same
terms: `auth.postgresUrl` when it keeps meetings in a database, and
`auth.s3AccessKeyId` / `auth.s3SecretAccessKey` when it records. Neither is read
unless the setting that needs it is on, and neither is ever in the ConfigMap.

Anyone holding the secret can mint a token for any room and any identity. It
reaches the SFU through the environment of an init container and is substituted
into the config file there — it is never in the ConfigMap, and the rendered file
lives in a memory-backed `emptyDir`.

## Keeping meetings, and recording them

Out of the box the SFU writes one JSON file per meeting to the volume in
`persistence`, and records nothing. That is the arrangement one process wants,
and it is the reason `sfu.replicaCount` is refused above one.

A database replaces the directory:

```yaml
auth:
  postgresUrl: postgres://mediacore:...@db.example.com:5432/mediacore
sfu:
  config:
    sessions:
      postgres:
        enabled: true
```

The server migrates the schema itself, under an advisory lock, so several
processes starting at once is safe. The url is not a chart setting -- it carries
a password -- so it goes in the Secret, like `auth.apiSecret`, and is
substituted into the config file inside the pod.

Recording needs that database and a bucket. An upload is a row several processes
claim, which a directory of files cannot be, so the chart refuses the pairing
rather than letting the server refuse it on the node:

```yaml
auth:
  s3AccessKeyId: ...
  s3SecretAccessKey: ...
recordings:
  enabled: true
  storageClass: csi-rbd-sc
  size: 50Gi
sfu:
  config:
    recording:
      # true records every meeting; false still records the rooms that ask for
      # it themselves, with {"sessionPolicy": {"record": true}} in the metadata
      # they were created with.
      enabled: true
      s3:
        endpoint: https://storage.example.com
        region: ru-1
        bucket: mediacore
        path_style: true
```

One Ogg/Opus file per person, written to the `recordings` volume while the
meeting is happening and put in the bucket under
`<prefix>/<meeting>/<participant>-<segment>.ogg` when it ends, after which the
local file is removed. The row in `mediacore_recording` is what a transcription
service reads: the object key, the account the token named, the offset from the
start of the meeting, and the length.

That volume is the one whose loss loses something: an `emptyDir` would drop the
audio of every meeting in progress on any restart, including the rollout that
caused it. It is separate from `persistence` because it is a different size and
a different risk -- session records are kilobytes.

## The server's config

The SFU reads a YAML file, not a pile of environment variables, so `sfu.config`
is that file in the server's own key names — `config-sample.yaml` in the
mediacore repository reads as documentation for it. The chart owns the parts
that must agree with the pod: `keys`, `port`, `bind_addresses`, `rtc.udp_port`,
`rtc.bind_address`, `rtc.advertise_addresses` and the two guessing switches.

`crates/config/src/lib.rs` is declared with serde's `deny_unknown_fields`: one
key it does not recognise and the process exits at startup. `values.schema.json`
mirrors that struct, so a typo is refused by helm, naming the key:

```console
$ helm template ... --set sfu.config.room.empty_timout=10
Error: values don't meet the specifications of the schema(s) in the following chart(s):
mediacore:
- at '/sfu/config/room': additional properties 'empty_timout' not allowed
```

When mediacore gains a setting, add it to `values.schema.json` in the same
change, or the chart will refuse a key the server now accepts.

## Checking it works

```console
kubectl logs deploy/<release>-mediacore-sfu | grep "media transport ready"
kubectl logs deploy/<release>-mediacore-front | grep listening
curl -s https://meet.example.com/healthz          # -> ok        (front end)
kubectl port-forward svc/<release>-mediacore-sfu 7880:7880
curl -s 127.0.0.1:7880/healthz                    # -> counters  (the SFU)
```

Then the real test, which needs two devices: both open the URL, join, and
speak. `rtp_packets` in the SFU's `/healthz` climbs while someone is talking.
Two tabs on one machine prove less than you would like — they can succeed on a
candidate nobody else can use.

If people join and the room is silent, it is the advertised address or a
firewall, and the SFU's log looks the same for both. Tell them apart from the
node: `tcpdump -ni any udp port 7882` while somebody presses Join. Nothing
arriving is a firewall; packets arriving while the SFU logs nothing means they
are not reaching the pod. `deploy/README.md` in the mediacore repository walks
through the same three failures in more detail.

## What this chart deliberately does not do

- **No Ingress by default.** The cluster this chart comes from is on Gateway
  API. `ingress.enabled` is there for clusters that are not, and media goes
  through neither of them.
- **No `Certificate` by default.** The wildcards already exist, and a second
  order for a name that is already certified is a way to lose a working Secret.
- **No PersistentVolumeClaim.** mediacore writes nothing to disk today, which is
  also why a restart ends every call. Session records and recordings are being
  designed and will need a volume; there is a commented placeholder in
  `values.yaml` for when they land, and an empty PVC before then would store
  nothing while making the SFU harder to schedule.
- **No autoscaling and no PodDisruptionBudget.** Both assume more than one
  replica.
- **No TURN.** A client that can only reach the world over TCP 443 cannot join;
  there is no relay in this deployment and the chart cannot invent one.
