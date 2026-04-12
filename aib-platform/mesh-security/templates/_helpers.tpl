{{- define "mesh-security.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mesh-security.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cloud-platform
app.kubernetes.io/component: mesh-security
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
