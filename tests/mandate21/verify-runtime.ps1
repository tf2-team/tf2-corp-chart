$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Host "[PASS] $Message"
}

function Read-RepoFile {
    param([string]$Path)
    return Get-Content -LiteralPath (Join-Path $repo $Path) -Raw
}

$wrapperPath = Join-Path $repo "scripts/mandate21-fis-drill.ps1"
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($wrapperPath, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) "FIS wrapper parses as PowerShell"

$wrapper = Read-RepoFile "scripts/mandate21-fis-drill.ps1"
Assert-True ($wrapper -match 'Get-Random') "wrapper selects the live AZ at runtime"
Assert-True ($wrapper -match 'start-experiment') "wrapper starts an AWS FIS experiment"
Assert-True ($wrapper -match 'RUN-M21-FIS') "wrapper requires an explicit live confirmation token"
Assert-True ($wrapper -notmatch '(?im)\bkubectl\b.*\b(cordon|drain|delete)\b') "wrapper never cordons, drains, or deletes Kubernetes resources"

$contract = Read-RepoFile "scripts/mandate21-fis-contract.example.json" | ConvertFrom-Json
Assert-True ($contract.schemaVersion -eq 1) "example contract uses schema version 1"
Assert-True (@($contract.zones.PSObject.Properties).Count -eq 2) "example contract maps exactly two AZs"
foreach ($zone in $contract.zones.PSObject.Properties) {
    Assert-True ($null -ne $zone.Value.primaryInZoneTemplateId) "$($zone.Name) maps the RDS-primary-in-zone template"
    Assert-True ($null -ne $zone.Value.primaryOutsideZoneTemplateId) "$($zone.Name) maps the RDS-primary-outside-zone template"
}

$loadTest = Read-RepoFile "scripts/maintenance-load-test.js"
foreach ($field in @("request_id", "trace_id", "timestamp", "http_status", "latency_ms", "order_id", "outcome")) {
    Assert-True ($loadTest.Contains($field)) "k6 ledger contains $field"
}
Assert-True ($loadTest -match 'LEDGER_ENABLED') "k6 ledger is explicitly opt-in"
Assert-True ($loadTest -notmatch 'console\.log\([^)]*(creditCard|email|address)') "k6 never logs customer or payment payload"

$dashboardPath = Join-Path $repo "grafana/provisioning/dashboards/mandate-21-az-failover.json"
$dashboard = Get-Content -LiteralPath $dashboardPath -Raw | ConvertFrom-Json -Depth 100
Assert-True ($dashboard.uid -eq "mandate-21-az-failover") "dashboard UID is stable"
$titles = @($dashboard.panels.title)
foreach ($title in @("Ready nodes by AZ", "Ready money-path pods by AZ", "ALB healthy targets by AZ", "Managed-store failover signals", "Outbox age and Accounting errors", "Order reconciliation counters")) {
    Assert-True ($titles -contains $title) "dashboard includes '$title'"
}

$linkerd = Read-RepoFile "gitops/linkerd/linkerd-control-plane.yaml"
Assert-True ($linkerd -match '(?m)^\s*controllerReplicas:\s*2\s*$') "Linkerd controller replica floor is two"
Assert-True ($linkerd -match '(?m)^\s*enablePodAntiAffinity:\s*true\s*$') "Linkerd controller anti-affinity is enabled"
Assert-True ($linkerd -match '(?m)^\s*enablePodDisruptionBudget:\s*true\s*$') "Linkerd controller PDB is enabled"

$helm = Get-Command helm -ErrorAction SilentlyContinue
Assert-True ($null -ne $helm) "helm is installed"
$rendered = & helm template techx-corp $repo --namespace techx-corp-prod `
    -f (Join-Path $repo "values.yaml") `
    -f (Join-Path $repo "values-public-alb.yaml") `
    -f (Join-Path $repo "values-prod.yaml") 2>&1
if ($LASTEXITCODE -ne 0) { throw "helm template failed:`n$($rendered -join "`n")" }
$manifest = $rendered -join "`n"

Assert-True ($manifest -match '(?ms)kind: Deployment.*?name: accounting.*?replicas: 2') "rendered Accounting Deployment has two replicas"
Assert-True ($manifest -match '(?ms)kind: PodDisruptionBudget.*?name: accounting.*?maxUnavailable: 1') "rendered Accounting PDB uses maxUnavailable 1"
Assert-True ($manifest -match 'yace\.techx-corp-prod\.svc\.cluster\.local:5000') "Prometheus directly scrapes YACE"
Assert-True ($manifest -match '(?ms)name: yace.*?app\.kubernetes\.io/name: prometheus.*?port: 5000') "YACE NetworkPolicy admits Prometheus"
Assert-True ($manifest -match 'aws_applicationelb_healthy_host_count_minimum|HealthyHostCount') "rendered configuration includes ALB healthy-target metrics"
Assert-True ($manifest -match 'mandate-21-az-failover') "rendered Grafana ConfigMap includes the Mandate 21 dashboard"

Write-Host "Mandate 21 runtime verification passed."
