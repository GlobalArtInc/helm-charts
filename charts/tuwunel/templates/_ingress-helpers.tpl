{{- define "tuwunel.paths" -}}
- /_matrix
- /_synapse/admin
{{- end -}}

{{- define "tuwunel.ingress.host" -}}
{{- required "ingress.host is not set. It is the name visitors type, with no scheme and no path. Pass --set ingress.host=example.org." .Values.ingress.host -}}
{{- end -}}

{{- define "tuwunel.route.host" -}}
{{- required "route.host is not set. It is the name visitors type, with no scheme and no path. Pass --set route.host=example.org." .Values.route.host -}}
{{- end -}}

{{- define "tuwunel.route.gatewayName" -}}
{{- required "route.gateway.name is not set. Name the Gateway this route attaches to." .Values.route.gateway.name -}}
{{- end -}}

{{- define "tuwunel.route.gatewayNamespace" -}}
{{- required "route.gateway.namespace is not set. Name the namespace of the Gateway this route attaches to." .Values.route.gateway.namespace -}}
{{- end -}}

{{- define "tuwunel.route.tlsSecretName" -}}
{{- if .Values.route.tls.certificate.enabled -}}
{{- default (printf "tls-%s" (include "tuwunel.fullname" .)) .Values.route.tls.secretName -}}
{{- else -}}
{{- required "route.tls.secretName is not set. Name the existing certificate Secret for this host, or set route.tls.certificate.enabled to order one." .Values.route.tls.secretName -}}
{{- end -}}
{{- end -}}
