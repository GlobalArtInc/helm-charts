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

{{- define "conductor.es.fullname" -}}
{{- printf "%s-es" (include "conductor.fullname" . | trunc 49 | trimSuffix "-") -}}
{{- end -}}

{{- define "conductor.es.headlessName" -}}
{{- printf "%s-headless" (include "conductor.es.fullname" .) -}}
{{- end -}}

{{- define "conductor.es.selectorLabels" -}}
app.kubernetes.io/name: {{ printf "%s-elasticsearch" (include "conductor.name" . | trunc 46 | trimSuffix "-") }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: elasticsearch
{{- end -}}

{{- define "conductor.es.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/version: {{ .Values.elasticsearch.cluster.image.tag | quote }}
{{ include "conductor.es.selectorLabels" . }}
{{- end -}}

{{- define "conductor.elasticsearch.url" -}}
{{- if .Values.elasticsearch.url -}}
{{- .Values.elasticsearch.url -}}
{{- else if .Values.elasticsearch.cluster.enabled -}}
{{- printf "http://%s:9200" (include "conductor.es.fullname" .) -}}
{{- end -}}
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

{{- define "conductor.oauth2Proxy.serviceName" -}}
{{- printf "%s-auth" (include "conductor.fullname" . | trunc 58 | trimSuffix "-") -}}
{{- end -}}

{{- define "conductor.backendServiceName" -}}
{{- if .Values.oauth2Proxy.enabled -}}
{{- include "conductor.oauth2Proxy.serviceName" . -}}
{{- else -}}
{{- include "conductor.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "conductor.oauth2Proxy.secretName" -}}
{{- default (printf "%s-oauth2-proxy" (include "conductor.fullname" .)) .Values.oauth2Proxy.existingSecret -}}
{{- end -}}

{{- define "conductor.oauth2Proxy.clientSecretKey" -}}
{{- if .Values.oauth2Proxy.existingSecret -}}
{{- .Values.oauth2Proxy.existingSecretClientKey -}}
{{- else -}}
client-secret
{{- end -}}
{{- end -}}

{{- define "conductor.oauth2Proxy.cookieSecretKey" -}}
{{- if .Values.oauth2Proxy.existingSecret -}}
{{- .Values.oauth2Proxy.existingSecretCookieKey -}}
{{- else -}}
cookie-secret
{{- end -}}
{{- end -}}

{{- define "conductor.oauth2Proxy.host" -}}
{{- if .Values.route.enabled -}}
{{- .Values.route.host -}}
{{- else if .Values.ingress.enabled -}}
{{- include "conductor.ingress.host" . -}}
{{- end -}}
{{- end -}}

{{- define "conductor.oauth2Proxy.redirectUrl" -}}
{{- default (printf "https://%s/oauth2/callback" (include "conductor.oauth2Proxy.host" .)) .Values.oauth2Proxy.oidc.redirectUrl -}}
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
{{- if and .Values.elasticsearch.enabled (not .Values.elasticsearch.url) (not .Values.elasticsearch.cluster.enabled) -}}
{{- fail "elasticsearch.url is not set and elasticsearch.cluster.enabled is off, so there is no Elasticsearch for the server to use. Search in the UI needs one: set elasticsearch.url to an existing 7.x cluster, or set elasticsearch.cluster.enabled to run one from this chart, or set elasticsearch.enabled to false to run without it." -}}
{{- end -}}
{{- if and .Values.elasticsearch.enabled .Values.elasticsearch.cluster.enabled -}}
{{- $cluster := .Values.elasticsearch.cluster -}}
{{- $replicas := int $cluster.replicas -}}
{{- $quorum := add (div $replicas 2) 1 -}}
{{- if not (or (eq $replicas 1) (and (ge $replicas 3) (eq (mod $replicas 2) 1))) -}}
{{- fail (printf "elasticsearch.cluster.replicas is %d. It has to be 1, or an odd number from 3 up: with two nodes the loss of either one leaves no majority of master-eligible nodes and the cluster stops accepting writes, so the second node adds a failure and no safety." $replicas) -}}
{{- end -}}
{{- if kindIs "invalid" .Values.elasticsearch.indexReplicasCount -}}
{{- fail (printf "elasticsearch.indexReplicasCount is not set, and elasticsearch.cluster.enabled is on. Set it to the number of replica shards per index, at most %d (elasticsearch.cluster.replicas minus one; 0 for a single node). Left unset, the server asks for one replica, which a single node cannot place, and an index with an unassigned replica keeps the cluster yellow." (sub $replicas 1)) -}}
{{- end -}}
{{- if gt (int .Values.elasticsearch.indexReplicasCount) (sub $replicas 1) -}}
{{- fail (printf "elasticsearch.indexReplicasCount is %d and elasticsearch.cluster.replicas is %d. A shard and its replica never share a node, so %d replicas per index need %d nodes. The surplus replicas stay unassigned, the cluster stays yellow and the readiness probe of a restarted pod never passes; set indexReplicasCount to at most %d, or add nodes." (int .Values.elasticsearch.indexReplicasCount) $replicas (int .Values.elasticsearch.indexReplicasCount) (add (int .Values.elasticsearch.indexReplicasCount) 1) (sub $replicas 1)) -}}
{{- end -}}
{{- if not (has $cluster.antiAffinity (list "hard" "soft" "none")) -}}
{{- fail "elasticsearch.cluster.antiAffinity must be hard, soft or none. hard keeps two Elasticsearch pods off one node and leaves a pod pending when there is no free node; soft only prefers that; none does not care." -}}
{{- end -}}
{{- if and $cluster.pdb.enabled (ge $replicas 3) (gt (int $cluster.pdb.minAvailable) (sub $replicas 1)) -}}
{{- fail (printf "elasticsearch.cluster.pdb.minAvailable is %d and elasticsearch.cluster.replicas is %d. The budget has to leave room for one pod to be evicted, or a node drain can never finish; set minAvailable to at most %d, or turn elasticsearch.cluster.pdb.enabled off." (int $cluster.pdb.minAvailable) $replicas (sub $replicas 1)) -}}
{{- end -}}
{{- if and $cluster.pdb.enabled (ge $replicas 3) (lt (int $cluster.pdb.minAvailable) $quorum) -}}
{{- fail (printf "elasticsearch.cluster.pdb.minAvailable is %d and elasticsearch.cluster.replicas is %d, so the budget is below the quorum of %d master-eligible nodes. A drain that is allowed to go that low can leave too few nodes to elect a master, and the cluster stops accepting writes; set minAvailable to at least %d, the quorum, and at most %d." (int $cluster.pdb.minAvailable) $replicas $quorum $quorum (sub $replicas 1)) -}}
{{- end -}}
{{- if not (kindIs "slice" $cluster.joinSeedHosts) -}}
{{- fail "elasticsearch.cluster.joinSeedHosts must be a list of host names, for example the headless Service of the cluster to join. It is empty for a cluster that starts on its own." -}}
{{- end -}}
{{- range $cluster.joinSeedHosts -}}
{{- if not (kindIs "string" .) -}}
{{- fail "elasticsearch.cluster.joinSeedHosts must hold strings only: each entry is a host name or host:port of a node, or of a headless Service, of the cluster to join." -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.lock.type (list "none" "local_only" "redis" "postgres")) -}}
{{- fail "lock.type must be none, local_only, redis or postgres." -}}
{{- end -}}
{{- if and (eq .Values.lock.type "redis") (not .Values.lock.redis.address) -}}
{{- fail "lock.redis.address is not set, and lock.type is redis. It is a redis:// URL, for example redis://redis:6379." -}}
{{- end -}}
{{- if and (gt (int .Values.replicaCount) 1) (not (has .Values.lock.type (list "redis" "postgres"))) -}}
{{- fail (printf "replicaCount is %d and lock.type is %s. Several server instances need a distributed lock so that two of them do not decide the same workflow at once; set lock.type to postgres or redis, or run one replica." (int .Values.replicaCount) .Values.lock.type) -}}
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
{{- if .Values.oauth2Proxy.enabled -}}
{{- $proxy := .Values.oauth2Proxy -}}
{{- if not $proxy.oidc.issuerUrl -}}
{{- fail "oauth2Proxy.oidc.issuerUrl is not set, and oauth2Proxy.enabled is on. It is the OIDC issuer the proxy reads its endpoints from, for a Keycloak realm https://keycloak.example/auth/realms/<realm>." -}}
{{- end -}}
{{- if not $proxy.oidc.clientId -}}
{{- fail "oauth2Proxy.oidc.clientId is not set, and oauth2Proxy.enabled is on. It is the ID of the client registered for this host at the identity provider. It is needed with oauth2Proxy.existingSecret too: that Secret holds only the client secret and the cookie secret." -}}
{{- end -}}
{{- if and (not $proxy.existingSecret) (not (and $proxy.clientSecret $proxy.cookieSecret)) -}}
{{- fail "oauth2Proxy.existingSecret is not set and oauth2Proxy.clientSecret or oauth2Proxy.cookieSecret is empty, so the proxy has no client secret or no key for its session cookie. Pass both, or point oauth2Proxy.existingSecret at a Secret holding them under oauth2Proxy.existingSecretClientKey and oauth2Proxy.existingSecretCookieKey." -}}
{{- end -}}
{{- if not (or .Values.route.enabled .Values.ingress.enabled) -}}
{{- fail "oauth2Proxy.enabled is on and neither route.enabled nor ingress.enabled is. The proxy only guards the route and the ingress of this release; the Service inside the cluster stays open either way, so with neither there is nothing for it to guard. Turn one of them on, or turn oauth2Proxy.enabled off." -}}
{{- end -}}
{{- if ne .Values.service.type "ClusterIP" -}}
{{- fail (printf "service.type is %s, and oauth2Proxy.enabled is on. The Service %s asks for no login, and as a %s it is reachable from outside the cluster without going through the proxy. Keep service.type at ClusterIP and publish through route or ingress, which go through the proxy." .Values.service.type (include "conductor.fullname" .) .Values.service.type) -}}
{{- end -}}
{{- if and .Values.route.enabled .Values.ingress.enabled (ne .Values.route.host (include "conductor.ingress.host" .)) -}}
{{- fail (printf "route.host is %s and the ingress hostname is %s, and oauth2Proxy.enabled is on. The proxy sends every login back to route.host and lets it return to no other host, so a login started on the ingress host would end on the route host. Give both the same host (an empty ingress.host falls back to route.host), or turn one of them off." .Values.route.host (include "conductor.ingress.host" .)) -}}
{{- end -}}
{{- if and (not (include "conductor.oauth2Proxy.host" .)) (not $proxy.oidc.redirectUrl) -}}
{{- fail "oauth2Proxy.oidc.redirectUrl is not set and there is no hostname to make it from. It defaults to https://<host>/oauth2/callback, with route.host when route.enabled is on and with the ingress hostname otherwise; set that host, or set oauth2Proxy.oidc.redirectUrl." -}}
{{- end -}}
{{- if has (int $proxy.port) (list 8080 5000) -}}
{{- fail (printf "oauth2Proxy.port is %d. The proxy shares the pod's network with the server, which holds 8080 for the API and the UI and 5000 for its own nginx, so the proxy could not listen there; pick another port, 4180 by default." (int $proxy.port)) -}}
{{- end -}}
{{- with $proxy.cookieSecret -}}
{{- if not (or (has (len .) (list 16 24 32)) (regexMatch "^[A-Za-z0-9_-]{22}$" .) (regexMatch "^[A-Za-z0-9_-]{43}=?$" .)) -}}
{{- fail (printf "oauth2Proxy.cookieSecret is %d bytes long, and the proxy cannot make the AES key of its session cookie from it. It takes 16, 24 or 32 bytes as they are, or the URL-safe base64 of 16 or 32 bytes: 22, 43, or 44 characters ending in =, with - and _ where plain base64 has + and /. openssl rand -hex 16 prints a key of 32 bytes; openssl rand -base64 32 | tr -- '+/' '-_' prints one of 44 characters." (len .)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
