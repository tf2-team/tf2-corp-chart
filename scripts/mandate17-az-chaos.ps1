[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$KubeContext,
    [Parameter(Mandatory = $true)][string]$Zone,
    [string]$Namespace = "techx-corp-prod",
    [int]$HoldSeconds = 300,
    [string]$EvidenceDirectory = "",
    [string[]]$NodePoolNames = @("stateless-spot", "stateless-on-demand"),
    [switch]$CapacityApproved,
    [switch]$FenceProvisioning,
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

function Test-StringArrayEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$Left,
        [Parameter(Mandatory = $true)][object[]]$Right
    )
    return (@($Left | Sort-Object) -join "`n") -eq (@($Right | Sort-Object) -join "`n")
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

$nodePoolSnapshots = [System.Collections.Generic.List[object]]::new()
foreach ($nodePoolName in $NodePoolNames) {
    $nodePoolData = Invoke-KubectlJson @("get", "nodepool", $nodePoolName, "-o", "json")
    $zoneRequirementMatches = @(
        for ($index = 0; $index -lt $nodePoolData.spec.template.spec.requirements.Count; $index++) {
            $requirement = $nodePoolData.spec.template.spec.requirements[$index]
            if ($requirement.key -eq "topology.kubernetes.io/zone") {
                [pscustomobject]@{ index = $index; requirement = $requirement }
            }
        }
    )
    if ($zoneRequirementMatches.Count -ne 1) {
        throw "NodePool $nodePoolName must have exactly one topology.kubernetes.io/zone requirement"
    }
    $zoneRequirementIndex = $zoneRequirementMatches[0].index
    $originalZoneRequirement = $zoneRequirementMatches[0].requirement
    if ($originalZoneRequirement.operator -ne "In" -or $Zone -notin $originalZoneRequirement.values) {
        throw "NodePool $nodePoolName does not provision into fault zone $Zone through an In requirement"
    }
    $originalZoneValues = @($originalZoneRequirement.values)
    $survivingZoneValues = @($originalZoneValues | Where-Object { $_ -ne $Zone })
    if ($survivingZoneValues.Count -eq 0) {
        throw "NodePool $nodePoolName has no surviving zone after excluding $Zone"
    }
    $nodePoolSnapshots.Add([pscustomobject]@{
        name = $nodePoolName
        data = $nodePoolData
        requirementIndex = $zoneRequirementIndex
        originalRequirement = $originalZoneRequirement
        originalValues = $originalZoneValues
        survivingValues = $survivingZoneValues
    })
}

$excludedDeploymentPattern = @(
    "^load-generator(-worker)?$",
    "^flagd$",
    "^egress-proxy$",
    "^grafana$",
    "^jaeger$",
    "^metrics-server$",
    "^prometheus(-adapter)?$",
    "^techx-corp-kube-state-metrics$",
    "^otel-collector"
) -join "|"

$deploymentData = Invoke-KubectlJson @("-n", $Namespace, "get", "deployments", "-o", "json")
$firstPartyDeployments = @(
    $deploymentData.items |
        Where-Object {
            $_.metadata.labels."app.kubernetes.io/part-of" -eq "techx-corp" -and
            $_.metadata.name -notmatch $excludedDeploymentPattern -and
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
foreach ($snapshot in $nodePoolSnapshots) {
    Write-Host "Provisioning fence: NodePool $($snapshot.name) zones [$($snapshot.originalValues -join ', ')] -> [$($snapshot.survivingValues -join ', ')]"
}
Write-Host "First-party Deployment pod targets (load-generator, flagd, platform/observability, Jobs and StatefulSets excluded):"
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
if (-not $FenceProvisioning) {
    throw "Refusing AZ chaos without -FenceProvisioning; otherwise Karpenter can replace capacity inside the fault AZ"
}
if (-not $PSCmdlet.ShouldProcess(
    "$Zone ($($nodeNames.Count) nodes, $($targets.Count) pods)",
    "fence Karpenter provisioning, cordon zone nodes and delete first-party Deployment pods"
)) { return }

if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $PSScriptRoot "..\docs\evidence\mandate-17\az-$Zone"
}
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
$nodeData | ConvertTo-Json -Depth 30 |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "nodes-before.json")
foreach ($snapshot in $nodePoolSnapshots) {
    $snapshot.data | ConvertTo-Json -Depth 30 |
        Out-File -Encoding utf8 (
            Join-Path $EvidenceDirectory "nodepool-$($snapshot.name)-before.json"
        )
}
$targets | ConvertTo-Json -Depth 5 |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "targets-reviewed.json")
& kubectl --context $KubeContext top nodes 2>&1 |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "node-usage-before.txt")
& kubectl --context $KubeContext -n $Namespace get pods -o wide |
    Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "pods-before.txt")

