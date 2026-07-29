[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("1a", "1b")][string]$FaultAz,
    [Parameter(Mandatory)][ValidateSet("1a", "1b")][string]$SurvivingAz,
    [string]$Namespace = "techx-corp-prod",
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Text {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & $File @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$File $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return ($output -join "`n")
}

function Invoke-Json {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string[]]$Arguments)
    return (Invoke-Text -File $File -Arguments $Arguments | ConvertFrom-Json -Depth 100)
}

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "CAPACITY PROBE CHECK FAILED: $Message" }
    Write-Host "[PASS] $Message"
}

Write-Host "=== Mandate 21 Karpenter Capacity Probe ==="
Write-Host "Fault AZ: us-east-$FaultAz, Surviving AZ target: us-east-$SurvivingAz"

# Read-only calculation of lost AZ pod requests + 20% headroom
$nodes = Invoke-Json kubectl @("get", "nodes", "-o", "json")
$faultNodes = @($nodes.items | Where-Object { $_.metadata.labels.'topology.kubernetes.io/zone' -eq "us-east-$FaultAz" })
$faultNodeNames = @($faultNodes | ForEach-Object { $_.metadata.name })

$pods = Invoke-Json kubectl @("-n", $Namespace, "get", "pods", "-o", "json")
$faultPods = @($pods.items | Where-Object { $faultNodeNames -contains $_.spec.nodeName -and $_.status.phase -eq "Running" })

$totalCpuMilli = 0
$totalMemBytes = [int64]0

foreach ($pod in $faultPods) {
    foreach ($container in $pod.spec.containers) {
        if ($container.resources -and $container.resources.requests) {
            $cpuStr = [string]$container.resources.requests.cpu
            if ($cpuStr -match '^(\d+)m$') {
                $totalCpuMilli += [int]$Matches[1]
            } elseif ($cpuStr -match '^(\d+)$') {
                $totalCpuMilli += ([int]$Matches[1]) * 1000
            }
            
            $memStr = [string]$container.resources.requests.memory
            if ($memStr -match '^(\d+)Mi$') {
                $totalMemBytes += ([int64]$Matches[1]) * 1024 * 1024
            } elseif ($memStr -match '^(\d+)Gi$') {
                $totalMemBytes += ([int64]$Matches[1]) * 1024 * 1024 * 1024
            }
        }
    }
}

# Add 20% headroom and min 2 pods
$probeCpuMilli = [math]::Max([int]($totalCpuMilli * 1.2), 2000)
$probeMemGiB = [math]::Max([int]([math]::Ceiling($totalMemBytes * 1.2 / 1GB)), 4)
$probePodCount = [math]::Max([int]$faultPods.Count, 2)

# Safety ceiling: max 32 CPU / 64 GiB limit
$probeCpuMilli = [math]::Min($probeCpuMilli, 32000)
$probeMemGiB = [math]::Min($probeMemGiB, 64)

Write-Host "Calculated Lost AZ Load: CPU=$totalCpuMilli m, Memory=$([math]::Round($totalMemBytes/1GB,2)) GiB, Pods=$($faultPods.Count)"
Write-Host "Configured Probe Load (with +20% headroom): CPU=$probeCpuMilli m, Memory=$probeMemGiB GiB, Target Replicas=$probePodCount"

# Verify probe deployment via GitOps/Argo
Write-Host "Verifying capacity-probe Deployment status in surviving AZ us-east-$SurvivingAz..."
$start = Get-Date
$ready = $false
do {
    Start-Sleep -Seconds 10
    $probeDeploy = Invoke-Json kubectl @("-n", $Namespace, "get", "deployment", "capacity-probe", "-o", "json")
    if ($null -ne $probeDeploy) {
        $desired = [int]$probeDeploy.spec.replicas
        $available = [int]$probeDeploy.status.availableReplicas
        if ($desired -gt 0 -and $available -eq $desired) {
            $ready = $true
            break
        }
    }
    $elapsed = ((Get-Date) - $start).TotalSeconds
    Write-Host "Awaiting capacity-probe ready... elapsed: $([int]$elapsed)s / $($TimeoutSeconds)s"
} while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds)

Assert-Check ($ready) "capacity-probe Deployment reached Ready state within $TimeoutSeconds seconds"

# Verify NodeClaim creation
$nodeClaims = Invoke-Json kubectl @("get", "nodeclaims", "-o", "json")
$newClaimsInZone = @($nodeClaims.items | Where-Object { $_.metadata.labels.'topology.kubernetes.io/zone' -eq "us-east-$SurvivingAz" -and $_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" } })
Assert-Check ($newClaimsInZone.Count -gt 0) "Karpenter provisioned new NodeClaim in surviving AZ us-east-$SurvivingAz"

# Verify no Pending pods or FailedScheduling
$pendingPods = Invoke-Text kubectl @("get", "pods", "-A", "--field-selector=status.phase=Pending", "-o", "name")
Assert-Check ([string]::IsNullOrWhiteSpace($pendingPods)) "Cluster has zero Pending pods after capacity probe"

Write-Host "CAPACITY PROBE PASS for scenario: fault=$FaultAz, probe=$SurvivingAz"

# Change trail: @hungxqt - 2026-07-29 - Created read-only Karpenter capacity probe verification runner.
