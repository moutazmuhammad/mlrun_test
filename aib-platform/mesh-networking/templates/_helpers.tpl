{{- define "mesh-networking.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mesh-networking.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cloud-platform
app.kubernetes.io/component: mesh-networking
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
