[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,
    [ValidateSet("ad", "recommendation")][string]$Dependency = "ad",
    [string]$Namespace = "techx-corp-prod",
    [int]$HoldSeconds = 60,
    [string]$ProbeUri = "",
    [string]$EvidenceDirectory = "",
    [switch]$Execute
)

$ErrorActionPreference = "Stop"
if ($HoldSeconds -lt 1) { throw "HoldSeconds must be positive" }

function Invoke-KubectlJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $raw = & kubectl --context $KubeContext @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed: kubectl --context $KubeContext $($Arguments -join ' ')"
    }
    return $raw | ConvertFrom-Json
}

function Get-ReadyEndpointCount {
    $sliceData = Invoke-KubectlJson @(
        "-n", $Namespace, "get", "endpointslices",
        "-l", "kubernetes.io/service-name=$Dependency", "-o", "json"
    )
    return @(
        $sliceData.items.endpoints |
            Where-Object { $_.conditions.ready -eq $true }
    ).Count
}

$deployment = Invoke-KubectlJson @("-n", $Namespace, "get", "deployment", $Dependency, "-o", "json")
$desiredReplicas = [int]$deployment.spec.replicas
if ($desiredReplicas -lt 1) { throw "${Dependency}: desired replicas must remain positive" }

$hpa = & kubectl --context $KubeContext -n $Namespace get hpa $Dependency --ignore-not-found -o name
if ($LASTEXITCODE -ne 0) { throw "Cannot inspect ${Dependency} HPA" }
if ($hpa) {
    throw "${Dependency}: active HPA owns replicas; use the fixed-replica ad dependency for this gate"
}

$selectorParts = @()
foreach ($property in $deployment.spec.selector.matchLabels.PSObject.Properties) {
    $selectorParts += "$($property.Name)=$($property.Value)"
}
if ($selectorParts.Count -eq 0) { throw "${Dependency}: Deployment has no matchLabels selector" }
$selector = $selectorParts -join ","

Write-Host "Target: $Namespace/deployment/$Dependency"
Write-Host "Desired replicas remain unchanged: $desiredReplicas"
Write-Host "Pod selector: $selector"
Write-Host "Fault: repeatedly delete replacement pods until EndpointSlice has 0 ready endpoints, then hold for $HoldSeconds seconds"

if (-not $Execute) {
    if ($PSBoundParameters.ContainsKey("WhatIf")) {
        Write-Host "WhatIf complete: no directory created and no cluster mutation performed."
        return
    }
    throw "Refusing live dependency chaos without -Execute (use -WhatIf for a non-mutating preview)"
}
if (-not $PSCmdlet.ShouldProcess(
    "$Namespace/deployment/$Dependency",
    "repeatedly delete dependency pods while preserving desired replicas"
)) { return }

if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $PSScriptRoot "..\docs\evidence\mandate-17\dependency-$Dependency"
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$deployment | ConvertTo-Json -Depth 30 |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "deployment-before.json")

$samples = [System.Collections.Generic.List[object]]::new()
$faultStartedAt = Get-Date
$acceptanceStartedAt = $null
$acceptanceDeadline = $null
$startupDeadline = $faultStartedAt.AddMinutes(2)

try {
    while ($null -eq $acceptanceDeadline -or (Get-Date) -lt $acceptanceDeadline) {
        $podData = Invoke-KubectlJson @(
            "-n", $Namespace, "get", "pods", "-l", $selector, "-o", "json"
        )
        $podNames = @(
            $podData.items |
                Where-Object { $_.metadata.deletionTimestamp -eq $null } |
                ForEach-Object { $_.metadata.name }
        )
        if ($podNames.Count -gt 0) {
            & kubectl --context $KubeContext -n $Namespace delete pod @podNames --wait=false |
                Out-File -Append -Encoding utf8 (Join-Path $EvidenceDirectory "deletion-loop.txt")
            if ($LASTEXITCODE -ne 0) { throw "Failed to delete ${Dependency} replacement pod(s)" }
        }

        $readyEndpoints = Get-ReadyEndpointCount
        if ($readyEndpoints -eq 0 -and $null -eq $acceptanceDeadline) {
            $acceptanceStartedAt = Get-Date
            $acceptanceDeadline = $acceptanceStartedAt.AddSeconds($HoldSeconds)
            Write-Host "Acceptance window opened at $($acceptanceStartedAt.ToString('o'))"
        }
        if ($null -eq $acceptanceDeadline -and (Get-Date) -gt $startupDeadline) {
            throw "Dependency never reached 0 ready endpoints within 2 minutes"
        }

        if ($ProbeUri -and $null -ne $acceptanceDeadline) {
            $separator = if ($ProbeUri.Contains("?")) { "&" } else { "?" }
            $uri = "$ProbeUri${separator}mandate17=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
            try {
                $response = Invoke-WebRequest -Uri $uri -TimeoutSec 10 -UseBasicParsing
                $samples.Add([pscustomobject]@{
                    time = (Get-Date).ToString("o")
                    uri = $uri
                    status = [int]$response.StatusCode
                    degraded = [string]$response.Headers["X-TechX-Degraded-Dependencies"]
                    body = [string]$response.Content
                    readyEndpoints = $readyEndpoints
                })
            }
            catch {
                $samples.Add([pscustomobject]@{
                    time = (Get-Date).ToString("o")
                    uri = $uri
                    status = 0
                    degraded = ""
                    body = $_.Exception.Message
                    readyEndpoints = $readyEndpoints
                })
            }
        }
        Start-Sleep -Seconds 2
    }

    if ($ProbeUri) {
        $samples | ConvertTo-Json -Depth 5 |
            Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "probe-samples.json")
        $failed = @($samples | Where-Object {
            $_.status -ne 200 -or
            $_.degraded -notmatch "(^|,\s*)$([regex]::Escape($Dependency))(\s*,|$)" -or
            $_.body.Trim() -ne "[]"
        })
        if ($samples.Count -eq 0 -or $failed.Count -gt 0) {
            throw "Fallback contract failed: samples=$($samples.Count), failed=$($failed.Count)"
        }
    }

    & kubectl --context $KubeContext -n $Namespace logs deployment/frontend --since=10m --all-containers=true |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "frontend-fallback-logs.txt")
}
finally {
    $recoveryStartedAt = Get-Date
    & kubectl --context $KubeContext -n $Namespace rollout status deployment $Dependency --timeout=5m
    $rolloutExit = $LASTEXITCODE
    $recovered = Invoke-KubectlJson @("-n", $Namespace, "get", "deployment", $Dependency, "-o", "json")
    [pscustomobject]@{
        dependency = $Dependency
        desiredReplicas = [int]$recovered.spec.replicas
        readyReplicas = [int]$recovered.status.readyReplicas
        availableReplicas = [int]$recovered.status.availableReplicas
        faultStartedAt = $faultStartedAt.ToString("o")
        acceptanceStartedAt = if ($acceptanceStartedAt) { $acceptanceStartedAt.ToString("o") } else { $null }
        recoveryStartedAt = $recoveryStartedAt.ToString("o")
        recoveryFinishedAt = (Get-Date).ToString("o")
        rolloutExitCode = $rolloutExit
    } | ConvertTo-Json |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "recovery.json")

    if ($rolloutExit -ne 0 -or
        [int]$recovered.spec.replicas -ne $desiredReplicas -or
        [int]$recovered.status.availableReplicas -ne $desiredReplicas) {
        throw "${Dependency} recovery failed"
    }
}
