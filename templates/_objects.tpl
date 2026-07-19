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
  {{- /* hasKey so replicas: 0 is honored (Helm `default` treats 0 as empty). */}}
  {{- if hasKey . "replicas" }}
  replicas: {{ .replicas }}
  {{- else }}
  replicas: {{ .defaultValues.replicas }}
  {{- end }}
  {{- end }}
  revisionHistoryLimit: {{ .revisionHistoryLimit | default .defaultValues.revisionHistoryLimit }}
  {{- $rollout := mergeOverwrite (dict) (deepCopy (default dict .defaultValues.rollout)) (deepCopy (default dict .rollout)) }}
  {{- if not .stateful }}
  {{- if $rollout.strategy }}
  strategy:
    {{- $rollout.strategy | toYaml | nindent 4 }}
  {{- end }}
  {{- if not (kindIs "invalid" $rollout.progressDeadlineSeconds) }}
  progressDeadlineSeconds: {{ $rollout.progressDeadlineSeconds }}
  {{- end }}
  {{- else }}
  {{- /* Immutable after create. Must match live STS (e.g. opensearch has serviceName set). */}}
  serviceName: {{ .name }}
  {{- end }}
  {{- if not (kindIs "invalid" $rollout.minReadySeconds) }}
  minReadySeconds: {{ $rollout.minReadySeconds }}
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
      {{- /* OTEL logical service.namespace follows Helm release NS (dev/prod); values may override. */}}
      {{- $podAnnotations := mergeOverwrite (dict "resource.opentelemetry.io/service.namespace" .Release.Namespace) (default dict .podAnnotations) }}
      {{- if $podAnnotations }}
      annotations:
        {{- toYaml $podAnnotations | nindent 8 }}
      {{- end }}
    spec:
      {{- $terminationGracePeriodSeconds := .terminationGracePeriodSeconds | default .defaultValues.terminationGracePeriodSeconds }}
      {{- if $terminationGracePeriodSeconds }}
      terminationGracePeriodSeconds: {{ $terminationGracePeriodSeconds }}
      {{- end }}
      {{- if or .defaultValues.image.pullSecrets ((.imageOverride).pullSecrets) }}
      imagePullSecrets:
        {{- ((.imageOverride).pullSecrets) | default .defaultValues.image.pullSecrets | toYaml | nindent 8}}
      {{- end }}
      serviceAccountName: {{ include "techx-corp.serviceAccountName" .}}
      {{- /* Component schedulingRules keys fully replace defaults when present (including empty maps/lists). */}}
      {{- $schedDefaults := default dict .defaultValues.schedulingRules }}
      {{- $schedOverrides := default dict .schedulingRules }}
      {{- $nodeSelector := ternary $schedOverrides.nodeSelector $schedDefaults.nodeSelector (hasKey $schedOverrides "nodeSelector") | default dict }}
      {{- $affinity := ternary $schedOverrides.affinity $schedDefaults.affinity (hasKey $schedOverrides "affinity") | default dict }}
      {{- $tolerations := ternary $schedOverrides.tolerations $schedDefaults.tolerations (hasKey $schedOverrides "tolerations") | default list }}
      {{- $topologySpreadConstraints := ternary $schedOverrides.topologySpreadConstraints $schedDefaults.topologySpreadConstraints (hasKey $schedOverrides "topologySpreadConstraints") | default list }}
      {{- $componentName := .name }}
      {{- $isStateful := .stateful }}
      {{- if and $nodeSelector (gt (len $nodeSelector) 0) }}
      nodeSelector:
        {{- toYaml $nodeSelector | nindent 8 }}
      {{- end }}
      {{- if and $affinity (gt (len $affinity) 0) }}
      affinity:
        {{- toYaml $affinity | nindent 8 }}
      {{- end }}
      {{- if and $tolerations (gt (len $tolerations) 0) }}
      tolerations:
        {{- toYaml $tolerations | nindent 8 }}
      {{- end }}
      {{- /* Soft topology balancing only; does not replace nodeSelector/tolerations hard placement. */}}
      {{- if and $topologySpreadConstraints (gt (len $topologySpreadConstraints) 0) }}
      topologySpreadConstraints:
        {{- range $topologySpreadConstraints }}
        - maxSkew: {{ .maxSkew }}
          topologyKey: {{ .topologyKey }}
          whenUnsatisfiable: {{ .whenUnsatisfiable }}
          {{- if .minDomains }}
          minDomains: {{ .minDomains }}
          {{- end }}
          {{- if .labelSelector }}
          labelSelector:
            {{- toYaml .labelSelector | nindent 12 }}
          {{- else }}
          labelSelector:
            matchLabels:
              opentelemetry.io/name: {{ $componentName }}
          {{- end }}
          {{- if hasKey . "matchLabelKeys" }}
          {{- if .matchLabelKeys }}
          matchLabelKeys:
            {{- toYaml .matchLabelKeys | nindent 12 }}
          {{- end }}
          {{- else if not $isStateful }}
          matchLabelKeys:
            - pod-template-hash
          {{- end }}
        {{- end }}
      {{- end }}
      {{- $podSecurityContext := mergeOverwrite (dict) (default dict .defaultValues.podSecurityContext) (default dict .podSecurityContext) }}
      {{- if not (empty $podSecurityContext) }}
      securityContext:
        {{- $podSecurityContext | toYaml | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .name }}
          {{- /* Default: REGISTRY/PROJECT/SERVICE:VERSION
               Full override: imageOverride.repository (+ optional tag)
               Service rename only: imageOverride.name keeps default.image.repository/tag
               (e.g. load-generator-worker → …/load-generator:<global-tag>) */ -}}
          {{- if ((.imageOverride).repository) }}
          image: '{{ .imageOverride.repository }}:{{ ((.imageOverride).tag) | default (default .Chart.AppVersion .defaultValues.image.tag) }}'
          {{- else }}
          image: '{{ .defaultValues.image.repository }}/{{ ((.imageOverride).name) | default .name }}:{{ ((.imageOverride).tag) | default (default .Chart.AppVersion .defaultValues.image.tag) }}'
          {{- end }}
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
            {{- if and .modelDelivery .modelDelivery.enabled }}
            - name: HF_HOME
              value: {{ .modelDelivery.mountPath | quote }}
            - name: HF_HUB_OFFLINE
              value: "1"
            - name: TRANSFORMERS_OFFLINE
              value: "1"
            - name: AI_GUARDRAIL_REQUIRE_MODEL
              value: "true"
            {{- end }}
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
          {{- $preStopSleepSeconds := .preStopSleepSeconds | default .defaultValues.preStopSleepSeconds }}
          {{- if $preStopSleepSeconds }}
          # Native Kubernetes sleep hook: no shell/binary is required in the image.
          # It gives EndpointSlice/ALB target deregistration time before SIGTERM.
          lifecycle:
            preStop:
              sleep:
                seconds: {{ $preStopSleepSeconds }}
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
          {{- if and .modelDelivery .modelDelivery.enabled }}
            - name: ai-model-cache
              mountPath: {{ .modelDelivery.mountPath }}
              readOnly: true
          {{- end }}
        {{- range .sidecarContainers }}
        {{- $sidecar := set . "name" (.name | lower)}}
        {{- $sidecar := set . "Chart" $.Chart }}
        {{- $sidecar := set . "Release" $.Release }}
        {{- $sidecar := set . "defaultValues" $.defaultValues }}
        - name: {{ .name   }}
          {{- if ((.imageOverride).repository) }}
          image: '{{ .imageOverride.repository }}:{{ ((.imageOverride).tag) | default (default .Chart.AppVersion .defaultValues.image.tag) }}'
          {{- else }}
          image: '{{ .defaultValues.image.repository }}/{{ ((.imageOverride).name) | default .name }}:{{ ((.imageOverride).tag) | default (default .Chart.AppVersion .defaultValues.image.tag) }}'
          {{- end }}
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
      {{- if or .initContainers (and .modelDelivery .modelDelivery.enabled) }}
      initContainers:
        {{- if and .modelDelivery .modelDelivery.enabled }}
        {{/* aws-cli image has aws + sha256sum but no tar; extract in a second init. */}}
        - name: fetch-ai-guardrail-model
          image: {{ .modelDelivery.fetcherImage | quote }}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-ec"]
          args:
            - |
              archive=/tmp/model.tar.gz
              checksum=/tmp/model.tar.gz.sha256
              aws s3 cp {{ .modelDelivery.s3Uri | quote }} "$archive" --only-show-errors
              aws s3 cp {{ printf "%s.sha256" .modelDelivery.s3Uri | quote }} "$checksum" --only-show-errors
              cd /tmp
              # Windows-uploaded .sha256 files may use CRLF; strip CR so the
              # filename is model.tar.gz not model.tar.gz$'\r'.
              sed -i 's/\r$//' model.tar.gz.sha256
              sha256sum -c model.tar.gz.sha256
          env:
            - name: AWS_REGION
              value: {{ .modelDelivery.awsRegion | quote }}
            - name: AWS_EC2_METADATA_DISABLED
              value: "true"
            # AWS CLI caches web-identity credentials under $HOME/.aws. The
            # init container runs with readOnlyRootFilesystem; HOME must point
            # at the writable emptyDir mounted at /tmp (default HOME is /).
            - name: HOME
              value: /tmp
            - name: AWS_CONFIG_FILE
              value: /tmp/.aws/config
            - name: AWS_SHARED_CREDENTIALS_FILE
              value: /tmp/.aws/credentials
          resources:
            {{- .modelDelivery.resources | toYaml | nindent 12 }}
          securityContext:
            {{- mergeOverwrite (dict) (default dict .defaultValues.initContainerSecurityContext) | toYaml | nindent 12 }}
          volumeMounts:
            - name: tmp-dir
              mountPath: /tmp
        - name: extract-ai-guardrail-model
          image: {{ .modelDelivery.extractorImage | quote }}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-ec"]
          args:
            - |
              archive=/tmp/model.tar.gz
              mkdir -p /models
              tar -xzf "$archive" -C /models
              test -f /models/.model-ready
              rm -f "$archive" /tmp/model.tar.gz.sha256
          resources:
            {{- .modelDelivery.resources | toYaml | nindent 12 }}
          securityContext:
            {{- mergeOverwrite (dict) (default dict .defaultValues.initContainerSecurityContext) | toYaml | nindent 12 }}
          volumeMounts:
            - name: ai-model-cache
              mountPath: /models
            - name: tmp-dir
              mountPath: /tmp
        {{- end }}
        {{- range $initContainer := .initContainers }}
        {{- if ne $initContainer.name "wait-for-postgresql" }}
        {{- $mergedSecurityContext := mergeOverwrite (dict) (default dict $.defaultValues.initContainerSecurityContext) (default dict $initContainer.securityContext) }}
        {{- $mergedResources := mergeOverwrite (dict) (default dict $.defaultValues.initContainerResources) (default dict $initContainer.resources) }}
        {{- $c := mergeOverwrite (dict) $initContainer }}
        {{- if not (empty $mergedSecurityContext) }}
        {{- $c = mergeOverwrite $c (dict "securityContext" $mergedSecurityContext) }}
        {{- else }}
        {{- $c = omit $c "securityContext" }}
        {{- end }}
        {{- if not (empty $mergedResources) }}
        {{- $c = mergeOverwrite $c (dict "resources" $mergedResources) }}
        {{- else }}
        {{- $c = omit $c "resources" }}
        {{- end }}
        {{- tpl (toYaml (list $c)) $ | nindent 8 }}
        {{- end }}
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
        {{- if and .modelDelivery .modelDelivery.enabled }}
        - name: ai-model-cache
          emptyDir:
            sizeLimit: {{ .modelDelivery.cacheSizeLimit }}
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
Requires at least one of:
  - targetCPUUtilizationPercentage
  - targetMemoryUtilizationPercentage
  - targetRequestsPerSecond (External metric via Prometheus Adapter)
