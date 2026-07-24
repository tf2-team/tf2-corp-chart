[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,
    [Parameter(Mandatory = $true)][string]$Zone,
    [string]$Namespace = "techx-corp-prod",
    [int]$HoldSeconds = 300,
    [string]$EvidenceDirectory = "",
    [switch]$CapacityApproved,
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

$nodeData = Invoke-KubectlJson @("get", "nodes", "-o", "json")
$zoneNodes = @($nodeData.items | Where-Object {
    $_.metadata.labels."topology.kubernetes.io/zone" -eq $Zone -and
    ($_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" })
})
$survivingNodes = @($nodeData.items | Where-Object {
    $_.metadata.labels."topology.kubernetes.io/zone" -ne $Zone -and
    ($_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" })
})
if ($zoneNodes.Count -eq 0) { throw "No Ready nodes found in zone $Zone" }
if ($survivingNodes.Count -eq 0) { throw "No Ready recovery nodes remain outside zone $Zone" }
$nodeNames = @($zoneNodes.metadata.name)

$deploymentData = Invoke-KubectlJson @("-n", $Namespace, "get", "deployments", "-o", "json")
$firstPartyDeployments = @(
    $deploymentData.items |
        Where-Object {
            $_.metadata.name -notmatch "^(load-generator|locust)" -and
            $_.metadata.labels."app.kubernetes.io/managed-by" -ne "Helm-operator"
        } |
        ForEach-Object { $_.metadata.name }
)
if ($firstPartyDeployments.Count -eq 0) { throw "No first-party Deployments found" }

$replicaSetData = Invoke-KubectlJson @("-n", $Namespace, "get", "replicasets", "-o", "json")
$replicaSetToDeployment = @{}
foreach ($rs in $replicaSetData.items) {
    $owner = @($rs.metadata.ownerReferences | Where-Object {
        $_.kind -eq "Deployment" -and $_.controller -eq $true
    } | Select-Object -First 1)
    if ($owner.Count -eq 1) { $replicaSetToDeployment[$rs.metadata.name] = $owner[0].name }
}

$podData = Invoke-KubectlJson @("-n", $Namespace, "get", "pods", "-o", "json")
$targets = @(
    $podData.items |
        Where-Object {
            if ($_.spec.nodeName -notin $nodeNames) { return $false }
            $rsOwner = @($_.metadata.ownerReferences | Where-Object {
                $_.kind -eq "ReplicaSet" -and $_.controller -eq $true
            } | Select-Object -First 1)
            if ($rsOwner.Count -ne 1) { return $false }
            $deploymentName = $replicaSetToDeployment[$rsOwner[0].name]
            return $deploymentName -and $deploymentName -in $firstPartyDeployments
        } |
        ForEach-Object {
            $rsOwner = @($_.metadata.ownerReferences | Where-Object {
                $_.kind -eq "ReplicaSet" -and $_.controller -eq $true
            } | Select-Object -First 1)
            [pscustomobject]@{
                pod = $_.metadata.name
                deployment = $replicaSetToDeployment[$rsOwner[0].name]
                node = $_.spec.nodeName
                zone = $Zone
            }
        }
)
if ($targets.Count -eq 0) { throw "No first-party Deployment pods found in zone $Zone" }

Write-Host "Fault zone: $Zone"
Write-Host "Nodes to cordon: $($nodeNames -join ', ')"
Write-Host "Surviving Ready nodes: $($survivingNodes.Count)"
Write-Host "First-party Deployment pod targets (load-generator/Jobs/StatefulSets excluded):"
$targets | Sort-Object deployment, pod | Format-Table -AutoSize

if (-not $Execute) {
    if ($PSBoundParameters.ContainsKey("WhatIf")) {
        Write-Host "WhatIf complete: no directory created and no cluster mutation performed."
        return
    }
    throw "Refusing live AZ chaos without -Execute (use -WhatIf for a non-mutating preview)"
}
if (-not $CapacityApproved) {
    throw "Refusing AZ chaos until surviving-zone capacity is reviewed (-CapacityApproved)"
}
if (-not $PSCmdlet.ShouldProcess(
    "$Zone ($($nodeNames.Count) nodes, $($targets.Count) pods)",
    "cordon zone nodes and delete first-party Deployment pods"
)) { return }

if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $PSScriptRoot "..\docs\evidence\mandate-17\az-$Zone"
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$nodeData | ConvertTo-Json -Depth 30 |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "nodes-before.json")
$targets | ConvertTo-Json -Depth 5 |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "targets-reviewed.json")
& kubectl --context $KubeContext top nodes 2>&1 |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "node-usage-before.txt")
& kubectl --context $KubeContext -n $Namespace get pods -o wide |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "pods-before.txt")

$cordoned = [System.Collections.Generic.List[string]]::new()
$cleanup = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($node in $nodeNames) {
        & kubectl --context $KubeContext cordon $node
        if ($LASTEXITCODE -ne 0) { throw "Failed to cordon $node" }
        $cordoned.Add($node)
    }

    $podNames = @($targets.pod)
    & kubectl --context $KubeContext -n $Namespace delete pod @podNames --wait=false
    if ($LASTEXITCODE -ne 0) { throw "Failed to delete AZ application pods" }

    $faultDeadline = (Get-Date).AddSeconds($HoldSeconds)
    do {
        $currentPods = Invoke-KubectlJson @("-n", $Namespace, "get", "pods", "-o", "json")
        $readyOnFaultNodes = @($currentPods.items | Where-Object {
            $_.spec.nodeName -in $nodeNames -and
            $_.metadata.name -in $podNames -and
            ($_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" })
        })
        if ($readyOnFaultNodes.Count -gt 0) {
            throw "Fault invalid: $($readyOnFaultNodes.Count) targeted pod(s) remain Ready on fault-zone nodes"
        }
        Start-Sleep -Seconds ([Math]::Min(10, [Math]::Max(1, [int](($faultDeadline - (Get-Date)).TotalSeconds))))
    } while ((Get-Date) -lt $faultDeadline)

    & kubectl --context $KubeContext -n $Namespace get pods -o wide |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "pods-fault-window.txt")
}
finally {
    foreach ($node in $cordoned) {
        $exists = & kubectl --context $KubeContext get node $node --ignore-not-found -o name
        if ($LASTEXITCODE -ne 0) {
            $cleanup.Add([pscustomobject]@{ node = $node; result = "lookup-failed" })
            continue
        }
        if (-not $exists) {
            $cleanup.Add([pscustomobject]@{ node = $node; result = "NotFound/replaced" })
            continue
        }
        & kubectl --context $KubeContext uncordon $node
        $cleanup.Add([pscustomobject]@{
            node = $node
            result = if ($LASTEXITCODE -eq 0) { "uncordoned" } else { "uncordon-failed" }
        })
    }
    $cleanup | ConvertTo-Json -Depth 5 |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "cleanup.json")

    $remainingCordons = @(
        (Invoke-KubectlJson @("get", "nodes", "-o", "json")).items |
            Where-Object { $_.spec.unschedulable -eq $true }
    )
    if ($remainingCordons.Count -gt 0) {
        throw "Cleanup failed: node(s) remain cordoned: $($remainingCordons.metadata.name -join ', ')"
    }

    & kubectl --context $KubeContext -n $Namespace wait deployment --all `
        --for=condition=Available --timeout=10m
    if ($LASTEXITCODE -ne 0) { throw "Workload recovery failed" }
    & kubectl --context $KubeContext -n $Namespace get pods -o wide |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "pods-after-restore.txt")
}
