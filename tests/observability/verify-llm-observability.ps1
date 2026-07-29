$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$chartDir = Resolve-Path "$scriptDir\..\.."

$valuesPath = Join-Path $chartDir "values.yaml"
$secretsValuesPath = Join-Path $chartDir "secrets-chart\values.yaml"
$secretsTplPath = Join-Path $chartDir "secrets-chart\templates\externalsecrets.yaml"
$dashboardPath = Join-Path $chartDir "grafana\provisioning\dashboards\llm-observability.json"

# 1. Verify spanmetrics dimensions in values.yaml
$valuesContent = Get-Content $valuesPath -Raw
$requiredDimensions = @("app.ai.surface", "gen_ai.request.model", "app.ai.outcome", "gen_ai.operation.name")
foreach ($dim in $requiredDimensions) {
    if ($valuesContent -notmatch [regex]::Escape($dim)) {
        Write-Error "values.yaml missing required spanmetrics dimension: $dim"
        exit 1
    }
}

# 2. Verify JAEGER_QUERY_URL in values.yaml frontend env
if ($valuesContent -notmatch "JAEGER_QUERY_URL") {
    Write-Error "values.yaml frontend env missing JAEGER_QUERY_URL"
    exit 1
}

# 3. Verify secrets-chart target in values.yaml
$secretsValuesContent = Get-Content $secretsValuesPath -Raw
if ($secretsValuesContent -notmatch "aiObservability:\s*techx-corp-ai-observability") {
    Write-Error "secrets-chart/values.yaml missing aiObservability target definition"
    exit 1
}

# 4. Verify ExternalSecret in externalsecrets.yaml
$secretsTplContent = Get-Content $secretsTplPath -Raw
if ($secretsTplContent -notmatch "AI_OBSERVABILITY_HMAC_KEY") {
    Write-Error "secrets-chart/templates/externalsecrets.yaml missing AI_OBSERVABILITY_HMAC_KEY mapping"
    exit 1
}

# 5. Verify LLM Observability dashboard
if (-not (Test-Path $dashboardPath)) {
    Write-Error "LLM Observability dashboard file missing at $dashboardPath"
    exit 1
}

$dashContent = Get-Content $dashboardPath -Raw
if ($dashContent -notmatch '"uid":\s*"llm-observability"') {
    Write-Error "llm-observability.json missing UID 'llm-observability'"
    exit 1
}

$requiredQueries = @(
    "app_ai_model_tokens_total",
    "app_ai_model_cost_usd_USD_total",
    "traces_span_metrics_duration_milliseconds_bucket",
    "traces_span_metrics_calls_total",
    "app_ai_outcome"
)

foreach ($q in $requiredQueries) {
    if ($dashContent -notmatch [regex]::Escape($q)) {
        Write-Error "llm-observability.json missing required PromQL query fragment: $q"
        exit 1
    }
}

Write-Host "LLM Observability verification passed successfully."

# Change trail: @hungxqt - 2026-07-29 - Created LLM Observability chart verification script.
