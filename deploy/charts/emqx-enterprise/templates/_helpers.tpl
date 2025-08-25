{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "emqx.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | replace "." "-" | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "emqx.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | replace "." "-" | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | replace "." "-" | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "emqx.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{/*
Get ssl secret name .
*/}}
{{- define "emqx.ssl.secretName" -}}
{{- if and .Values.ssl.useExisting .Values.ssl.existingName -}}
    {{ .Values.ssl.existingName }}
{{- else -}}
    {{ include "emqx.fullname" . }}-tls
{{- end -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "emqx.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "emqx.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
