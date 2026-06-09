{{/*
Fully qualified app name. Truncated to 63 chars (k8s label limit).
If release name already contains chart name, avoid duplication.
*/}}
{{- define "identity-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart label: name-version (used in helm.sh/chart label)
*/}}
{{- define "identity-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels — used in matchLabels (must be stable, never change after first deploy)
*/}}
{{- define "identity-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
All labels — selector labels + extras (version, managed-by)
*/}}
{{- define "identity-service.labels" -}}
helm.sh/chart: {{ include "identity-service.chart" . }}
{{ include "identity-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "identity-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "identity-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
