{{- define "mediacore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mediacore.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "mediacore.name" .) | trunc 63 | trimSuffix "-" -}}
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
What the browser is told to open for signalling. The front end accepts a scheme
and a bare host and nothing else -- it appends /rtc itself -- so this is derived
from the published host rather than from any Service address, and the page and
the WebSocket end up on one origin.
*/}}
{{- define "mediacore.front.wsUrl" -}}
{{- if .Values.front.wsUrl -}}
{{- .Values.front.wsUrl | trimSuffix "/" -}}
{{- else if and .Values.route.enabled .Values.route.host -}}
{{- printf "wss://%s" .Values.route.host -}}
{{- else -}}
{{- fail "front.wsUrl is not set and there is no route.host to derive it from. The front end has to tell the browser where to open the signalling WebSocket, and it accepts a scheme and a bare host only -- wss://meet.example.com, no path and no trailing slash. Publish the SFU on the same origin as the page: a WebSocket to a second hostname is refused by the browser with nothing shown to the user and nothing logged on the server." -}}
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

{{- if .Values.route.enabled -}}
{{- if not .Values.route.host -}}
{{- fail "route.host is not set. It is the hostname visitors type, and both the listener and the route are built from it -- no scheme, no path. Set route.enabled to false if you publish this some other way." -}}
{{- end -}}
{{- end -}}
{{- end -}}
