{{- define "synapse-secrets.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "synapse-secrets.signingKeyName" -}}
{{- default (printf "%s-signing-key" .Release.Name) .Values.signingKey.secretName -}}
{{- end -}}

{{- define "synapse-secrets.appservicesName" -}}
{{- default (printf "%s-appservices" .Release.Name) .Values.appservices.secretName -}}
{{- end -}}
