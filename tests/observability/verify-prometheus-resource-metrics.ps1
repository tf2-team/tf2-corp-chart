$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$chartDir = Resolve-Path "$scriptDir\..\.."
$valuesPath = Join-Path $chartDir "values-prod.yaml"

if (-not (Test-Path $valuesPath)) {
    Write-Error "values-prod.yaml not found at $valuesPath"
    exit 1
}

$content = Get-Content $valuesPath -Raw

# 1. Locate the kubernetes-nodes-cadvisor section
$cadvisorIdx = $content.IndexOf("kubernetes-nodes-cadvisor:")
if ($cadvisorIdx -lt 0) {
    Write-Error "values-prod.yaml missing kubernetes-nodes-cadvisor scrape config block"
    exit 1
}

$cadvisorBlock = $content.Substring($cadvisorIdx)
# Truncate at next top-level or sibling scrape config if needed
$nextSectionIdx = $cadvisorBlock.IndexOf("server:")
if ($nextSectionIdx -gt 0) {
    $cadvisorBlock = $cadvisorBlock.Substring(0, $nextSectionIdx)
}

# 2. Assert namespace keep rule remains techx-corp-prod
if ($cadvisorBlock -notmatch "regex:\s*techx-corp-prod") {
    Write-Error "kubernetes-nodes-cadvisor block missing expected namespace keep regex: techx-corp-prod"
    exit 1
}

# 3. Assert metric allowlist includes all required cAdvisor families including oom_events_total
$expectedMetricRegex = "regex:\s*container_\(cpu_usage_seconds_total\|memory_working_set_bytes\|oom_events_total\|fs_reads_bytes_total\|fs_writes_bytes_total\|network_receive_bytes_total\|network_transmit_bytes_total\)"
if ($cadvisorBlock -notmatch $expectedMetricRegex) {
    Write-Error "kubernetes-nodes-cadvisor metric allowlist does not retain container_oom_events_total along with required cAdvisor families"
    exit 1
}

Write-Host "cAdvisor resource metrics verification passed: container_oom_events_total is retained."
# Change trail: @hungxqt - 2026-07-29 - Added cAdvisor OOM resource metrics verification test.
