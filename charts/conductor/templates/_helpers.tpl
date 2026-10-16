{{- define "conductor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "conductor.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "conductor.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "conductor.labels" -}}
app.kubernetes.io/name: {{ include "conductor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ default .Chart.AppVersion .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "conductor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "conductor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "conductor.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}

{{- define "conductor.postgres.secretName" -}}
{{- default (printf "%s-postgres" (include "conductor.fullname" .)) .Values.postgres.existingSecret -}}
{{- end -}}

{{- define "conductor.postgres.secretKey" -}}
{{- if .Values.postgres.existingSecret -}}
{{- .Values.postgres.existingSecretKey -}}
{{- else -}}
password
{{- end -}}
{{- end -}}

{{- define "conductor.elasticsearch.secretName" -}}
{{- default (printf "%s-elasticsearch" (include "conductor.fullname" .)) .Values.elasticsearch.existingSecret -}}
{{- end -}}

{{- define "conductor.elasticsearch.secretKey" -}}
{{- if .Values.elasticsearch.existingSecret -}}
{{- .Values.elasticsearch.existingSecretKey -}}
{{- else -}}
password
{{- end -}}
{{- end -}}

{{- define "conductor.elasticsearch.hasPassword" -}}
{{- if and .Values.elasticsearch.enabled (or .Values.elasticsearch.existingSecret .Values.elasticsearch.password) -}}
true
{{- end -}}
{{- end -}}

{{- define "conductor.ingress.host" -}}
{{- default .Values.route.host .Values.ingress.host -}}
{{- end -}}

{{- define "conductor.route.tlsSecretName" -}}
{{- if .Values.route.tls.certificate.enabled -}}
{{- default (printf "tls-%s" (include "conductor.fullname" .)) .Values.route.tls.secretName -}}
{{- else -}}
{{- required "route.tls.secretName is not set. Name the existing certificate Secret for this host, or set route.tls.certificate.enabled to order one, or set route.listenerSet.enabled to false to attach the route to a gateway listener that already terminates TLS." .Values.route.tls.secretName -}}
{{- end -}}
{{- end -}}

{{- define "conductor.validate" -}}
{{- if not .Values.postgres.host -}}
{{- fail "postgres.host is not set. Conductor keeps workflows and queues in PostgreSQL and the database has to exist before the first start; the schema is created by the server." -}}
{{- end -}}
{{- if and (not .Values.postgres.existingSecret) (not .Values.postgres.password) -}}
{{- fail "postgres.password is empty and postgres.existingSecret is not set, so there is no password for the database. Pass postgres.password, or point postgres.existingSecret at a Secret holding it under postgres.existingSecretKey." -}}
{{- end -}}
{{- if and .Values.elasticsearch.enabled (not .Values.elasticsearch.url) -}}
{{- fail "elasticsearch.url is not set. Search in the UI needs Elasticsearch; set elasticsearch.enabled to false to run without it." -}}
{{- end -}}
{{- if not (has .Values.lock.type (list "none" "local_only" "redis")) -}}
{{- fail "lock.type must be none, local_only or redis." -}}
{{- end -}}
{{- if and (eq .Values.lock.type "redis") (not .Values.lock.redis.address) -}}
{{- fail "lock.redis.address is not set, and lock.type is redis. It is a redis:// URL, for example redis://redis:6379." -}}
{{- end -}}
{{- if and (gt (int .Values.replicaCount) 1) (ne .Values.lock.type "redis") -}}
{{- fail (printf "replicaCount is %d and lock.type is %s. Several server instances need a distributed lock so that two of them do not decide the same workflow at once; set lock.type to redis, or run one replica." (int .Values.replicaCount) .Values.lock.type) -}}
{{- end -}}
{{- if .Values.route.enabled -}}
{{- if not .Values.route.host -}}
{{- fail "route.host is not set. It is the hostname visitors type, no scheme and no path. Set route.enabled to false to publish this some other way." -}}
{{- end -}}
{{- if .Values.route.listenerSet.enabled -}}
{{- $_ := include "conductor.route.tlsSecretName" . -}}
{{- end -}}
{{- end -}}
{{- if and .Values.ingress.enabled (not (include "conductor.ingress.host" .)) -}}
{{- fail "ingress.enabled is on and there is no hostname to publish. Set ingress.host, or leave it empty and set route.host, which it falls back to." -}}
{{- end -}}
{{- end -}}
