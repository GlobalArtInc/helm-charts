{{- define "jaunt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "jaunt.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 53 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "jaunt.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 53 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 53 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "jaunt.baseLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/version: {{ default .Chart.AppVersion .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "jaunt.instanceSelectorLabels" -}}
app.kubernetes.io/name: {{ include "jaunt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "jaunt.selectorLabels" -}}
{{ include "jaunt.instanceSelectorLabels" . }}
app.kubernetes.io/component: server
{{- end -}}

{{- define "jaunt.labels" -}}
{{ include "jaunt.baseLabels" . }}
{{ include "jaunt.selectorLabels" . }}
{{- end -}}

{{- define "jaunt.caInit.labels" -}}
{{ include "jaunt.baseLabels" . }}
{{ include "jaunt.instanceSelectorLabels" . }}
app.kubernetes.io/component: ca-init
{{- end -}}

{{- define "jaunt.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.image.digest -}}
{{- printf "%s:%s@%s" .Values.image.repository $tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{- define "jaunt.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "jaunt.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "jaunt.policyConfigMapName" -}}
{{- default (printf "%s-policy" (include "jaunt.fullname" .)) .Values.policy.existingConfigMap -}}
{{- end -}}

{{- define "jaunt.claimName" -}}
{{- default (include "jaunt.fullname" .) .Values.persistence.existingClaim -}}
{{- end -}}

{{- define "jaunt.route.tlsSecretName" -}}
{{- if .Values.route.tls.certificate.enabled -}}
{{- default (printf "tls-%s" (include "jaunt.fullname" .)) .Values.route.tls.secretName -}}
{{- else -}}
{{- .Values.route.tls.secretName -}}
{{- end -}}
{{- end -}}

{{/* The host part of a URL, or of host[:port]. */}}
{{- define "jaunt.hostOf" -}}
{{- regexReplaceAll ":[0-9]+$" (regexReplaceAll "^[a-z]+://" . "") "" -}}
{{- end -}}

{{/* Fixed paths inside the container. */}}
{{- define "jaunt.paths.config" -}}/etc/jaunt/config/jauntd.yaml{{- end -}}
{{- define "jaunt.paths.policy" -}}/etc/jaunt/policy{{- end -}}
{{- define "jaunt.paths.caIdentity" -}}/run/secrets/jaunt/ca/identity{{- end -}}
{{- define "jaunt.paths.oidcSecret" -}}/run/secrets/jaunt/oidc/client-secret{{- end -}}
{{- define "jaunt.paths.oidcRoots" -}}/etc/jaunt/trust/oidc-roots.pem{{- end -}}

{{/*
jauntd.yaml as a YAML mapping: the keys the chart owns, generated from the
values, then the free-form `config` merged over them.
*/}}
{{- define "jaunt.config" -}}
{{- $c := dict "data_dir" .Values.dataDir "listen" (printf "0.0.0.0:%d" (int .Values.ports.http)) "policy_dir" (include "jaunt.paths.policy" .) -}}
{{- with .Values.publicUrl }}{{- $_ := set $c "public_url" . }}{{- end -}}
{{- with .Values.sshSuffix }}{{- $_ := set $c "ssh_suffix" . }}{{- end -}}
{{- with .Values.agentEndpoint }}{{- $_ := set $c "agent_endpoint" . }}{{- end -}}
{{- with .Values.gateEndpoint }}{{- $_ := set $c "gate_endpoint" . }}{{- end -}}
{{- if .Values.agents.enabled -}}
{{- $_ := set $c "agents_listen" (printf "0.0.0.0:%d" (int .Values.ports.agents)) -}}
{{- else -}}
{{- $_ := set $c "agents_listen" "" -}}
{{- end -}}
{{- if .Values.sshGate.enabled -}}
{{- $gate := dict "listen" (printf "0.0.0.0:%d" (int .Values.ports.ssh)) -}}
{{- $hostnames := .Values.sshGate.hostnames -}}
{{- if and (not $hostnames) .Values.gateEndpoint -}}
{{- $hostnames = list (include "jaunt.hostOf" .Values.gateEndpoint) -}}
{{- end -}}
{{- $_ := set $gate "hostnames" $hostnames -}}
{{- if .Values.sshGate.proxyProtocol -}}
{{- $_ := set $gate "proxy_protocol" true -}}
{{- end -}}
{{- if .Values.sshGate.trustedProxies -}}
{{- $_ := set $gate "trusted_proxies" .Values.sshGate.trustedProxies -}}
{{- end -}}
{{- $_ := set $c "ssh_gate" $gate -}}
{{- end -}}
{{- $oidc := dict "client_secret_file" (include "jaunt.paths.oidcSecret" .) -}}
{{- with .Values.oidc.issuerUrl }}{{- $_ := set $oidc "issuer_url" . }}{{- end -}}
{{- with .Values.oidc.clientId }}{{- $_ := set $oidc "client_id" . }}{{- end -}}
{{- if .Values.oidc.extraRootCertificates.name -}}
{{- $_ := set $oidc "extra_root_certificates_file" (include "jaunt.paths.oidcRoots" .) -}}
{{- end -}}
{{- $_ := set $c "oidc" $oidc -}}
{{- toYaml (mergeOverwrite $c (deepCopy .Values.config)) -}}
{{- end -}}

{{- define "jaunt.env" -}}
- name: JAUNT_CONFIG
  value: {{ include "jaunt.paths.config" . | quote }}
- name: JAUNT_CA_KEY_FILE
  value: {{ include "jaunt.paths.caIdentity" . | quote }}
{{- with .Values.log.filter }}
- name: RUST_LOG
  value: {{ . | quote }}
{{- end }}
{{- end -}}

{{/* Volume mounts shared by the server and the ca-init Job. */}}
{{- define "jaunt.volumeMounts.common" -}}
- name: config
  mountPath: /etc/jaunt/config
  readOnly: true
- name: data
  mountPath: {{ .Values.dataDir }}
- name: tmp
  mountPath: /tmp
- name: ca-identity
  mountPath: /run/secrets/jaunt/ca
  readOnly: true
{{- end -}}

{{- define "jaunt.volumes.common" -}}
- name: config
  configMap:
    name: {{ include "jaunt.fullname" . }}
- name: data
  {{- if .Values.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ include "jaunt.claimName" . }}
  {{- else }}
  emptyDir: {}
  {{- end }}
- name: tmp
  emptyDir:
    sizeLimit: 64Mi
- name: ca-identity
  secret:
    secretName: {{ .Values.ca.identitySecret.name | quote }}
    defaultMode: 256 # octal 0400
    items:
      - key: {{ .Values.ca.identitySecret.key | quote }}
        path: identity
{{- end -}}

{{- define "jaunt.publicHost" -}}
{{- include "jaunt.hostOf" (fromYaml (include "jaunt.config" .)).public_url -}}
{{- end -}}

{{- define "jaunt.route.httpHost" -}}
{{- default (include "jaunt.publicHost" .) .Values.route.http.host -}}
{{- end -}}

{{- define "jaunt.route.agentsHost" -}}
{{- default (include "jaunt.hostOf" (fromYaml (include "jaunt.config" .)).agent_endpoint) .Values.route.agents.host -}}
{{- end -}}

{{/*
The parentRef of a route: a listener of the chart's ListenerSet, or a listener of
the Gateway itself, by sectionName. Takes a dict with ctx (the root context),
listener (the name in the ListenerSet) and sectionName (on the Gateway).
*/}}
{{- define "jaunt.parentRef" -}}
{{- $ctx := .ctx -}}
{{- if $ctx.Values.route.listenerSet.enabled -}}
- group: gateway.networking.k8s.io
  kind: ListenerSet
  name: {{ include "jaunt.fullname" $ctx }}-listeners
  sectionName: {{ .listener }}
{{- else -}}
- group: gateway.networking.k8s.io
  kind: Gateway
  name: {{ $ctx.Values.route.gateway.name }}
  namespace: {{ $ctx.Values.route.gateway.namespace }}
  {{- with .sectionName }}
  sectionName: {{ . }}
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Route apiVersions. An explicit value wins. Otherwise the cluster decides, by the
API versions it serves; when it cannot tell (helm template lists no CRDs) the
defaults are the ones of the clusters this chart is meant for. Takes a dict with
ctx, kind, explicit and fallback.
*/}}
{{- define "jaunt.route.apiVersion" -}}
{{- $ctx := .ctx -}}
{{- if .explicit -}}
{{- .explicit -}}
{{- else if $ctx.Capabilities.APIVersions.Has (printf "gateway.networking.k8s.io/v1/%s" .kind) -}}
gateway.networking.k8s.io/v1
{{- else if $ctx.Capabilities.APIVersions.Has (printf "gateway.networking.k8s.io/v1alpha2/%s" .kind) -}}
gateway.networking.k8s.io/v1alpha2
{{- else -}}
{{- .fallback -}}
{{- end -}}
{{- end -}}

{{/* "true" when the argument is a lowercase DNS name by the daemon's rule. */}}
{{- define "jaunt.isDnsName" -}}
{{- $ok := le (len .) 253 -}}
{{- range (splitList "." .) -}}
{{- if not (and (le (len .) 63) (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" .)) -}}
{{- $ok = false -}}
{{- end -}}
{{- end -}}
{{- if $ok }}true{{ end -}}
{{- end -}}

{{/* "true" when the last label is a number, which makes a host an IP address. */}}
{{- define "jaunt.endsInNumber" -}}
{{- $last := last (splitList "." .) -}}
{{- if or (regexMatch "^[0-9]+$" $last) (regexMatch "^0[xX][0-9a-fA-F]*$" $last) }}true{{ end -}}
{{- end -}}

{{/* What is wrong with a trusted proxy block, or nothing. */}}
{{- define "jaunt.trustedProxyProblem" -}}
{{- $block := lower . -}}
{{- if not (regexMatch "^[0-9a-f:.]+/[0-9]{1,3}$" $block) -}}
it is not a CIDR block such as 10.0.0.0/8
{{- else -}}
{{- $parts := splitList "/" $block -}}
{{- $addr := first $parts -}}
{{- $prefix := int (last $parts) -}}
{{- if contains ":" $addr -}}
{{- $groups := splitList ":" $addr -}}
{{- $bad := gt (len (regexFindAll "::" $addr -1)) 1 -}}
{{- if contains ":::" $addr -}}{{- $bad = true -}}{{- end -}}
{{- range $i, $g := $groups -}}
{{- if not (or (regexMatch "^[0-9a-f]{0,4}$" $g) (and (eq (add $i 1) (len $groups)) (regexMatch "^[0-9]{1,3}(\\.[0-9]{1,3}){3}$" $g))) -}}{{- $bad = true -}}{{- end -}}
{{- end -}}
{{- if $bad -}}
it is not a valid IPv6 network
{{- else if hasPrefix "::ffff:" $addr -}}
an IPv4-mapped IPv6 network never matches, write it in the IPv4 form
{{- else if gt $prefix 128 -}}
the prefix length is above 128
{{- else if eq $prefix 0 -}}
a network of prefix length 0 trusts every peer
{{- else if lt $prefix 16 -}}
the network is too wide for a proxy fleet, IPv6 needs /16 or longer
{{- end -}}
{{- else -}}
{{- $octets := splitList "." $addr -}}
{{- $bad := ne (len $octets) 4 -}}
{{- range $octets -}}
{{- if not (and (regexMatch "^[0-9]{1,3}$" .) (le (int .) 255)) -}}{{- $bad = true -}}{{- end -}}
{{- end -}}
{{- if $bad -}}
it is not a valid IPv4 network
{{- else if gt $prefix 32 -}}
the prefix length is above 32
{{- else if eq $prefix 0 -}}
a network of prefix length 0 trusts every peer
{{- else if lt $prefix 8 -}}
the network is too wide for a proxy fleet, IPv4 needs /8 or longer
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
