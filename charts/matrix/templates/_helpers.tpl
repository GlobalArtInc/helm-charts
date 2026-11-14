{{- define "tuwunel.name" -}}
{{- default "tuwunel" .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tuwunel.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "tuwunel.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "tuwunel.importName" -}}
{{- printf "%s-import" (include "tuwunel.fullname" . | trunc 56 | trimSuffix "-") -}}
{{- end -}}

{{- define "tuwunel.labels" -}}
app.kubernetes.io/name: {{ include "tuwunel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ default .Chart.AppVersion .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "tuwunel.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tuwunel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "tuwunel.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
{{- end -}}

{{- define "tuwunel.pvcName" -}}
{{- default (printf "%s-data" (include "tuwunel.fullname" .)) .Values.persistence.existingClaim -}}
{{- end -}}

{{- define "tuwunel.validate" -}}
{{- if not .Values.serverName -}}
{{- fail "serverName is not set. It is the domain in every Matrix ID on this server (@user:<serverName>) and the server will not start without it. Pass --set serverName=example.org." -}}
{{- end -}}

{{- if gt (int .Values.replicaCount) 1 -}}
{{- fail (printf "replicaCount is %d. Tuwunel keeps its database in RocksDB on one volume, and a second process on that database is not supported. Set replicaCount to 0 or 1." (int .Values.replicaCount)) -}}
{{- end -}}

{{- if and .Values.import.enabled (gt (int .Values.replicaCount) 0) -}}
{{- fail "import.enabled is on and replicaCount is above 0. The import Job writes into the same database the server runs on, so the server has to be stopped first: set replicaCount to 0 for the import, then back to 1 once it has finished." -}}
{{- end -}}

{{- if and .Values.route.enabled .Values.ingress.enabled -}}
{{- fail "route.enabled and ingress.enabled are both on. Both would publish this server, and which one answers is decided by DNS. Turn one of them off." -}}
{{- end -}}

{{- if and .Values.media.s3.enabled (not .Values.media.s3.existingSecret) -}}
{{- fail "media.s3.enabled is on and media.s3.existingSecret is not set. The S3 access and secret keys reach the pod from that Secret. Name the Secret that holds them." -}}
{{- end -}}

{{- if and .Values.media.s3.enabled (not .Values.media.s3.bucket) -}}
{{- fail "media.s3.enabled is on and media.s3.bucket is not set. Name the bucket that holds the media." -}}
{{- end -}}

{{- if not (regexMatch "^[a-z][a-z0-9_]*$" .Values.media.s3.providerName) -}}
{{- fail (printf "media.s3.providerName is %q. Use lowercase letters, digits and underscores, starting with a letter. The name becomes part of an environment variable name, so dots and capitals break it." .Values.media.s3.providerName) -}}
{{- end -}}

{{- if and .Values.ingress.blockedPaths (not .Values.ingress.enabled) -}}
{{- fail "ingress.blockedPaths is set and ingress.enabled is off. The blocks are rendered with the Ingress, so nothing would be blocked. Turn ingress.enabled on or clear ingress.blockedPaths." -}}
{{- end -}}

{{- range $index, $path := .Values.ingress.blockedPaths -}}
{{- if not (or (hasPrefix "/" $path) (hasPrefix "^/" $path)) -}}
{{- fail (printf "ingress.blockedPaths[%d] is %q. Each blocked path is a regular expression that starts with / or ^/." $index $path) -}}
{{- end -}}
{{- if regexMatch `[\s";{}]` $path -}}
{{- fail (printf "ingress.blockedPaths[%d] is %q. It must not contain a quote, a space, ';', '{' or '}'." $index $path) -}}
{{- end -}}
{{- $_ := mustRegexMatch $path "" -}}
{{- end -}}

{{- if and .Values.appservices.existingSecret .Values.appservices.registrations -}}
{{- fail "appservices.existingSecret and appservices.registrations are both set. The chart mounts the existing Secret and ignores registrations. Keep one of them." -}}
{{- end -}}
{{- end -}}

{{- define "tuwunel.import.foldCaseScript" -}}
root=/synapse-media/local_content
cd "$root"
list="$(mktemp)"
find . -mindepth 3 -maxdepth 3 -type f | sed 's#^\./##' | awk -F/ '
{
  c1 = substr($1, 1, 1); c2 = substr($1, 2, 1)
  a[1] = tolower(c1); a[2] = toupper(c1); b[1] = tolower(c2); b[2] = toupper(c2)
  for (i = 1; i <= 2; i++) for (j = 1; j <= 2; j++) {
    v = a[i] b[j]
    if (v != $1) print v "/" $2 "/" $3 "\t" $0
  }
}' | sort -u > "$list"
made=0
while IFS="$(printf '\t')" read -r target source; do
  if [ ! -e "$target" ]; then
    mkdir -p "$(dirname "$target")"
    ln -s "$PWD/$source" "$target"
    made=$((made + 1))
  fi
done < "$list"
echo "case variants linked: $made"
{{- end -}}
