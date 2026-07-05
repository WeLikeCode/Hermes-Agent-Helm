{{- define "hermes.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hermes.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if eq .Release.Name $name -}}
{{- $name -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "hermes.labels" -}}
app.kubernetes.io/name: {{ include "hermes.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "hermes.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hermes.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "hermes.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "hermes.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- /*
Hermes app image ref. Tolerates an empty digest (falls back to
repository:tag) only because values.image.digest is a WP012-task-3
placeholder at authoring time; production use should always resolve to
repository:tag@digest, same convention as charts/demo.
*/ -}}
{{- define "hermes.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s:%s@%s" .Values.image.repository .Values.image.tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{- define "hermes.initImage" -}}
{{- printf "%s:%s@%s" .Values.initContainer.image.repository .Values.initContainer.image.tag .Values.initContainer.image.digest -}}
{{- end -}}

{{- define "hermes.dashboardProxyImage" -}}
{{- if .Values.dashboardProxy.image.digest -}}
{{- printf "%s:%s@%s" .Values.dashboardProxy.image.repository .Values.dashboardProxy.image.tag .Values.dashboardProxy.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.dashboardProxy.image.repository .Values.dashboardProxy.image.tag -}}
{{- end -}}
{{- end -}}

{{- /*
Name Kubernetes assigns to the PVC generated from the StatefulSet's
volumeClaimTemplate named "data": "<templateName>-<statefulsetName>-<ordinal>".
Used by the backup CronJob to mount the same primary data volume read-only.
*/ -}}
{{- define "hermes.dataPVCName" -}}
{{- printf "data-%s-0" (include "hermes.fullname" .) -}}
{{- end -}}
