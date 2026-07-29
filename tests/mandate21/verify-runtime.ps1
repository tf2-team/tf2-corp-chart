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
Assert-True ($wrapper -match 'describe-alarms') "wrapper verifies every FIS stop alarm is OK"
Assert-True ($wrapper -match 'RecoveryMinutes') "wrapper enforces a measured recovery window"
Assert-True ($wrapper -match 'reconciliation-report\.txt') "wrapper persists Person 2 reconciliation output"

$cleanupPath = Join-Path $repo "scripts/mandate21-cleanup.psm1"
$cleanupTokens = $null
$cleanupErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($cleanupPath, [ref]$cleanupTokens, [ref]$cleanupErrors)
Assert-True ($cleanupErrors.Count -eq 0) "cleanup module parses as PowerShell"

$preflightPath = Join-Path $repo "scripts/collect-infra-preflight.ps1"
$preflightTokens = $null
$preflightErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($preflightPath, [ref]$preflightTokens, [ref]$preflightErrors)
Assert-True ($preflightErrors.Count -eq 0) "infrastructure preflight collector parses as PowerShell"
$preflight = Read-RepoFile "scripts/collect-infra-preflight.ps1"
Assert-True ($preflight -match '\[string\]\$OutputPath\s*=\s*""') "preflight output default does not evaluate PSScriptRoot during parameter binding"
Assert-True ($preflight -match '\$OutputPath\s*=\s*Join-Path\s+\$scriptDirectory') "preflight resolves its default output path at runtime"
Assert-True ($preflight -notmatch 'ConvertFrom-Json\s+-Depth') "preflight JSON parsing is compatible with Windows PowerShell 5.1"
Assert-True ($preflight -match '\$ValkeyReplicationGroupId\s*=\s*"techx-prod-tf2-cart"') "preflight targets the production Valkey replication group"
Assert-True ($preflight -match '\$MskClusterName\s*=\s*"techx-prod-tf2-msk"') "preflight targets the production MSK cluster"

$contract = Read-RepoFile "scripts/mandate21-fis-contract.example.json" | ConvertFrom-Json
Assert-True ($contract.schemaVersion -eq 1) "example contract uses schema version 1"
Assert-True (@($contract.zones.PSObject.Properties).Count -eq 2) "example contract maps exactly two AZs"
Assert-True ($null -ne $contract.cleanupByTemplateId) "example contract contains cleanupByTemplateId map"
foreach ($zone in $contract.zones.PSObject.Properties) {
    Assert-True ($null -ne $zone.Value.primaryInZoneTemplateId) "$($zone.Name) maps the RDS-primary-in-zone template"
    Assert-True ($null -ne $zone.Value.primaryOutsideZoneTemplateId) "$($zone.Name) maps the RDS-primary-outside-zone template"
}

$liveContract = Read-RepoFile "scripts/mandate21-fis-contract.json" | ConvertFrom-Json
$liveTemplateIds = @()
foreach ($zone in $liveContract.zones.PSObject.Properties) {
    foreach ($templateId in @($zone.Value.primaryInZoneTemplateId, $zone.Value.primaryOutsideZoneTemplateId)) {
        Assert-True ($templateId -match '^EXT[A-Za-z0-9]+$') "$($zone.Name) uses a concrete FIS experiment template ID"
        $liveTemplateIds += $templateId
    }
}
Assert-True (@($liveTemplateIds | Sort-Object -Unique).Count -eq 4) "live FIS contract maps four distinct template variants"
Assert-True ($null -ne $liveContract.cleanupByTemplateId) "live FIS contract contains cleanupByTemplateId map"
Assert-True (@($liveContract.cleanupByTemplateId.PSObject.Properties.Name | Sort-Object -Unique).Count -eq 4) "live FIS contract cleanupByTemplateId contains all four template IDs"

$loadTest = Read-RepoFile "scripts/maintenance-load-test.js"
foreach ($field in @("testRequestId", "traceId", "startedAt", "completedAt", "httpStatus", "durationMs", "orderId", "outcome")) {
    Assert-True ($loadTest.Contains($field)) "k6 ledger contains $field"
}
Assert-True ($loadTest -match 'LEDGER_ENABLED') "k6 ledger is explicitly opt-in"
Assert-True ($loadTest -notmatch 'console\.log\([^)]*(creditCard|email|address)') "k6 never logs customer or payment payload"

$kubecost = Read-RepoFile "gitops/clusters/prod/kubecost-application.yaml"
Assert-True ($kubecost -match '(?m)^\s*skipCrds:\s*true\s*$') "Kubecost omits disabled Turndown CRDs from the least-privilege AppProject"

$dashboardPath = Join-Path $repo "grafana/provisioning/dashboards/mandate-21-az-failover.json"
$dashboard = Get-Content -LiteralPath $dashboardPath -Raw | ConvertFrom-Json
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
    -f (Join-Path $repo "values-prod.yaml") `
    -f (Join-Path $repo "service-digest/values-accounting.yaml") 2>&1
if ($LASTEXITCODE -ne 0) { throw "helm template failed:`n$($rendered -join "`n")" }
$manifest = $rendered -join "`n"