Optional autoscaling.behavior is passed through as HPA v2 behavior (scaleUp/scaleDown).
Request metric name defaults to http_requests_per_second (must match prometheus-adapter rules).
HPA uses max across all metrics (Option B: CPU/mem safety valves + RPS primary for hot paths).
*/}}
{{- define "techx-corp.hpa" }}
{{- if and (not .autoscaling.targetCPUUtilizationPercentage) (not .autoscaling.targetMemoryUtilizationPercentage) (not .autoscaling.targetRequestsPerSecond) }}
{{- fail (printf "components.%s.autoscaling.enabled requires targetCPUUtilizationPercentage, targetMemoryUtilizationPercentage, and/or targetRequestsPerSecond" .name) }}
{{- end }}
{{- $customMetricName := .autoscaling.customMetricName | default "http_requests_per_second" }}
{{- $serviceName := .autoscaling.serviceName | default .name }}
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
    {{- if .autoscaling.targetRequestsPerSecond }}
    # External RPS from Prometheus Adapter (service_name label = OTel service.name).
    # AverageValue → HPA divides total service RPS by current replica count.
    - type: External
      external:
        metric:
          name: {{ $customMetricName }}
          selector:
            matchLabels:
              service_name: {{ $serviceName | quote }}
        target:
          type: AverageValue
          averageValue: {{ .autoscaling.targetRequestsPerSecond | quote }}
    {{- end }}
  {{- if .autoscaling.behavior }}
  behavior:
    {{- toYaml .autoscaling.behavior | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
PodDisruptionBudget for multi-replica stateless Deployments (minAvailable: 1).
Rendered for HPA minReplicas >= 2 and fixed replicas >= 2.
*/}}
{{- define "techx-corp.pdb" }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  labels:
    {{- include "techx-corp.labels" . | nindent 4 }}
spec:
  {{- if .pdb }}
    {{- if hasKey .pdb "minAvailable" }}
  minAvailable: {{ .pdb.minAvailable }}
    {{- else if hasKey .pdb "maxUnavailable" }}
  maxUnavailable: {{ .pdb.maxUnavailable }}
    {{- end }}
  {{- else }}
  minAvailable: 1
  {{- end }}
  selector:
    matchLabels:
      {{- include "techx-corp.selectorLabels" . | nindent 6 }}
{{- end }}
{{/* Change trail: @hungxqt - 2026-07-19 - Support imageOverride.name for service-segment remap without full repository pin. */}}
