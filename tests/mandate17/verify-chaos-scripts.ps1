$ErrorActionPreference = "Stop"
$chartRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

function Assert-ScriptParses([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw "$Path has PowerShell parse errors: $($errors.Message -join '; ')"
    }
}

$dependencyPath = Join-Path $chartRoot "scripts\mandate17-dependency-chaos.ps1"
$azPath = Join-Path $chartRoot "scripts\mandate17-az-chaos.ps1"
Assert-ScriptParses $dependencyPath
Assert-ScriptParses $azPath

$dependency = Get-Content -Raw $dependencyPath
foreach ($required in @(
    "[switch]`$Execute",
    "use -WhatIf for a non-mutating preview",
    "get`", `"endpointslices`"",
    "readyEndpoints -eq 0",
    "delete pod @podNames --wait=false",
    "body.Trim() -ne `"[]`"",
    "X-TechX-Degraded-Dependencies",
    "rollout status deployment"
)) {
    if ($dependency -notmatch [regex]::Escape($required)) {
        throw "Dependency chaos script missing contract: $required"
    }
}
if ($dependency -match "scale deployment") {
    throw "Dependency chaos must preserve Deployment desired replicas"
}

$az = Get-Content -Raw $azPath
foreach ($required in @(
    "[switch]`$Execute",
    "[switch]`$CapacityApproved",
    "[switch]`$FenceProvisioning",
    "[int]`$EvacuationTimeoutSeconds",
    "[string[]]`$NodePoolNames",
    "stateless-spot",
    "stateless-on-demand",
    "get`", `"nodepool`"",
    "patch nodepool",
    "-before.json",
    "-fenced.json",
    "-restored.json",
    "resourceVersion",
    "new node(s) appeared in fenced zone",
    "fault-boundary.json",
    "Fault boundary established",
    "concurrent drift",
    "get`", `"deployments`"",
    "get`", `"replicasets`"",
    "^load-generator(-worker)?`$",
    "^flagd`$",
    "^prometheus(-adapter)?`$",
    "app.kubernetes.io/part-of",
    "targets-reviewed.json",
    "NotFound/replaced",
    "node(s) remain cordoned",
    "wait deployment --all"
)) {
    if ($az -notmatch [regex]::Escape($required)) {
        throw "AZ chaos script missing contract: $required"
    }
}
if (
    $az.IndexOf('$evacuationDeadline') -lt 0 -or
    $az.IndexOf('$faultDeadline') -lt 0 -or
    $az.IndexOf('$evacuationDeadline') -ge $az.IndexOf('$faultDeadline')
) {
    throw "AZ chaos must establish evacuation before starting the fault hold window"
}

Write-Host "Mandate 17 dependency and AZ chaos script contracts passed."
