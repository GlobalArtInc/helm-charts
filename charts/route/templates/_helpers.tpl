{{- define "route.name" -}}
{{- required "нужно задать name" .Values.name -}}
{{- end -}}

{{- define "route.secret" -}}
{{- default (printf "tls-%s" (include "route.name" .)) .Values.certificate.secretName -}}
{{- end -}}
