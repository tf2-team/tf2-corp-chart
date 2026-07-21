param([string]$Helm = "helm")

$ErrorActionPreference = "Stop"
$chartRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$baseArgs = @(
    "template", "techx-corp", $chartRoot,
    "--namespace", "techx-corp-prod",
    "--values", (Join-Path $chartRoot "values.yaml"),
    "--values", (Join-Path $chartRoot "values-public-alb.yaml"),
    "--values", (Join-Path $chartRoot "values-prod.yaml")
)

function Render([bool]$Enabled, [bool]$Enforce, [bool]$Proxy) {
    $args = $baseArgs
    if ($Proxy) {
        $args += @("--values", (Join-Path $PSScriptRoot "network-policy-values.yaml"))
    }
    $args += @(
        "--set", "networkPolicy.enabled=$($Enabled.ToString().ToLowerInvariant())",
        "--set", "networkPolicy.enforceEgress=$($Enforce.ToString().ToLowerInvariant())",
        "--set", "egressProxy.enabled=$($Proxy.ToString().ToLowerInvariant())"
    )
    $output = & $Helm @args
    if ($LASTEXITCODE -ne 0) { throw "helm template failed for $Enabled/$Enforce/$Proxy" }
    return ($output -join "`n")
}

function NetworkPolicyDocuments([string]$Rendered) {
    return @(($Rendered -split '(?m)^---\s*$') | Where-Object {
        $_ -match '# Source: techx-corp/templates/networkpolicy.yaml' -and
        $_ -match '(?m)^kind: NetworkPolicy$'
    })
}

function Assert-InvalidValues([bool]$Enabled, [bool]$Enforce, [bool]$Proxy) {
    $args = $baseArgs
    if ($Proxy) {
        $args += @("--values", (Join-Path $PSScriptRoot "network-policy-values.yaml"))
    }
    $args += @(
        "--set", "networkPolicy.enabled=$($Enabled.ToString().ToLowerInvariant())",
        "--set", "networkPolicy.enforceEgress=$($Enforce.ToString().ToLowerInvariant())",
        "--set", "egressProxy.enabled=$($Proxy.ToString().ToLowerInvariant())"
    )
    & $Helm @args 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        throw "invalid containment values unexpectedly rendered: $Enabled/$Enforce/$Proxy"
    }
}

$disabled = NetworkPolicyDocuments (Render $false $false $false)
if ($disabled.Count -ne 0) { throw "disabled state rendered NetworkPolicy resources" }

Assert-InvalidValues $false $true $true
Assert-InvalidValues $true $true $false
$missingGrafanaProxyArgs = $baseArgs + @(
    "--set", "networkPolicy.enabled=true",
    "--set", "networkPolicy.enforceEgress=true",
    "--set", "egressProxy.enabled=true"
)
& $Helm @missingGrafanaProxyArgs 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { throw "full enforcement accepted Grafana without proxy environment" }

$missingDigestArgs = $baseArgs + @(
    "--values", (Join-Path $PSScriptRoot "network-policy-values.yaml"),
    "--set", "networkPolicy.enabled=true",
    "--set", "networkPolicy.enforceEgress=true",
    "--set", "egressProxy.enabled=true",
    "--set-string", "egressProxy.image.digest="
)
& $Helm @missingDigestArgs 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { throw "full enforcement accepted an unpinned proxy image" }

$ingressRendered = Render $true $false $false
$ingress = NetworkPolicyDocuments $ingressRendered
if ($ingress.Count -lt 20) { throw "ingress state rendered too few NetworkPolicy resources" }
$ingressText = $ingress -join "`n---`n"
if ($ingressText -match '(?m)^    - Egress\s*$' -or $ingressText -match '(?m)^  egress:') {
    throw "ingress-only state must not isolate egress"
}
if ($ingressText -match '(?m)^\s*- \{\}\s*(?:#.*)?$') { throw "open ingress peer detected" }
$frontendIngressPolicy = $ingress | Where-Object { $_ -match '(?m)^  name: frontend-proxy$' }
if ($frontendIngressPolicy.Count -ne 1) { throw "ingress state must render one frontend-proxy policy" }
foreach ($albCidr in @('10.0.10.0/24', '10.0.11.0/24')) {
    if ($frontendIngressPolicy -notmatch "cidr: $([regex]::Escape($albCidr))") {
        throw "verified ALB subnet CIDR is missing: $albCidr"
    }
}
if ($frontendIngressPolicy -match 'cidr: 10\.0\.0\.0/16') {
    throw "frontend ingress must not allow the entire VPC CIDR"
}

