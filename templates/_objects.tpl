{{/*
Demo component Deployment template
*/}}
{{- define "techx-corp.deployment" }}
---
apiVersion: apps/v1
kind: {{ if .stateful }}StatefulSet{{ else }}Deployment{{ end }}
metadata:
  name: {{ .name }}
  labels:
    {{- include "techx-corp.labels" . | nindent 4 }}
spec:
  {{- if not (and .autoscaling .autoscaling.enabled) }}
  replicas: {{ .replicas | default .defaultValues.replicas }}
  {{- end }}
  revisionHistoryLimit: {{ .revisionHistoryLimit | default .defaultValues.revisionHistoryLimit }}
  {{- $rollout := mergeOverwrite (dict) (deepCopy (default dict .defaultValues.rollout)) (deepCopy (default dict .rollout)) }}
  {{- if $rollout.strategy }}
  strategy:
    {{- $rollout.strategy | toYaml | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" $rollout.minReadySeconds) }}
  minReadySeconds: {{ $rollout.minReadySeconds }}
  {{- end }}
  {{- if not (kindIs "invalid" $rollout.progressDeadlineSeconds) }}
  progressDeadlineSeconds: {{ $rollout.progressDeadlineSeconds }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "techx-corp.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "techx-corp.selectorLabels" . | nindent 8 }}
        {{- include "techx-corp.workloadLabels" . | nindent 8 }}
        {{- if .podLabels }}
        {{- toYaml .podLabels | nindent 8 }}
        {{- end }}
      {{- if .podAnnotations }}
      annotations:
        {{- toYaml .podAnnotations | nindent 8 }}
      {{- end }}
    spec:
      {{- if .terminationGracePeriodSeconds }}
      terminationGracePeriodSeconds: {{ .terminationGracePeriodSeconds }}
      {{- end }}
      {{- if or .defaultValues.image.pullSecrets ((.imageOverride).pullSecrets) }}
      imagePullSecrets:
        {{- ((.imageOverride).pullSecrets) | default .defaultValues.image.pullSecrets | toYaml | nindent 8}}
      {{- end }}
      serviceAccountName: {{ include "techx-corp.serviceAccountName" .}}
      {{- $schedulingRules := .schedulingRules | default dict }}
      {{- if or .defaultValues.schedulingRules.nodeSelector $schedulingRules.nodeSelector}}
      nodeSelector:
        {{- $schedulingRules.nodeSelector | default .defaultValues.schedulingRules.nodeSelector | toYaml | nindent 8 }}
      {{- end }}
      {{- if or .defaultValues.schedulingRules.affinity $schedulingRules.affinity}}
      affinity:
        {{- $schedulingRules.affinity | default .defaultValues.schedulingRules.affinity | toYaml | nindent 8 }}
      {{- end }}
      {{- if or .defaultValues.schedulingRules.tolerations $schedulingRules.tolerations}}
      tolerations:
        {{- $schedulingRules.tolerations | default .defaultValues.schedulingRules.tolerations | toYaml | nindent 8 }}
      {{- end }}
      {{- $podSecurityContext := mergeOverwrite (dict) (default dict .defaultValues.podSecurityContext) (default dict .podSecurityContext) }}
      {{- if not (empty $podSecurityContext) }}
      securityContext:
        {{- $podSecurityContext | toYaml | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .name }}
          image: '{{ ((.imageOverride).repository) | default .defaultValues.image.repository }}:{{ ((.imageOverride).tag) | default (printf "%s-%s" (default .Chart.AppVersion .defaultValues.image.tag) .name) }}'
          imagePullPolicy: {{ ((.imageOverride).pullPolicy) | default .defaultValues.image.pullPolicy }}
          {{- if .command }}
          command:
            {{- .command | toYaml | nindent 12 -}}
          {{- end }}
          {{- if or .ports .service}}
          ports:
            {{- include "techx-corp.pod.ports" . | nindent 12 }}
          {{- end }}
          env:
            {{- include "techx-corp.pod.env" . | nindent 12 }}
          resources:
            {{- .resources | toYaml | nindent 12 }}
          {{- $securityContext := mergeOverwrite (dict) (default dict .defaultValues.securityContext) (default dict .securityContext) }}
          {{- if not (empty $securityContext) }}
          securityContext:
            {{- $securityContext | toYaml | nindent 12 }}
          {{- end }}
          {{- if .startupProbe }}
          startupProbe:
            {{- .startupProbe | toYaml | nindent 12 }}
          {{- end }}
          {{- if .livenessProbe }}
          livenessProbe:
            {{- .livenessProbe | toYaml | nindent 12 }}
          {{- end }}
          {{- if .readinessProbe }}
          readinessProbe:
            {{- .readinessProbe | toYaml | nindent 12 }}
          {{- end }}
          volumeMounts:
            {{- if .additionalVolumeMounts }}
            {{- tpl (toYaml .additionalVolumeMounts) . | nindent 12 }}
            {{- end }}
          {{- range .mountedConfigMaps }}
            - name: {{ .name | lower }}
              mountPath: {{ .mountPath }}
              {{- if .subPath }}
              subPath: {{ .subPath }}
              {{- end }}
          {{- end }}
          {{- range .mountedEmptyDirs }}
            - name: {{ .name | lower }}
              mountPath: {{ .mountPath }}
              {{- if .subPath }}
              subPath: {{ .subPath }}
              {{- end }}
          {{- end }}
        {{- range .sidecarContainers }}
        {{- $sidecar := set . "name" (.name | lower)}}
        {{- $sidecar := set . "Chart" $.Chart }}
        {{- $sidecar := set . "Release" $.Release }}
        {{- $sidecar := set . "defaultValues" $.defaultValues }}
        - name: {{ .name   }}
          image: '{{ ((.imageOverride).repository) | default .defaultValues.image.repository }}:{{ ((.imageOverride).tag) | default (printf "%s-%s" (default .Chart.AppVersion .defaultValues.image.tag) .name) }}'
          imagePullPolicy: {{ ((.imageOverride).pullPolicy) | default .defaultValues.image.pullPolicy }}
          {{- if .command }}
          command:
            {{- .command | toYaml | nindent 12 -}}
          {{- end }}
          {{- if or .ports .service }}
          ports:
            {{- include "techx-corp.pod.ports" . | nindent 12 }}
          {{- end }}
          env:
            {{- include "techx-corp.pod.env" . | nindent 12 }}
          {{- if .resources }}
          resources:
            {{- .resources | toYaml | nindent 12 }}
          {{- end }}
          {{- $sidecarSecurityContext := mergeOverwrite (dict) (default dict .defaultValues.securityContext) (default dict .securityContext) }}
          {{- if not (empty $sidecarSecurityContext) }}
          securityContext:
            {{- $sidecarSecurityContext | toYaml | nindent 12 }}
          {{- end }}
          {{- if .startupProbe }}
          startupProbe:
            {{- .startupProbe | toYaml | nindent 12 }}
          {{- end }}
          {{- if .livenessProbe }}
          livenessProbe:
            {{- .livenessProbe | toYaml | nindent 12 }}
          {{- end }}
          {{- if .readinessProbe }}
          readinessProbe:
            {{- .readinessProbe | toYaml | nindent 12 }}
          {{- end }}
          {{- if .volumeMounts }}
          volumeMounts:
            {{- .volumeMounts | toYaml | nindent 12 }}
          {{- end }}
        {{- end }}
      {{- if .initContainers }}
      initContainers:
        {{- range $initContainer := .initContainers }}
        {{- $mergedSecurityContext := mergeOverwrite (dict) (default dict $.defaultValues.initContainerSecurityContext) (default dict $initContainer.securityContext) }}
        {{- $c := mergeOverwrite (dict) $initContainer }}
        {{- if not (empty $mergedSecurityContext) }}
        {{- $c = mergeOverwrite $c (dict "securityContext" $mergedSecurityContext) }}
        {{- else }}
        {{- $c = omit $c "securityContext" }}
        {{- end }}
        {{- tpl (toYaml (list $c)) $ | nindent 8 }}
        {{- end }}
      {{- end }}
      volumes:
        {{- range .mountedConfigMaps }}
        - name: {{ .name | lower}}
          configMap:
            {{- if .existingConfigMap }}
            name: {{ tpl .existingConfigMap $ }}
            {{- else }}
            name: {{ $.name }}-{{ .name | lower }}
            {{- end }}
        {{- end }}
        {{- range .mountedEmptyDirs }}
        - name: {{ .name | lower}}
          emptyDir: {}
        {{- end }}
        {{- if .additionalVolumes }}
        {{- tpl (toYaml .additionalVolumes) . | nindent 8 }}
        {{- end }}
  {{- if and .stateful .volumeClaimTemplates }}
  volumeClaimTemplates:
    {{- tpl (toYaml .volumeClaimTemplates) . | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
Demo component Service template
*/}}
{{- define "techx-corp.service" }}
{{- if or .ports .service}}
{{- $service := .service | default dict }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  labels:
    {{- include "techx-corp.labels" . | nindent 4 }}
  {{- with $service.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ $service.type | default "ClusterIP" }}
  ports:
    {{- if .ports }}
    {{- range .ports }}
    - port: {{ .value }}
      name: {{ .name}}
      targetPort: {{ .value }}
    {{- end }}
    {{- end }}

    {{- if and .service .service.port }}
    - port: {{ .service.port}}
      name: tcp-service
      targetPort: {{ .service.port }}
    {{- if .service.nodePort }}
      nodePort: {{ .service.nodePort }}
    {{- end }}
    {{- end }}

    {{- range $i, $sidecar := .sidecarContainers }}
    {{- if .ports }}
    {{- range .ports }}
    - port: {{ .value }}
      name: {{ .name}}
      targetPort: {{ .value }}
    {{- end }}
    {{- end }}

    {{- if and .service .service.port }}
    - port: {{ .service.port}}
      name: tcp-service-{{ $i }}
      targetPort: {{ .service.port }}
    {{- if .service.nodePort }}
      nodePort: {{ .service.nodePort }}
    {{- end }}
    {{- end }}
    {{- end }}
  selector:
    {{- include "techx-corp.selectorLabels" . | nindent 4 }}
{{- end}}
{{- end}}

{{/*
Demo component ConfigMap template
*/}}
{{- define "techx-corp.configmap" }}
{{- range .mountedConfigMaps }}
{{- if .data }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $.name }}-{{ .name | lower }}
  labels:
        {{- include "techx-corp.labels" $ | nindent 4 }}
data:
  {{- .data | toYaml | nindent 2}}
{{- end}}
{{- end}}
{{- end}}

{{/*
Demo component Ingress template
*/}}
{{- define "techx-corp.ingress" }}
{{- $hasIngress := false}}
{{- if .ingress }}
{{- if .ingress.enabled }}
{{- $hasIngress = true }}
{{- end }}
{{- end }}
{{- $hasServicePorts := false}}
{{- if .service }}
{{- if .service.port }}
{{- $hasServicePorts = true }}
{{- end }}
{{- end }}
{{- if and $hasIngress (or .ports $hasServicePorts) }}
{{- $ingresses := list .ingress }}
{{- if .ingress.additionalIngresses }}
{{-   $ingresses := concat $ingresses .ingress.additionalIngresses -}}
{{- end }}
{{- range $ingresses }}
---
apiVersion: "networking.k8s.io/v1"
kind: Ingress
metadata:
  {{- if .name }}
  name: {{ $.name }}-{{ .name | lower }}
  {{- else }}
  name: {{ $.name }}
  {{- end }}
  labels:
    {{- include "techx-corp.labels" $ | nindent 4 }}
  {{- if .annotations }}
  annotations:
    {{ toYaml .annotations | nindent 4 }}
  {{- end }}
spec:
  {{- if .ingressClassName }}
  ingressClassName: {{ .ingressClassName }}
  {{- end -}}
  {{- if .tls }}
  tls:
    {{- range .tls }}
    - hosts:
        {{- range .hosts }}
        - {{ . | quote }}
        {{- end }}
      {{- with .secretName }}
      secretName: {{ . }}
      {{- end }}
    {{- end }}
  {{- end }}
  rules:
    {{- range .hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType }}
            backend:
              service:
                name: {{ $.name }}
                port:
                  number: {{ .port }}
          {{- end }}
    {{- end }}
{{- end}}
{{- end}}
{{- end}}

{{/*
Demo component HPA template
*/}}
{{- define "techx-corp.hpa" }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .name }}
  labels:
    {{- include "techx-corp.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ .name }}
  minReplicas: {{ .autoscaling.minReplicas | default 1 }}
  maxReplicas: {{ .autoscaling.maxReplicas | default 5 }}
  metrics:
    {{- if .autoscaling.targetCPUUtilizationPercentage }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .autoscaling.targetCPUUtilizationPercentage }}
    {{- end }}
    {{- if .autoscaling.targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .autoscaling.targetMemoryUtilizationPercentage }}
    {{- end }}
{{- end }}

