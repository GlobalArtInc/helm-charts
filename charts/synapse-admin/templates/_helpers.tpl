{{- define "synapse-admin.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "synapse-admin.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "synapse-admin.labels" -}}
{{ include "synapse-admin.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "synapse-admin.ingress.host" -}}
{{- default .Values.route.host .Values.ingress.host -}}
{{- end -}}

{{- define "synapse-admin.route.tlsSecretName" -}}
{{- if .Values.route.tls.certificate.enabled -}}
{{- default (printf "tls-%s" (include "synapse-admin.fullname" .)) .Values.route.tls.secretName -}}
{{- else -}}
{{- required "route.tls.secretName is not set. Name the existing certificate Secret for this host, or set route.tls.certificate.enabled to order one, or leave route.listenerSet.enabled off to attach the route to a listener that already terminates TLS." .Values.route.tls.secretName -}}
{{- end -}}
{{- end -}}

{{- define "synapse-admin.validate" -}}
{{- if and .Values.route.enabled (not .Values.route.host) -}}
{{- fail "route.enabled is on and route.host is empty. Set the hostname the route answers on." -}}
{{- end -}}
{{- if and .Values.route.enabled .Values.route.listenerSet.enabled .Values.route.listenerSet.attachTo -}}
{{- fail "route.listenerSet.enabled and route.listenerSet.attachTo exclude each other: the chart either makes its own ListenerSet or joins an existing one." -}}
{{- end -}}
{{- if and .Values.route.enabled .Values.route.listenerSet.enabled -}}
{{- $_ := include "synapse-admin.route.tlsSecretName" . -}}
{{- end -}}
{{- if and .Values.adminApi.enabled (not .Values.adminApi.service.name) -}}
{{- fail "adminApi.enabled is on and adminApi.service.name is empty. Name the Service of the Synapse release, for example matrix-synapse." -}}
{{- end -}}
{{- if and .Values.ingress.enabled (not (include "synapse-admin.ingress.host" .)) -}}
{{- fail "ingress.enabled is on and there is no hostname to publish. Set ingress.host, or leave it empty and set route.host, which it falls back to." -}}
{{- end -}}
{{- end -}}
