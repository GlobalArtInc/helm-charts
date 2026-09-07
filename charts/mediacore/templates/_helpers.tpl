{{- define "mediacore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The prefix every object of this release is named after.

A release called `mediacore` installing a chart called `mediacore` would give
`mediacore-mediacore-sfu-0`, which is the name that ends up in logs, in the
session records and in the recording queue. So the chart name is not repeated
when the release name already carries it -- the usual Helm idiom, and worth
more here than usual because this prefix is also the SFU's node identity.
*/}}
{{- define "mediacore.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "mediacore.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "mediacore.sfu.fullname" -}}
{{- printf "%s-sfu" (include "mediacore.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mediacore.front.fullname" -}}
{{- printf "%s-front" (include "mediacore.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mediacore.labels" -}}
app.kubernetes.io/name: {{ include "mediacore.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ default .Chart.AppVersion .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "mediacore.sfu.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mediacore.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: sfu
{{- end -}}

{{- define "mediacore.front.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mediacore.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: front
{{- end -}}

{{- define "mediacore.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "mediacore.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "mediacore.image" -}}
{{- $repository := required "image.repository is not set. Nothing publishes a mediacore image: build one from the Dockerfile at the root of github.com/GlobalArtInc/mediacore (it produces both binaries) and push it to a registry this cluster can pull from." .Values.image.repository -}}
{{- printf "%s:%s" $repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{- define "mediacore.secretName" -}}
{{- default (printf "%s-auth" (include "mediacore.fullname" .)) .Values.auth.existingSecret -}}
{{- end -}}

{{/*
The api key and secret, as environment variables both workloads need: the SFU
verifies tokens with them, the front end signs tokens with them, and they have
to be the same pair or the page loads and joining fails.
*/}}
{{- define "mediacore.authEnv" -}}
- name: MEDIACORE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "mediacore.secretName" . }}
      key: {{ .Values.auth.secretKeys.apiKey }}
- name: MEDIACORE_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "mediacore.secretName" . }}
      key: {{ .Values.auth.secretKeys.apiSecret }}
{{- end -}}

{{/*
Whether the SFU keeps its meetings in a database, and whether it can record.
Asked in four places -- the config, the init container's checks, its
environment, and the volume -- and answering them from one expression is what
keeps a pod that renders from being a pod that cannot start.
*/}}
{{- define "mediacore.sfu.inPostgres" -}}
{{- if (((.Values.sfu.config).sessions).postgres).enabled -}}true{{- end -}}
{{- end -}}

{{- define "mediacore.sfu.records" -}}
{{- if (.Values.sfu.config).recording -}}true{{- end -}}
{{- end -}}

{{/*
The credentials the SFU reads at pod start, as distinct from the settings in
its ConfigMap. A password in a ConfigMap is a password in `helm get values` and
in every `kubectl describe` of it, so the database url and the object store's
keys are here, from the same Secret the signing secret comes from.

`optional: true` on every one of them, and it is not laxness. With
`auth.existingSecret` the chart cannot see inside the Secret, so the checks in
`mediacore.validate` cannot run and a missing key gets as far as the pod. A
required `secretKeyRef` that is missing stops the kubelet before any container
runs: `CreateContainerConfigError`, no logs, and with this Deployment's
`Recreate` strategy the old pod is already gone. Optional lets the init
container start and fail with the sentence naming the Secret and the key.
*/}}
{{- define "mediacore.sfu.storeEnv" -}}
{{- if include "mediacore.sfu.inPostgres" . }}
- name: MEDIACORE_POSTGRES_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "mediacore.secretName" . }}
      key: {{ .Values.auth.secretKeys.postgresUrl }}
      optional: true
{{- end }}
{{- if include "mediacore.sfu.records" . }}
- name: MEDIACORE_S3_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "mediacore.secretName" . }}
      key: {{ .Values.auth.secretKeys.s3AccessKeyId }}
      optional: true