$fullRendered = Render $true $true $true
$full = NetworkPolicyDocuments $fullRendered
$fullText = $full -join "`n---`n"
if ($fullText -notmatch '(?m)^    - Egress\s*$') { throw "full state did not isolate egress" }
if ($fullText -notmatch 'name: allow-dns-egress') { throw "full state is missing DNS egress" }
$dnsPolicy = $full | Where-Object { $_ -match '(?m)^  name: allow-dns-egress$' }
if ($dnsPolicy.Count -ne 1) { throw "full state must render exactly one DNS egress policy" }
foreach ($required in @(
    'kubernetes.io/metadata.name: kube-system',
    'k8s-app: kube-dns',
    'protocol: UDP',
    'protocol: TCP',
    'port: 53'
)) {
    if ($dnsPolicy -notmatch [regex]::Escape($required)) { throw "DNS egress missing: $required" }
}
$internetRules = [regex]::Matches($fullText, 'cidr: 0\.0\.0\.0/0')
if ($internetRules.Count -ne 1) { throw "only the egress proxy may have one internet rule" }
if ($fullText -match 'cidr: 10\.0\.0\.0/8') { throw "over-broad VPC CIDR detected" }
foreach ($requiredPolicy in @(
    'otel-collector-egress', 'metrics-server', 'prometheus-adapter',
    'kube-state-metrics', 'runtime-hardening-inventory'
)) {
    if ($fullText -notmatch "(?m)^  name: $([regex]::Escape($requiredPolicy))$") {
        throw "full state is missing control-plane policy: $requiredPolicy"
    }
}
if ($fullRendered -notmatch 'app.kubernetes.io/component: otel-collector') {
    throw "OTel collector pods are missing the selector label used by NetworkPolicy"
}

$grafanaDoc = ($fullRendered -split '(?m)^---\s*$') | Where-Object {
    $_ -match '# Source: techx-corp/charts/grafana/templates/deployment.yaml' -and
    $_ -match '(?m)^kind: Deployment$'
}
if ($grafanaDoc.Count -ne 1) { throw "full state must render one Grafana Deployment" }
foreach ($required in @(
    'name: "HTTPS_PROXY"', 'name: "https_proxy"', 'name: "NO_PROXY"', 'name: "no_proxy"',
    'value: "http://egress-proxy:10000"', 'opentelemetry.io/name: grafana'
)) {
    if ($grafanaDoc -notmatch [regex]::Escape($required)) { throw "Grafana proxy environment missing: $required" }
}
$grafanaPolicy = $full | Where-Object { $_ -match '(?m)^  name: grafana$' }
if ($grafanaPolicy.Count -ne 1 -or $grafanaPolicy -notmatch 'app.kubernetes.io/name: egress-proxy') {
    throw "Grafana policy must allow egress to the proxy"
}

$proxyConfig = ($fullRendered -split '(?m)^---\s*$') | Where-Object {
    $_ -match '# Source: techx-corp/templates/egress-proxy.yaml' -and
    $_ -match '(?m)^kind: ConfigMap$'
}
foreach ($requiredDomain in @(
    'athena.ap-southeast-1.amazonaws.com:443',
    'glue.ap-southeast-1.amazonaws.com:443',
    'sts.ap-southeast-1.amazonaws.com:443',
    's3.ap-southeast-1.amazonaws.com:443',
    '*.s3.ap-southeast-1.amazonaws.com:443',
    'discord.com:443'
)) {
    if ($proxyConfig -notmatch [regex]::Escape($requiredDomain)) {
        throw "Grafana proxy allowlist domain missing: $requiredDomain"
    }
}

$proxyDoc = ($fullRendered -split '(?m)^---\s*$') | Where-Object {
    $_ -match '# Source: techx-corp/templates/egress-proxy.yaml' -and
    $_ -match '(?m)^kind: Deployment$'
}
if ($proxyDoc -notmatch '(?m)^  replicas: 2$') { throw "egress proxy must have two replicas" }
foreach ($required in @(
    'runAsNonRoot: true', 'readOnlyRootFilesystem: true',
    'allowPrivilegeEscalation: false', 'automountServiceAccountToken: false',
    'topologyKey: topology.kubernetes.io/zone', 'topologyKey: kubernetes.io/hostname',
    'argocd.argoproj.io/sync-wave: "-1"',
    'envoyproxy/envoy@sha256:a7a56545102f7a682e0cafea2c9b8448af1b09ebb710eab688dfb931e3ec7ff6'
)) {
    if ($proxyDoc -notmatch [regex]::Escape($required)) { throw "egress proxy missing: $required" }
}

$attacker = Get-Content -Raw (Join-Path $PSScriptRoot "attacker-deployment.yaml")
foreach ($required in @(
    'kind: Deployment', 'automountServiceAccountToken: false', 'runAsNonRoot: true',
    'readOnlyRootFilesystem: true', 'allowPrivilegeEscalation: false', 'drop:',
    'requests:', 'limits:',
    'curlimages/curl:8.14.1@sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b'
)) {
    if ($attacker -notmatch [regex]::Escape($required)) { throw "attacker fixture missing: $required" }
}

Write-Host "Mandate 17 three-state NetworkPolicy, proxy, and attacker manifests passed."
