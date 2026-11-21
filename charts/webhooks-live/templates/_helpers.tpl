{{- define "webhooks-live.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "webhooks-live.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 53 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "webhooks-live.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 53 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 53 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "webhooks-live.baseLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/version: {{ default .Chart.AppVersion .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "webhooks-live.instanceSelectorLabels" -}}
app.kubernetes.io/name: {{ include "webhooks-live.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "webhooks-live.selectorLabels" -}}
{{ include "webhooks-live.instanceSelectorLabels" . }}
app.kubernetes.io/component: server
{{- end -}}

{{- define "webhooks-live.labels" -}}
{{ include "webhooks-live.baseLabels" . }}
{{ include "webhooks-live.selectorLabels" . }}
{{- end -}}

{{- define "webhooks-live.migrate.labels" -}}
{{ include "webhooks-live.baseLabels" . }}
{{ include "webhooks-live.instanceSelectorLabels" . }}
app.kubernetes.io/component: migrate
{{- end -}}

{{- define "webhooks-live.admin.labels" -}}
{{ include "webhooks-live.baseLabels" . }}
{{ include "webhooks-live.instanceSelectorLabels" . }}
app.kubernetes.io/component: admin
{{- end -}}

{{- define "webhooks-live.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if .Values.image.digest -}}
{{- printf "%s:%s@%s" .Values.image.repository $tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{- define "webhooks-live.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "webhooks-live.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "webhooks-live.route.tlsSecretName" -}}
{{- if .Values.route.tls.certificate.enabled -}}
{{- default (printf "tls-%s" (include "webhooks-live.fullname" .)) .Values.route.tls.secretName -}}
{{- else -}}
{{- .Values.route.tls.secretName -}}
{{- end -}}
{{- end -}}

{{- define "webhooks-live.number" -}}
{{- if kindIs "float64" . -}}
{{- printf "%.0f" . -}}
{{- else -}}
{{- . -}}
{{- end -}}
{{- end -}}

{{- define "webhooks-live.milliseconds" -}}
{{- $total := 0 -}}
{{- range regexFindAll "[0-9]+(ms|s|m|h|d|w)" . -1 -}}
{{- $value := int (regexFind "[0-9]+" .) -}}
{{- $unit := regexFind "(ms|s|m|h|d|w)$" . -}}
{{- $factor := 1 -}}
{{- if eq $unit "s" -}}
{{- $factor = 1000 -}}
{{- else if eq $unit "m" -}}
{{- $factor = 60000 -}}
{{- else if eq $unit "h" -}}
{{- $factor = 3600000 -}}
{{- else if eq $unit "d" -}}
{{- $factor = 86400000 -}}
{{- else if eq $unit "w" -}}
{{- $factor = 604800000 -}}
{{- end -}}
{{- $total = add $total (mul $value $factor) -}}
{{- end -}}
{{- $total -}}
{{- end -}}

{{- define "webhooks-live.env" -}}
- name: WEBHOOKS_LIVE_PUBLIC_URL
  value: {{ .Values.publicUrl | quote }}
- name: WEBHOOKS_LIVE_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret.name | quote }}
      key: {{ .Values.database.existingSecret.key | quote }}
- name: WEBHOOKS_LIVE_DB_POOL_SIZE
  value: {{ include "webhooks-live.number" .Values.database.poolSize | quote }}
- name: WEBHOOKS_LIVE_AUTH_MODE
  value: {{ .Values.auth.mode | quote }}
{{- if eq .Values.auth.mode "sso" }}
- name: WEBHOOKS_LIVE_OIDC_ISSUER
  value: {{ .Values.auth.oidc.issuer | quote }}
- name: WEBHOOKS_LIVE_OIDC_CLIENT_ID
  value: {{ .Values.auth.oidc.clientId | quote }}
- name: WEBHOOKS_LIVE_OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.auth.oidc.clientSecret.existingSecret.name | quote }}
      key: {{ .Values.auth.oidc.clientSecret.existingSecret.key | quote }}
- name: WEBHOOKS_LIVE_OIDC_SCOPES
  value: {{ join " " .Values.auth.oidc.scopes | quote }}
{{- with .Values.auth.oidc.providerName }}
- name: WEBHOOKS_LIVE_OIDC_PROVIDER_NAME
  value: {{ . | quote }}
{{- end }}
{{- end }}
- name: WEBHOOKS_LIVE_SESSION_IDLE
  value: {{ .Values.auth.sessionIdle | quote }}
- name: WEBHOOKS_LIVE_SESSION_MAX
  value: {{ .Values.auth.sessionMax | quote }}
{{- with .Values.trustedProxies }}
- name: WEBHOOKS_LIVE_TRUSTED_PROXIES
  value: {{ join "," . | quote }}
{{- end }}
- name: WEBHOOKS_LIVE_RETENTION
  value: {{ .Values.retention | quote }}
- name: WEBHOOKS_LIVE_RING_MODE_ALLOWED
  value: {{ .Values.ringModeAllowed | quote }}
- name: WEBHOOKS_LIVE_MAX_CAPTURES
  value: {{ include "webhooks-live.number" .Values.limits.maxCaptures | quote }}
- name: WEBHOOKS_LIVE_MAX_BODY_BYTES
  value: {{ include "webhooks-live.number" .Values.limits.maxBodyBytes | quote }}
- name: WEBHOOKS_LIVE_BODY_MEMORY_BUDGET
  value: {{ include "webhooks-live.number" .Values.limits.bodyMemoryBudget | quote }}
- name: WEBHOOKS_LIVE_MAX_DELAYED
  value: {{ include "webhooks-live.number" .Values.limits.maxDelayed | quote }}
- name: WEBHOOKS_LIVE_STORAGE_CAP_BYTES
  value: {{ include "webhooks-live.number" .Values.limits.storageCapBytes | quote }}
- name: WEBHOOKS_LIVE_RATE_CAPTURE_IP
  value: {{ .Values.rateLimits.captureIp | quote }}
- name: WEBHOOKS_LIVE_RATE_CAPTURE_ENDPOINT
  value: {{ .Values.rateLimits.captureEndpoint | quote }}
- name: WEBHOOKS_LIVE_RATE_API_IP
  value: {{ .Values.rateLimits.apiIp | quote }}
- name: WEBHOOKS_LIVE_RATE_CREATE_IP
  value: {{ .Values.rateLimits.createIp | quote }}
- name: WEBHOOKS_LIVE_FORWARD_ENABLED
  value: {{ .Values.forward.enabled | quote }}
- name: WEBHOOKS_LIVE_FORWARD_CONCURRENCY
  value: {{ include "webhooks-live.number" .Values.forward.concurrency | quote }}
- name: WEBHOOKS_LIVE_FORWARD_MAX_ATTEMPTS
  value: {{ include "webhooks-live.number" .Values.forward.maxAttempts | quote }}
{{- with .Values.forward.allowCidrs }}
- name: WEBHOOKS_LIVE_FORWARD_ALLOW_CIDRS
  value: {{ join "," . | quote }}
{{- end }}
- name: WEBHOOKS_LIVE_SHUTDOWN_DRAIN
  value: {{ .Values.shutdown.drain | quote }}
- name: WEBHOOKS_LIVE_SHUTDOWN_GRACE
  value: {{ .Values.shutdown.grace | quote }}
- name: WEBHOOKS_LIVE_LOG
  value: {{ .Values.log.filter | quote }}
{{- range $key, $value := .Values.config }}
- name: {{ printf "WEBHOOKS_LIVE_%s" $key }}
  value: {{ include "webhooks-live.number" $value | quote }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}
