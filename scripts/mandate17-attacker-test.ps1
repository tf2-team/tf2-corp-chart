param(
    [Parameter(Mandatory)][string]$KubeContext,
    [string]$Namespace = "techx-corp-prod",
    [Parameter(Mandatory)][string]$RdsEndpoint,
    [Parameter(Mandatory)][string]$MskEndpoint,
    [Parameter(Mandatory)][string]$ValkeyEndpoint,
    [string]$EvidenceDirectory = ""
)

$ErrorActionPreference = "Stop"
$chartRoot = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $chartRoot "tests/mandate17/attacker-deployment.yaml"
if (-not $EvidenceDirectory) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $EvidenceDirectory = Join-Path $chartRoot "docs/evidence/mandate-17/attacker-$stamp"
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$log = Join-Path $EvidenceDirectory "attacker-test.txt"

function Run-Kubectl([string[]]$Arguments) {
    & kubectl --context $KubeContext @Arguments 2>&1
    return $LASTEXITCODE
}

function Assert-Blocked([string]$Name, [string]$Target) {
    "TEST blocked: $Name -> $Target" | Tee-Object -FilePath $log -Append
    & kubectl --context $KubeContext -n $Namespace exec deployment/mandate17-attacker -- `
        curl -k -sS -o /dev/null --connect-timeout 3 --max-time 5 $Target 2>&1 |
        Tee-Object -FilePath $log -Append | Out-Host
    if ($LASTEXITCODE -eq 0) { throw "$Name unexpectedly connected to $Target" }
    "PASS blocked: $Name" | Tee-Object -FilePath $log -Append
}

try {
    "context=$KubeContext namespace=$Namespace started=$(Get-Date -Format o)" |
        Tee-Object -FilePath $log

    $policy = & kubectl --context $KubeContext -n $Namespace get networkpolicy egress-proxy -o name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $policy) {
        throw "Full NetworkPolicy enforcement is not active; egress-proxy policy is missing"
    }
    $policyEndpoints = & kubectl --context $KubeContext get policyendpoints.networking.k8s.aws -n $Namespace -o name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $policyEndpoints) {
        throw "No AWS VPC CNI PolicyEndpoint exists in $Namespace"
    }

    & kubectl --context $KubeContext -n $Namespace apply -f $fixture |
        Tee-Object -FilePath $log -Append | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "attacker fixture apply failed" }
    & kubectl --context $KubeContext -n $Namespace rollout status deployment/mandate17-attacker --timeout=2m |
        Tee-Object -FilePath $log -Append | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "attacker deployment did not become Ready" }

    & kubectl --context $KubeContext -n $Namespace exec deployment/mandate17-attacker -- `
        nslookup kubernetes.default.svc.cluster.local 2>&1 |
        Tee-Object -FilePath $log -Append | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "DNS positive control failed" }
    "PASS DNS positive control" | Tee-Object -FilePath $log -Append

    Assert-Blocked "same-namespace service" "http://cart:8080"
    Assert-Blocked "Kubernetes API" "https://kubernetes.default.svc"
    Assert-Blocked "egress proxy" "http://egress-proxy:10000"
    Assert-Blocked "arbitrary internet" "https://example.com"
    Assert-Blocked "RDS data plane" "telnet://$RdsEndpoint"
    Assert-Blocked "MSK data plane" "telnet://$MskEndpoint"
    Assert-Blocked "Valkey data plane" "telnet://$ValkeyEndpoint"

    & kubectl --context $KubeContext -n $Namespace exec deployment/mandate17-attacker -- `
        test '!' -e /var/run/secrets/kubernetes.io/serviceaccount/token
    if ($LASTEXITCODE -ne 0) { throw "attacker unexpectedly has a Kubernetes API token" }
    "PASS no Kubernetes API token" | Tee-Object -FilePath $log -Append

    $canReadSecrets = & kubectl --context $KubeContext auth can-i get secrets `
        --as "system:serviceaccount:${Namespace}:mandate17-attacker" -n $Namespace
    if ($canReadSecrets.Trim() -ne "no") { throw "attacker ServiceAccount can read Secrets" }
    "PASS no Kubernetes RBAC" | Tee-Object -FilePath $log -Append
    "RESULT PASS completed=$(Get-Date -Format o)" | Tee-Object -FilePath $log -Append
}
finally {
    & kubectl --context $KubeContext -n $Namespace delete -f $fixture --ignore-not-found=true `
        2>&1 | Tee-Object -FilePath $log -Append | Out-Host
}
