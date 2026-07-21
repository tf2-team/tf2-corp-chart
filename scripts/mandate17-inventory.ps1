param(
    [string]$Helm = "helm",
    [string]$Kubectl = "kubectl",
    [string]$KubeContext = "",
    [string]$Namespace = "techx-corp-prod"
)

$ErrorActionPreference = "Stop"
$chartRoot = Split-Path -Parent $PSScriptRoot
$firstParty = @(
    "accounting", "ad", "cart", "checkout", "currency", "email",
    "flagd", "fraud-detection", "frontend", "frontend-proxy",
    "image-provider", "llm", "load-generator", "load-generator-worker",
    "payment", "product-catalog", "product-reviews", "quote",
    "recommendation", "shipping", "shopping-copilot"
)

$rendered = & $Helm template techx-corp $chartRoot --namespace $Namespace `
    --values (Join-Path $chartRoot "values.yaml") `
    --values (Join-Path $chartRoot "values-public-alb.yaml") `
    --values (Join-Path $chartRoot "values-prod.yaml")
if ($LASTEXITCODE -ne 0) { throw "helm template failed" }
$documents = (($rendered -join "`n") -split "(?m)^---\s*$")

function Get-Manifest([string]$Kind, [string]$Name) {
    return @($documents | Where-Object {
        $_ -match "(?m)^kind: $([regex]::Escape($Kind))$" -and
        $_ -match "(?m)^  name: $([regex]::Escape($Name))$"
    })
}

$checked = 0
foreach ($name in $firstParty) {
    $workloads = @((Get-Manifest "Deployment" $name) + (Get-Manifest "StatefulSet" $name))
    if ($workloads.Count -eq 0) { continue }
    if ($workloads.Count -ne 1) { throw "${name}: expected exactly one workload" }

    $workload = $workloads[0]
    if ($workload -notmatch "(?m)^      serviceAccountName: $([regex]::Escape($name))$") {
        throw "${name}: workload must use its dedicated ServiceAccount"
    }
    if ($workload -notmatch "(?m)^      automountServiceAccountToken: false$") {
        throw "${name}: Pod must disable the default Kubernetes API token"
    }

    $serviceAccounts = @(Get-Manifest "ServiceAccount" $name)
    if ($serviceAccounts.Count -ne 1) { throw "${name}: expected one dedicated ServiceAccount" }
    if ($serviceAccounts[0] -notmatch "(?m)^automountServiceAccountToken: false$") {
        throw "${name}: ServiceAccount must disable token automount"
    }

    foreach ($kind in @("RoleBinding", "ClusterRoleBinding")) {
        $bindings = @($documents | Where-Object { $_ -match "(?m)^kind: ${kind}$" })
        foreach ($binding in $bindings) {
            if ($binding -match "(?ms)^subjects:.*?^  - kind: ServiceAccount\s+name: $([regex]::Escape($name))$") {
                throw "${name}: unexpected Kubernetes RBAC binding in ${kind}"
            }
        }
    }

    Write-Host "PASS $name identity/token/RBAC"
    $checked++
}

if ($checked -eq 0) { throw "No first-party workloads were checked" }

if ($KubeContext) {
    $dangerousChecks = @(
        @("get", "secrets"), @("list", "secrets"), @("create", "pods"),
        @("patch", "deployments.apps"), @("get", "nodes")
    )
    foreach ($name in $firstParty) {
        $exists = & $Kubectl --context $KubeContext -n $Namespace get deployment $name --ignore-not-found -o name
        if (-not $exists) { continue }
        foreach ($check in $dangerousChecks) {
            $allowed = & $Kubectl --context $KubeContext auth can-i $check[0] $check[1] `
                --as "system:serviceaccount:${Namespace}:${name}" -n $Namespace
            if ($allowed.Trim() -eq "yes") {
                throw "${name}: unexpectedly allowed to $($check -join ' ')"
            }
        }
        Write-Host "PASS $name live auth can-i"
    }
}

Write-Host "Mandate 17 identity inventory passed for $checked rendered workload(s)."
