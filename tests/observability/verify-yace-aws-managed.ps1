$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$chartDir = Resolve-Path "$scriptDir\..\.."
$valuesPath = Join-Path $chartDir "values-prod.yaml"

if (-not (Test-Path $valuesPath)) {
    Write-Error "values-prod.yaml not found at $valuesPath"
    exit 1
}

$content = Get-Content $valuesPath -Raw

# Check jobs
$expectedJobs = @(
    'rds-postgresql',
    'elasticache-cart-001',
    'elasticache-cart-002',
    'kafka-broker-1',
    'kafka-broker-2',
    'kafka-broker-3'
)

foreach ($job in $expectedJobs) {
    if ($content -notmatch "name:\s*$job") {
        Write-Error "Missing expected YACE job: $job"
        exit 1
    }
}

# Check namespaces
$expectedNamespaces = @('AWS/RDS', 'AWS/ElastiCache', 'AWS/Kafka')
foreach ($ns in $expectedNamespaces) {
    if ($content -notmatch "namespace:\s*$ns") {
        Write-Error "Missing expected namespace: $ns"
        exit 1
    }
}

# Check identifiers
$expectedIdentifiers = @(
    'techx-prod-tf2-postgresql',
    'techx-prod-tf2-cart-001',
    'techx-prod-tf2-cart-002',
    'techx-prod-tf2-msk'
)
foreach ($id in $expectedIdentifiers) {
    if (-not $content.Contains($id)) {
        Write-Error "Missing expected resource identifier: $id"
        exit 1
    }
}

# Check period
if ($content -notmatch "period:\s*300") {
    Write-Error "Expected period: 300 missing"
    exit 1
}

# Extract YACE section to verify length 600
$yaceIdx = $content.IndexOf("components:")
if ($yaceIdx -ge 0) {
    $yaceConfig = $content.Substring($yaceIdx)
} else {
    $yaceConfig = $content
}

if ($yaceConfig -match "length:\s*300") {
    Write-Error "YACE config still contains length: 300. Expected length: 600"
    exit 1
}

if ($yaceConfig -notmatch "length:\s*600") {
    Write-Error "YACE config missing required length: 600"
    exit 1
}

Write-Host "YACE AWS-managed metrics verification passed successfully."
# Change trail: @hungxqt - 2026-07-27 - Added YACE chart configuration verification test.
