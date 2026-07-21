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
    $args = $baseArgs + @(
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

$disabled = NetworkPolicyDocuments (Render $false $false $false)
if ($disabled.Count -ne 0) { throw "disabled state rendered NetworkPolicy resources" }

$invalidArgs = $baseArgs + @(
    "--set", "networkPolicy.enabled=true",
    "--set", "networkPolicy.enforceEgress=true",
    "--set", "egressProxy.enabled=false"
)
$invalidOutput = & $Helm @invalidArgs 2>&1
if ($LASTEXITCODE -eq 0 -or ($invalidOutput -join "`n") -notmatch 'requires egressProxy.enabled=true') {
    throw "full enforcement without the proxy must be rejected"
}

$ingressRendered = Render $true $false $false
$ingress = NetworkPolicyDocuments $ingressRendered
if ($ingress.Count -lt 20) { throw "ingress state rendered too few NetworkPolicy resources" }
$ingressText = $ingress -join "`n---`n"
if ($ingressText -match '(?m)^    - Egress\s*$' -or $ingressText -match '(?m)^  egress:') {
    throw "ingress-only state must not isolate egress"
}
if ($ingressText -match '(?m)^\s*- \{\}\s*(?:#.*)?$') { throw "open ingress peer detected" }
if ($ingressText -notmatch 'cidr: 10\.0\.0\.0/16') { throw "verified ALB/VPC CIDR is missing" }

$fullRendered = Render $true $true $true
$full = NetworkPolicyDocuments $fullRendered
$fullText = $full -join "`n---`n"
if ($fullText -notmatch '(?m)^    - Egress\s*$') { throw "full state did not isolate egress" }
if ($fullText -notmatch 'name: allow-dns-egress') { throw "full state is missing DNS egress" }
$internetRules = [regex]::Matches($fullText, 'cidr: 0\.0\.0\.0/0')
if ($internetRules.Count -ne 1) { throw "only the egress proxy may have one internet rule" }
if ($fullText -match 'cidr: 10\.0\.0\.0/8') { throw "over-broad VPC CIDR detected" }

$proxyDoc = ($fullRendered -split '(?m)^---\s*$') | Where-Object {
    $_ -match '# Source: techx-corp/templates/egress-proxy.yaml' -and
    $_ -match '(?m)^kind: Deployment$'
}
if ($proxyDoc -notmatch '(?m)^  replicas: 2$') { throw "egress proxy must have two replicas" }
foreach ($required in @(
    'runAsNonRoot: true', 'readOnlyRootFilesystem: true',
    'allowPrivilegeEscalation: false', 'automountServiceAccountToken: false',
    'topologyKey: topology.kubernetes.io/zone', 'topologyKey: kubernetes.io/hostname',
    'argocd.argoproj.io/sync-wave: "-1"'
)) {
    if ($proxyDoc -notmatch [regex]::Escape($required)) { throw "egress proxy missing: $required" }
}

$attacker = Get-Content -Raw (Join-Path $PSScriptRoot "attacker-deployment.yaml")
foreach ($required in @(
    'kind: Deployment', 'automountServiceAccountToken: false', 'runAsNonRoot: true',
    'readOnlyRootFilesystem: true', 'allowPrivilegeEscalation: false', 'drop:',
    'requests:', 'limits:'
)) {
    if ($attacker -notmatch [regex]::Escape($required)) { throw "attacker fixture missing: $required" }
}

Write-Host "Mandate 17 three-state NetworkPolicy, proxy, and attacker manifests passed."
