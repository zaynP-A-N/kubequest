{{/*
Common labels applied to every object in the chart.
Used like:  labels: {{- include "kubequest.labels" . | nindent 4 }}
*/}}
{{- define "kubequest.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
