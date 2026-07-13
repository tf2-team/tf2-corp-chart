{{/*
Expand the name of the chart.
*/}}
{{- define "techx-corp.name" -}}
{{- default .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "techx-corp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "techx-corp.labels" -}}
helm.sh/chart: {{ include "techx-corp.chart" . }}
{{ include "techx-corp.selectorLabels" . }}
{{ include "techx-corp.workloadLabels" . }}
app.kubernetes.io/part-of: techx-corp
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}



{{/*
Workload (Pod) labels
*/}}
{{- define "techx-corp.workloadLabels" -}}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- if .name }}
app.kubernetes.io/component: {{ .name}}
app.kubernetes.io/name: {{ .name }}
{{- end }}
{{- end }}




{{/*
Selector labels
*/}}
{{- define "techx-corp.selectorLabels" -}}
{{- if .name }}
opentelemetry.io/name: {{ .name }}
{{- end }}
{{- end }}

{{- define "techx-corp.envOverriden" -}}
{{- $mergedEnvs := list }}
{{- $envOverrides := default (list) .envOverrides }}

{{- range .env }}
{{-   $currentEnv := . }}
{{-   $hasOverride := false }}
{{-   range $envOverrides }}
{{-     if eq $currentEnv.name .name }}
{{-       $mergedEnvs = append $mergedEnvs . }}
{{-       $envOverrides = without $envOverrides . }}
{{-       $hasOverride = true }}
{{-     end }}
{{-   end }}
{{-   if not $hasOverride }}
{{-     $mergedEnvs = append $mergedEnvs $currentEnv }}
{{-   end }}
{{- end }}
{{- $mergedEnvs = concat $mergedEnvs $envOverrides }}
{{- mustToJson $mergedEnvs }}
{{- end }}

{{/*
Create the name of the service account to use.

Resolution order (SEC-03 least-privilege):
  1. If the component declares its own serviceAccount (.componentServiceAccount),
     use that identity. Default name falls back to the component name so each
     workload gets a distinct, auditable service account.
  2. Otherwise fall back to the global serviceAccount for backwards compatibility.
IRSA annotations are never propagated from global down to a component; they must
be declared explicitly on the identity that needs AWS access.
*/}}
{{- define "techx-corp.serviceAccountName" -}}
{{- if .componentServiceAccount -}}
{{- if .componentServiceAccount.create -}}
{{- default .name .componentServiceAccount.name -}}
{{- else -}}
{{- default "default" .componentServiceAccount.name -}}
{{- end -}}
{{- else -}}
{{- if .serviceAccount.create -}}
{{- default (include "techx-corp.name" .) .serviceAccount.name -}}
{{- else -}}
{{- default "default" .serviceAccount.name -}}
{{- end -}}
{{- end -}}
{{- end }}