$cordoned = [System.Collections.Generic.List[string]]::new()
$cleanup = [System.Collections.Generic.List[object]]::new()
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$fencedNodePools = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($snapshot in $nodePoolSnapshots) {
        $fenceOperations = @(
            @{
                op = "test"
                path = "/metadata/resourceVersion"
                value = [string]$snapshot.data.metadata.resourceVersion
            },
            @{
                op = "test"
                path = "/spec/template/spec/requirements/$($snapshot.requirementIndex)"
                value = $snapshot.originalRequirement
            },
            @{
                op = "replace"
                path = "/spec/template/spec/requirements/$($snapshot.requirementIndex)/values"
                value = $snapshot.survivingValues
            }
        )
        $fencePatch = ConvertTo-Json -InputObject @($fenceOperations) -Depth 20 -Compress
        & kubectl --context $KubeContext patch nodepool $snapshot.name --type=json --patch $fencePatch
        if ($LASTEXITCODE -ne 0) { throw "Failed to fence NodePool $($snapshot.name)" }
        $fencedNodePools.Add($snapshot.name)

        $fencedNodePool = Invoke-KubectlJson @("get", "nodepool", $snapshot.name, "-o", "json")
        $fencedZoneRequirement = $fencedNodePool.spec.template.spec.requirements[$snapshot.requirementIndex]
        if (
            $fencedZoneRequirement.key -ne "topology.kubernetes.io/zone" -or
            $fencedZoneRequirement.operator -ne "In" -or
            -not (Test-StringArrayEqual @($fencedZoneRequirement.values) $snapshot.survivingValues)
        ) {
            throw "NodePool $($snapshot.name) fence verification failed"
        }
        $fencedNodePool | ConvertTo-Json -Depth 30 |
            Out-File -Encoding utf8 (
                Join-Path $EvidenceDirectory "nodepool-$($snapshot.name)-fenced.json"
            )
    }

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
        $currentNodes = Invoke-KubectlJson @("get", "nodes", "-o", "json")
        $currentFaultNodeNames = @(
            $currentNodes.items |
                Where-Object {
                    $_.metadata.labels."topology.kubernetes.io/zone" -eq $Zone
                } |
                ForEach-Object { $_.metadata.name }
        )
        $unexpectedFaultNodes = @($currentFaultNodeNames | Where-Object { $_ -notin $nodeNames })
        if ($unexpectedFaultNodes.Count -gt 0) {
            throw "Fault invalid: new node(s) appeared in fenced zone ${Zone}: $($unexpectedFaultNodes -join ', ')"
        }

        $currentPods = Invoke-KubectlJson @("-n", $Namespace, "get", "pods", "-o", "json")
        $readyOnFaultNodes = @(
            $currentPods.items |
                Where-Object {
                    if ($_.spec.nodeName -notin $currentFaultNodeNames) { return $false }
                    $rsOwner = @($_.metadata.ownerReferences | Where-Object {
                        $_.kind -eq "ReplicaSet" -and $_.controller -eq $true
                    } | Select-Object -First 1)
                    if ($rsOwner.Count -ne 1) { return $false }
                    $deploymentName = $replicaSetToDeployment[$rsOwner[0].name]
                    return $deploymentName -in $firstPartyDeployments -and
                        ($_.status.conditions | Where-Object {
                            $_.type -eq "Ready" -and $_.status -eq "True"
                        })
                }
        )
        if ($readyOnFaultNodes.Count -gt 0) {
            throw "Fault invalid: $($readyOnFaultNodes.Count) first-party pod(s) remain Ready in fault zone"
        }
        Start-Sleep -Seconds ([Math]::Min(10, [Math]::Max(1, [int](($faultDeadline - (Get-Date)).TotalSeconds))))
    } while ((Get-Date) -lt $faultDeadline)

    & kubectl --context $KubeContext -n $Namespace get pods -o wide |
        Out-File -Encoding utf8 (Join-Path $EvidenceDirectory "pods-fault-window.txt")
}
finally {
    foreach ($snapshot in $nodePoolSnapshots) {
        if ($snapshot.name -notin $fencedNodePools) { continue }
        try {
            $currentNodePool = Invoke-KubectlJson @("get", "nodepool", $snapshot.name, "-o", "json")
            $currentZoneMatches = @(
                for ($index = 0; $index -lt $currentNodePool.spec.template.spec.requirements.Count; $index++) {
                    $requirement = $currentNodePool.spec.template.spec.requirements[$index]
                    if ($requirement.key -eq "topology.kubernetes.io/zone") {
                        [pscustomobject]@{ index = $index; requirement = $requirement }
                    }
                }
            )
            if ($currentZoneMatches.Count -ne 1) {
                throw "Cannot safely restore: NodePool zone requirement count changed"
            }
            $restoreIndex = $currentZoneMatches[0].index
            $currentZoneRequirement = $currentZoneMatches[0].requirement
            if (Test-StringArrayEqual @($currentZoneRequirement.values) $snapshot.originalValues) {
                $cleanup.Add([pscustomobject]@{
                    nodePool = $snapshot.name
                    result = "already-restored"
                })
            }
            elseif (
                $currentZoneRequirement.operator -eq "In" -and
                (Test-StringArrayEqual @($currentZoneRequirement.values) $snapshot.survivingValues)
            ) {
                $restoreOperations = @(
                    @{
                        op = "test"
                        path = "/metadata/resourceVersion"
                        value = [string]$currentNodePool.metadata.resourceVersion
                    },
                    @{
                        op = "test"
                        path = "/spec/template/spec/requirements/$restoreIndex"
                        value = $currentZoneRequirement
                    },
                    @{
                        op = "replace"
                        path = "/spec/template/spec/requirements/$restoreIndex/values"
                        value = $snapshot.originalValues
                    }
                )
                $restorePatch = ConvertTo-Json -InputObject @($restoreOperations) -Depth 20 -Compress
                & kubectl --context $KubeContext patch nodepool $snapshot.name --type=json --patch $restorePatch
                if ($LASTEXITCODE -ne 0) { throw "NodePool restore patch failed" }
                $cleanup.Add([pscustomobject]@{ nodePool = $snapshot.name; result = "restored" })
            }
            else {
                throw "Cannot safely restore: NodePool zone requirement has concurrent drift"
            }

            $restoredNodePool = Invoke-KubectlJson @("get", "nodepool", $snapshot.name, "-o", "json")
            $restoredZoneRequirement = @(
                $restoredNodePool.spec.template.spec.requirements |
                    Where-Object { $_.key -eq "topology.kubernetes.io/zone" }
            )
            if (
                $restoredZoneRequirement.Count -ne 1 -or
                -not (Test-StringArrayEqual @($restoredZoneRequirement[0].values) $snapshot.originalValues)
            ) {
                throw "NodePool restore verification failed"
            }
            $restoredNodePool | ConvertTo-Json -Depth 30 |
                Out-File -Encoding utf8 (
                    Join-Path $EvidenceDirectory "nodepool-$($snapshot.name)-restored.json"
                )
        }
        catch {
            $cleanupErrors.Add($_.Exception.Message)
            $cleanup.Add([pscustomobject]@{
                nodePool = $snapshot.name
                result = "restore-failed"
            })
        }
    }

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

    if ($cleanupErrors.Count -gt 0) {
        throw "Cleanup failed: $($cleanupErrors -join '; ')"
    }
}