Assert-True ($manifest -match '(?ms)kind: Deployment.*?name: accounting.*?replicas: 2') "rendered Accounting Deployment has two replicas"
Assert-True ($manifest -match '(?ms)kind: PodDisruptionBudget.*?name: accounting.*?maxUnavailable: 1') "rendered Accounting PDB uses maxUnavailable 1"
$accountingDigest = [regex]::Match(
    (Read-RepoFile "service-digest/values-accounting.yaml"),
    'sha256:[0-9a-f]{64}'
).Value
Assert-True (-not [string]::IsNullOrWhiteSpace($accountingDigest)) "Accounting production digest is present"
Assert-True ($manifest -match [regex]::Escape("accounting@$accountingDigest")) "Accounting Deployment and migration Job use the promoted immutable digest"
Assert-True ($manifest -match '(?ms)kind: Job.*?name: accounting-migration.*?activeDeadlineSeconds: 300') "Accounting migration fails closed after five minutes"
$migrationJob = @($manifest -split '(?m)^---\s*$' | Where-Object {
    $_ -match '(?ms)kind:\s+Job.*?name:\s+accounting-migration'
})[0]
Assert-True ($migrationJob -match 'DB_CONNECTION_STRING') "Accounting migration receives its database credential"
Assert-True ($migrationJob -notmatch '(?m)^\s*-\s+name:\s+(KAFKA_ADDR|CHECKOUT_OUTBOX_TABLE)\s*$') "Accounting migration cannot start Kafka or the outbox reconciler"
Assert-True ($migrationJob -match '(?m)^\s*linkerd\.io/inject:\s+disabled\s*$') "Accounting migration is not held open by a Linkerd sidecar"
Assert-True ($migrationJob -match '(?m)^\s*restartPolicy:\s+Never\s*$') "Accounting migration retries with fresh Pods"
$migrationPolicy = @($manifest -split '(?m)^---\s*$' | Where-Object {
    $_ -match '(?ms)kind:\s+NetworkPolicy.*?name:\s+accounting-migration-postgresql-egress'
})[0]
Assert-True ($migrationPolicy -match '(?m)^\s*argocd\.argoproj\.io/hook:\s+PreSync\s*$') "Accounting migration egress policy is a PreSync hook"
Assert-True ($migrationPolicy -match '(?m)^\s*argocd\.argoproj\.io/sync-wave:\s+["'']?-1["'']?\s*$') "Accounting migration egress policy is created before the Job"
Assert-True ($migrationPolicy -match '(?ms)podSelector:.*?app\.kubernetes\.io/component:\s+accounting-migration') "Accounting migration egress policy selects only the migration Pod"
Assert-True ($migrationPolicy -match '(?ms)ipBlock:.*?cidr:\s+10\.0\.0\.0/16.*?protocol:\s+TCP.*?port:\s+5432') "Accounting migration egress is limited to PostgreSQL in the VPC"
Assert-True ($migrationPolicy -notmatch '0\.0\.0\.0/0') "Accounting migration has no unrestricted egress"
Assert-True ($manifest -match 'yace\.techx-corp-prod\.svc\.cluster\.local:5000') "Prometheus directly scrapes YACE"
Assert-True ($manifest -match '(?ms)name: yace.*?app\.kubernetes\.io/name: prometheus.*?port: 5000') "YACE NetworkPolicy admits Prometheus"
Assert-True ($manifest -match 'aws_applicationelb_healthy_host_count_minimum|HealthyHostCount') "rendered configuration includes ALB healthy-target metrics"
Assert-True ($manifest -notmatch 'kind:\s+Deployment.*?name:\s+capacity-probe') "capacity-probe Deployment is disabled by default"

$probeRendered = & helm template techx-corp $repo --namespace techx-corp-prod `
    -f (Join-Path $repo "values.yaml") `
    -f (Join-Path $repo "values-public-alb.yaml") `
    -f (Join-Path $repo "values-prod.yaml") `
    -f (Join-Path $repo "service-digest/values-accounting.yaml") `
    --set capacityProbe.enabled=true 2>&1
if ($LASTEXITCODE -ne 0) { throw "helm template with capacityProbe.enabled=true failed:`n$($probeRendered -join "`n")" }
$probeManifest = $probeRendered -join "`n"
Assert-True ($probeManifest -match '(?ms)kind:\s+Deployment.*?name:\s+capacity-probe') "capacity-probe Deployment renders when capacityProbe.enabled=true"
Assert-True ($probeManifest -match 'karpenter\.sh/capacity-type:\s+["'']?on-demand["'']?') "capacity-probe uses stateless-on-demand placement"
Assert-True ($probeManifest -match '(?ms)key:\s+["'']?workload-class["'']?.*?value:\s+["'']?spot-tolerant["'']?') "capacity-probe tolerates spot-tolerant workload-class"
Assert-True ($probeManifest -match 'automountServiceAccountToken:\s+false') "capacity-probe omits service account token"

Write-Host "Mandate 21 runtime verification passed."

# Change trail: @hungxqt - 2026-07-29 - Verified capacity-probe Deployment disabled by default and rendered when enabled.