- name: MEDIACORE_S3_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "mediacore.secretName" . }}
      key: {{ .Values.auth.secretKeys.s3SecretAccessKey }}
      optional: true
{{- end }}
{{- end -}}

{{/*
The names envsubst is given. It substitutes only what it is told to, and a
placeholder left out of this list is written into the rendered config verbatim
-- which the server reads as a url with a `$` in it and refuses, on the node,
in a crash loop.
*/}}
{{- define "mediacore.sfu.substituted" -}}
{{- $names := list "${MEDIACORE_API_KEY}" "${MEDIACORE_API_SECRET}" -}}
{{- if not (.Values.sfu.config).node_id -}}
{{- $names = append $names "${MEDIACORE_NODE_ID}" -}}
{{- end -}}
{{- if .Values.sfu.advertise.fromNodeIP -}}
{{- $names = append $names "${MEDIACORE_ADVERTISE_IP}" -}}
{{- end -}}
{{- if include "mediacore.sfu.inPostgres" . -}}
{{- $names = append $names "${MEDIACORE_POSTGRES_URL}" -}}
{{- end -}}
{{- if include "mediacore.sfu.records" . -}}
{{- $names = append $names "${MEDIACORE_S3_ACCESS_KEY_ID}" -}}
{{- $names = append $names "${MEDIACORE_S3_SECRET_ACCESS_KEY}" -}}
{{- end -}}
{{- join " " $names -}}
{{- end -}}

{{/*
The paths the SFU owns, in one place because they are published twice: by the
HTTPRoute and, on clusters without Gateway API, by the Ingress. Two lists would
drift, and the drift is silent -- a /rtc that lands on the front end answers 404
to the signalling WebSocket, which the browser reports as a connection that
closed and nothing else. Everything not listed here belongs to the front end.

/rtc is the signalling WebSocket and its validation probe; /twirp is the room
service the backoffice calls with a token it signed itself; /swagger is the
generated API page, published only when route.swagger says so -- one switch,
because there is one split.
*/}}
{{- define "mediacore.sfu.paths" -}}
- /rtc
- /twirp
{{- if .Values.route.swagger }}
- /swagger
{{- end }}
{{- end -}}

{{/*
The hostname the Ingress publishes. Empty means route.host: the page and the
WebSocket have to share one origin whoever publishes them, so the name is
written once even when the route itself is switched off.
*/}}
{{- define "mediacore.ingress.host" -}}
{{- default .Values.route.host .Values.ingress.host -}}
{{- end -}}

{{/*
The name this release is reachable under, whichever object publishes it. Empty
when nothing does, which is a legitimate deployment -- somebody else's proxy in
front -- and then front.wsUrl has to be stated by hand.
*/}}
{{- define "mediacore.publishedHost" -}}
{{- if and .Values.route.enabled .Values.route.host -}}
{{- .Values.route.host -}}
{{- else if .Values.ingress.enabled -}}
{{- include "mediacore.ingress.host" . -}}
{{- end -}}
{{- end -}}

{{/*
What the browser is told to open for signalling. The front end accepts a scheme
and a bare host and nothing else -- it appends /rtc itself -- so this is derived
from the published host rather than from any Service address, and the page and
the WebSocket end up on one origin.
*/}}
{{- define "mediacore.front.wsUrl" -}}
{{- if .Values.front.wsUrl -}}
{{- .Values.front.wsUrl | trimSuffix "/" -}}
{{- else if (include "mediacore.publishedHost" .) -}}
{{- printf "wss://%s" (include "mediacore.publishedHost" .) -}}
{{- else -}}
{{- fail "front.wsUrl is not set and neither route.host nor ingress.host gives a name to derive it from. The front end has to tell the browser where to open the signalling WebSocket, and it accepts a scheme and a bare host only -- wss://meet.example.com, no path and no trailing slash. Publish the SFU on the same origin as the page: a WebSocket to a second hostname is refused by the browser with nothing shown to the user and nothing logged on the server." -}}
{{- end -}}
{{- end -}}

