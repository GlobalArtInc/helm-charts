{{- define "matrix-hookshot.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "matrix-hookshot.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "matrix-hookshot.labels" -}}
{{ include "matrix-hookshot.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "matrix-hookshot.ingress.host" -}}
{{- default .Values.route.host .Values.ingress.host -}}
{{- end -}}

{{- define "matrix-hookshot.route.tlsSecretName" -}}
{{- if .Values.route.tls.certificate.enabled -}}
{{- default (printf "tls-%s" (include "matrix-hookshot.fullname" .)) .Values.route.tls.secretName -}}
{{- else -}}
{{- required "route.tls.secretName is not set. Name the existing certificate Secret for this host, or set route.tls.certificate.enabled to order one, or leave route.listenerSet.enabled off to attach the route to a listener that already terminates TLS." .Values.route.tls.secretName -}}
{{- end -}}
{{- end -}}

{{- define "matrix-hookshot.validate" -}}
{{- if and .Values.route.enabled (not .Values.route.host) -}}
{{- fail "route.enabled is on and route.host is empty. Set the hostname the route answers on." -}}
{{- end -}}
{{- if and .Values.route.enabled .Values.route.listenerSet.enabled .Values.route.listenerSet.attachTo -}}
{{- fail "route.listenerSet.enabled and route.listenerSet.attachTo exclude each other: the chart either makes its own ListenerSet or joins an existing one." -}}
{{- end -}}
{{- if and .Values.route.enabled .Values.route.listenerSet.enabled -}}
{{- $_ := include "matrix-hookshot.route.tlsSecretName" . -}}
{{- end -}}
{{- if and .Values.ingress.enabled (not (include "matrix-hookshot.ingress.host" .)) -}}
{{- fail "ingress.enabled is on and there is no hostname to publish. Set ingress.host, or leave it empty and set route.host, which it falls back to." -}}
{{- end -}}
{{- end -}}
