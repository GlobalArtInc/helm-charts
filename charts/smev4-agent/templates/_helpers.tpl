{{- define "smev4-agent.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "smev4-agent.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "smev4-agent.labels" -}}
app.kubernetes.io/name: {{ include "smev4-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "smev4-agent.configSecretName" -}}
{{- if .Values.config.existingSecret -}}
{{ .Values.config.existingSecret }}
{{- else -}}
{{ include "smev4-agent.fullname" . }}-config
{{- end -}}
{{- end -}}

{{- define "smev4-agent.keysSecretName" -}}
{{- if .Values.keys.existingSecret -}}
{{ .Values.keys.existingSecret }}
{{- else -}}
{{ fail "keys.existingSecret is required: mount CryptoPro keys via an existing Secret" }}
{{- end -}}
{{- end -}}