{{- define "mediacore.route.tlsSecretName" -}}
{{- if .Values.route.tls.certificate.enabled -}}
{{- default (printf "tls-%s" (include "mediacore.fullname" .)) .Values.route.tls.secretName -}}
{{- else -}}
{{- required "route.tls.secretName is not set. Name the existing certificate Secret for this host -- the cluster's wildcards are already issued, and this is normally one of them -- or set route.tls.certificate.enabled to order one for a name no wildcard covers." .Values.route.tls.secretName -}}
{{- end -}}
{{- end -}}

{{/*
Everything that would otherwise become a deployment which starts, signals, and
carries no audio. Rendered from templates/validate.yaml, which produces no
manifest of its own.
*/}}
{{- define "mediacore.validate" -}}
{{- if and (not .Values.sfu.enabled) (not .Values.front.enabled) -}}
{{- fail "both sfu.enabled and front.enabled are false, so this release would install nothing." -}}
{{- end -}}

{{- if and .Values.sfu.enabled (ne (int .Values.sfu.replicaCount) 1) -}}
{{- fail (printf "sfu.replicaCount is %d. mediacore does not scale horizontally: rooms, participants and every track live in the memory of one process, and the two RPCs that would move a participant between nodes -- ForwardParticipant and MoveParticipant -- answer `unimplemented` on purpose. Two replicas behind one Service put half of a room on each pod; both halves join, both see a participant list, and neither hears the other, with nothing in any log to say why. That is worse than a failed install, so this chart renders one replica or none. If one process is not enough, run separate releases and decide in your own application which room lives where." (int .Values.sfu.replicaCount)) -}}
{{- end -}}

{{- if not .Values.auth.existingSecret -}}
{{- if not .Values.auth.apiSecret -}}
{{- fail "auth.apiSecret is empty and auth.existingSecret is not set, so there is nothing to sign room tokens with. Generate one -- `openssl rand -hex 32` -- and pass it with --set-string auth.apiSecret=..., or point auth.existingSecret at a Secret you manage. This chart will not invent a default: a shared default secret lets anyone who has read this repository mint a token for any room on your deployment." -}}
{{- end -}}
{{- if lt (len .Values.auth.apiSecret) 32 -}}
{{- fail (printf "auth.apiSecret is %d characters. The front end refuses to start below 32, so a shorter one gives you an SFU that runs and a front end that crash-loops: `openssl rand -hex 32`." (len .Values.auth.apiSecret)) -}}
{{- end -}}
{{- end -}}

{{- if .Values.sfu.enabled -}}
{{- if and .Values.sfu.hostNetwork .Values.sfu.hostPort -}}
{{- fail "sfu.hostPort has no meaning with sfu.hostNetwork: the container already binds the node's ports directly. Turn one of them off." -}}
{{- end -}}
{{- if and (not .Values.sfu.advertise.fromNodeIP) (not .Values.sfu.advertise.addresses) -}}
{{- fail "sfu.advertise.fromNodeIP is off and sfu.advertise.addresses is empty, so the server would have to guess which address to put into its ICE candidates. Its guess is the first address a route lookup finds, which inside a pod is the pod address no browser can reach: everyone joins, the participant list fills in, and the room is silent, with no error in any log. State the address clients send media to." -}}
{{- end -}}
{{- range .Values.sfu.advertise.addresses -}}
{{- $host := . | toString -}}
{{- $host = regexReplaceAll ":[0-9]+$" $host "" -}}
{{- if not (regexMatch "^[0-9a-fA-F.:\\[\\]]+$" $host) -}}
{{- fail (printf "sfu.advertise.addresses contains `%s`. ICE candidates carry addresses, never names -- the server rejects a hostname at startup -- so this has to be an ip, or an ip:port when something in front of the pod renumbers the media port." .) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- if include "mediacore.sfu.inPostgres" . -}}
{{- if and (not .Values.auth.existingSecret) (not .Values.auth.postgresUrl) -}}
{{- fail "sfu.config.sessions.postgres.enabled is on and there is nothing to connect with. The url carries a password, so it is not a chart setting: pass it as auth.postgresUrl, or point auth.existingSecret at a Secret holding it under the key auth.secretKeys.postgresUrl." -}}
{{- end -}}
{{- end -}}

