{{- define "tuwunel.podTemplate" -}}
metadata:
  annotations:
    checksum/config: {{ print (include (print $.Template.BasePath "/secret-config.yaml") .) (include (print $.Template.BasePath "/secret-appservices.yaml") .) | sha256sum }}
    {{- if .Values.backup.enabled }}
    checksum/backup: {{ include (print $.Template.BasePath "/configmap-backup.yaml") . | sha256sum }}
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  labels:
    {{- include "tuwunel.selectorLabels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}
  enableServiceLinks: {{ .Values.enableServiceLinks }}
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  {{- if .Values.backup.enabled }}
  shareProcessNamespace: true
  {{- end }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: tuwunel
      image: {{ include "tuwunel.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      args: ["-c", "/etc/tuwunel/tuwunel.toml"]
      env:
        - name: TUWUNEL_CONFIG
          value: /etc/tuwunel/tuwunel.toml
        {{- if .Values.media.s3.enabled }}
        - name: TUWUNEL_STORAGE_PROVIDER__{{ upper .Values.media.s3.providerName }}__S3__KEY
          valueFrom:
            secretKeyRef:
              name: {{ .Values.media.s3.existingSecret }}
              key: {{ .Values.media.s3.accessKeyKey }}
        - name: TUWUNEL_STORAGE_PROVIDER__{{ upper .Values.media.s3.providerName }}__S3__SECRET
          valueFrom:
            secretKeyRef:
              name: {{ .Values.media.s3.existingSecret }}
              key: {{ .Values.media.s3.secretKeyKey }}
        {{- end }}
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with .Values.extraEnvFrom }}
      envFrom:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      ports:
        - name: http
          containerPort: {{ .Values.service.port }}
          protocol: TCP
      {{- if .Values.warmCache.enabled }}
      lifecycle:
        postStart:
          exec:
            command: ["sh", "-c", {{ printf "(cat %s/*.sst > /dev/null 2>&1 &); exit 0" (.Values.warmCache.path | default "/var/lib/tuwunel") | quote }}]
      {{- end }}
      startupProbe:
        exec:
          command: {{ .Values.probes.startup.command | toJson }}
        periodSeconds: {{ .Values.probes.startup.periodSeconds }}
        failureThreshold: {{ .Values.probes.startup.failureThreshold }}
        timeoutSeconds: {{ .Values.probes.startup.timeoutSeconds }}
      livenessProbe:
        exec:
          command: {{ .Values.probes.liveness.command | toJson }}
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
        failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
        timeoutSeconds: {{ .Values.probes.liveness.timeoutSeconds }}
      readinessProbe:
        exec:
          command: {{ .Values.probes.readiness.command | toJson }}
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
        failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
        timeoutSeconds: {{ .Values.probes.readiness.timeoutSeconds }}
      {{- with .Values.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      volumeMounts:
        - name: data
          mountPath: /var/lib/tuwunel
        - name: config
          mountPath: /etc/tuwunel/tuwunel.toml
          subPath: tuwunel.toml
          readOnly: true
        {{- if or .Values.appservices.existingSecret .Values.appservices.registrations }}
        - name: appservices
          mountPath: /etc/tuwunel/appservices
          readOnly: true
        {{- end }}
        - name: tmp
          mountPath: /tmp
    {{- if .Values.backup.enabled }}
    - name: backup
      image: {{ .Values.backup.image.repository }}:{{ .Values.backup.image.tag }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: ["/bin/sh", "/scripts/backup.sh"]
      env:
        - name: HOME
          value: /tmp
        - name: BACKUP_DIR
          value: {{ .Values.backup.path | quote }}
        - name: S3_BUCKET
          value: {{ .Values.backup.s3.bucket | quote }}
        - name: S3_PREFIX
          value: {{ .Values.backup.s3.prefix | trimAll "/" | quote }}
        - name: INTERVAL_SECONDS
          value: {{ int .Values.backup.intervalSeconds | quote }}
        - name: INITIAL_DELAY_SECONDS
          value: {{ int .Values.backup.initialDelaySeconds | quote }}
        - name: RETRY_SECONDS
          value: {{ int .Values.backup.retrySeconds | quote }}
        - name: STARTUP_WAIT_SECONDS
          value: {{ int .Values.backup.startupWaitSeconds | quote }}
        - name: WAIT_SECONDS
          value: {{ int .Values.backup.waitSeconds | quote }}
        - name: SERVER_PORT
          value: {{ int .Values.service.port | quote }}
        - name: METRICS_PORT
          value: {{ int .Values.backup.metricsPort | quote }}
        - name: RCLONE_CONFIG_DEST_TYPE
          value: s3
        - name: RCLONE_CONFIG_DEST_PROVIDER
          value: Other
        - name: RCLONE_CONFIG_DEST_ENDPOINT
          value: {{ .Values.backup.s3.endpoint | quote }}
        - name: RCLONE_CONFIG_DEST_NO_CHECK_BUCKET
          value: "true"
        - name: RCLONE_CONFIG_DEST_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef:
              name: {{ .Values.backup.s3.existingSecret }}
              key: access-key
        - name: RCLONE_CONFIG_DEST_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: {{ .Values.backup.s3.existingSecret }}
              key: secret-key
      ports:
        - name: metrics
          containerPort: {{ int .Values.backup.metricsPort }}
          protocol: TCP
      {{- with .Values.backup.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      volumeMounts:
        - name: data
          mountPath: /var/lib/tuwunel
          readOnly: true
        - name: backup-metrics
          mountPath: /metrics
        - name: backup-script
          mountPath: /scripts
          readOnly: true
        - name: backup-tmp
          mountPath: /tmp
    {{- end }}
  volumes:
    - name: data
      {{- if .Values.persistence.enabled }}
      persistentVolumeClaim:
        claimName: {{ include "tuwunel.pvcName" . }}
      {{- else }}
      emptyDir: {}
      {{- end }}
    - name: config
      secret:
        secretName: {{ include "tuwunel.fullname" . }}-config
    {{- if or .Values.appservices.existingSecret .Values.appservices.registrations }}
    - name: appservices
      secret:
        secretName: {{ default (printf "%s-appservices" (include "tuwunel.fullname" .)) .Values.appservices.existingSecret }}
    {{- end }}
    - name: tmp
      emptyDir: {}
    {{- if .Values.backup.enabled }}
    - name: backup-metrics
      emptyDir: {}
    - name: backup-tmp
      emptyDir: {}
    - name: backup-script
      configMap:
        name: {{ include "tuwunel.fullname" . }}-backup
    {{- end }}
{{- end -}}