{{- if include "mediacore.sfu.records" . -}}
{{- if not (include "mediacore.sfu.inPostgres" .) -}}
{{- fail "sfu.config.recording is set and sfu.config.sessions.postgres.enabled is not. A recording's upload is a row several processes claim, and a directory of one file per meeting cannot be a queue -- the server refuses to start on this pairing, so the release is refused here instead, before it becomes a crash loop." -}}
{{- end -}}
{{- if not .Values.recordings.enabled -}}
{{- fail "sfu.config.recording is set and recordings.enabled is not. Audio is written to disk for as long as a meeting lasts and uploaded when it ends; the pod's root filesystem is read-only, so without that volume the first recording fails to open its file." -}}
{{- end -}}
{{- if and (not .Values.auth.existingSecret) (or (not .Values.auth.s3AccessKeyId) (not .Values.auth.s3SecretAccessKey)) -}}
{{- fail "sfu.config.recording is set and the object store's keys are missing. Every request to an object store is signed and an unsigned one is refused: pass auth.s3AccessKeyId and auth.s3SecretAccessKey, or point auth.existingSecret at a Secret holding them under the keys in auth.secretKeys." -}}
{{- end -}}
{{- if not ((.Values.sfu.config.recording).s3).bucket -}}
{{- fail "sfu.config.recording is set and sfu.config.recording.s3.bucket is empty. There is nowhere for a finished recording to go, and a server that recorded all day and could upload none of it would only fill its volume." -}}
{{- end -}}
{{- end -}}

{{- if .Values.route.enabled -}}
{{- if not .Values.route.host -}}
{{- fail "route.host is not set. It is the hostname visitors type, and both the listener and the route are built from it -- no scheme, no path. Set route.enabled to false if you publish this some other way." -}}
{{- end -}}
{{- end -}}

{{- if .Values.ingress.enabled -}}
{{- if not (include "mediacore.ingress.host" .) -}}
{{- fail "ingress.enabled is on and there is no hostname to publish. Set ingress.host -- the name visitors type, no scheme and no path -- or leave it empty and set route.host, which it falls back to so that the two ways of publishing cannot name two different origins." -}}
{{- end -}}
{{/*
Two publishers, two names, one front end. Not a duplicate-object check: the same
name published twice is how a cluster moves from the gateway to an ingress
controller without a gap, and both objects then serve the same paths to the same
backends. Two different names is the arrangement that cannot work, because the
front end is built with exactly one WebSocket URL.
*/}}
{{- if and .Values.route.enabled .Values.front.enabled (ne (include "mediacore.ingress.host" .) .Values.route.host) -}}
{{- fail (printf "route.enabled publishes this release on %s and ingress.enabled publishes it on %s. The front end is handed one WebSocket URL for every visitor -- wss://%s here -- and a page served from %s may not open a WebSocket to %s: the browser refuses it with nothing shown to the user and nothing logged on the server, so whoever arrives on the second name gets a room that never connects. Publish one name: turn one of the two off, or give both the same host, which is how you move from one to the other without a gap -- both publish it, you move the DNS record, then you turn the old one off. Two names are only sensible with front.enabled: false, where nothing but the SFU's own paths is being published." .Values.route.host (include "mediacore.ingress.host" .) (include "mediacore.publishedHost" .) (include "mediacore.ingress.host" .) .Values.route.host) -}}
{{- end -}}
{{- end -}}
{{- end -}}
