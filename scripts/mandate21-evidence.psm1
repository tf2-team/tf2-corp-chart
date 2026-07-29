Set-StrictMode -Version Latest

function New-Mandate21Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][string]$Detail
    )

    [pscustomobject]@{
        check = $Name
        status = if ($Passed) { "PASS" } else { "FAIL" }
        detail = $Detail
    }
}

function Test-InfraPreflightSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Snapshot)

    $checks = [System.Collections.Generic.List[object]]::new()
    $routes = [System.Collections.Generic.List[object]]::new()

    $clusterPresent = $null -ne $Snapshot.cluster
    $checks.Add((New-Mandate21Check "cluster.unique" $clusterPresent "Configured EKS cluster must resolve exactly once."))
    if ($clusterPresent) {
        $checks.Add((New-Mandate21Check "cluster.vpc" (-not [string]::IsNullOrWhiteSpace([string]$Snapshot.cluster.vpcId)) "VPC is derived from the configured EKS cluster."))
        $checks.Add((New-Mandate21Check "cluster.subnets" (@($Snapshot.cluster.subnetIds).Count -gt 0) "EKS must expose at least one configured subnet."))
    }

    foreach ($subnet in @($Snapshot.subnets)) {
        $defaultRoutes = @($subnet.defaultRoutes)
        $singleDefault = $defaultRoutes.Count -eq 1
        $route = if ($singleDefault) { $defaultRoutes[0] } else { $null }
        $nat = $subnet.natGateway
        $natIdMatches = $null -ne $route -and -not [string]::IsNullOrWhiteSpace([string]$route.natGatewayId) -and $null -ne $nat -and $route.natGatewayId -eq $nat.id
        $sameAz = $null -ne $nat -and $nat.availabilityZone -eq $subnet.availabilityZone
        $routeActive = $null -ne $route -and $route.state -eq "active"
        $natAvailable = $null -ne $nat -and $nat.state -eq "available"
        $passed = $singleDefault -and $natIdMatches -and $sameAz -and $routeActive -and $natAvailable

        $routes.Add([pscustomobject]@{
            subnetId = $subnet.id
            availabilityZone = $subnet.availabilityZone
            routeTableId = $subnet.routeTableId
            defaultRoutes = $defaultRoutes
            natGatewayId = if ($null -ne $nat) { $nat.id } else { $null }
            natAvailabilityZone = if ($null -ne $nat) { $nat.availabilityZone } else { $null }
            status = if ($passed) { "PASS" } else { "FAIL" }
        })
        $checks.Add((New-Mandate21Check "network.privateSubnet.$($subnet.id).sameAzNat" $passed "Exactly one active IPv4 default route must target an available NAT gateway in the same AZ."))
    }

    if ($clusterPresent) {
        $checks.Add((New-Mandate21Check "network.subnetCoverage" (@($Snapshot.subnets).Count -eq @($Snapshot.cluster.subnetIds).Count) "Every EKS-configured subnet must have route evidence."))
    }

    $rdsItems = @($Snapshot.stores.rds)
    $checks.Add((New-Mandate21Check "rds.unique" ($rdsItems.Count -eq 1) "RDS identifier must resolve exactly once."))
    if ($rdsItems.Count -eq 1) {
        $rds = $rdsItems[0]
        $checks.Add((New-Mandate21Check "rds.available" ($rds.status -eq "available") "RDS must be available."))
        $checks.Add((New-Mandate21Check "rds.multiAz" ([bool]$rds.multiAz) "RDS Multi-AZ must be enabled."))
        $checks.Add((New-Mandate21Check "rds.encrypted" ([bool]$rds.storageEncrypted) "RDS storage encryption must be enabled."))
        $checks.Add((New-Mandate21Check "rds.deletionProtection" ([bool]$rds.deletionProtection) "RDS deletion protection must be enabled."))
        $checks.Add((New-Mandate21Check "rds.backupRetention" ([int]$rds.backupRetentionDays -ge 7) "RDS backup retention must be at least seven days."))
    }

    $valkeyItems = @($Snapshot.stores.valkey)
    $checks.Add((New-Mandate21Check "valkey.unique" ($valkeyItems.Count -eq 1) "Valkey replication group must resolve exactly once."))
    if ($valkeyItems.Count -eq 1) {
        $valkey = $valkeyItems[0]
        $checks.Add((New-Mandate21Check "valkey.available" ($valkey.status -eq "available") "Valkey must be available."))
        $checks.Add((New-Mandate21Check "valkey.multiAz" ($valkey.multiAz -eq "enabled") "Valkey Multi-AZ must be enabled."))
        $checks.Add((New-Mandate21Check "valkey.automaticFailover" ($valkey.automaticFailover -eq "enabled") "Valkey automatic failover must be enabled."))
        $checks.Add((New-Mandate21Check "valkey.transitEncryption" ([bool]$valkey.transitEncryption) "Valkey transit encryption must be enabled."))
        $checks.Add((New-Mandate21Check "valkey.atRestEncryption" ([bool]$valkey.atRestEncryption) "Valkey at-rest encryption must be enabled."))
    }

    $dynamoItems = @($Snapshot.stores.dynamoDb)
    $checks.Add((New-Mandate21Check "dynamodb.unique" ($dynamoItems.Count -eq 1) "DynamoDB table must resolve exactly once."))
    if ($dynamoItems.Count -eq 1) {
        $dynamo = $dynamoItems[0]
        $checks.Add((New-Mandate21Check "dynamodb.active" ($dynamo.status -eq "ACTIVE") "DynamoDB must be ACTIVE."))
        $checks.Add((New-Mandate21Check "dynamodb.deletionProtection" ([bool]$dynamo.deletionProtection) "DynamoDB deletion protection must be enabled."))
        $checks.Add((New-Mandate21Check "dynamodb.kms" ($dynamo.sseStatus -eq "ENABLED" -and $dynamo.sseType -eq "KMS" -and -not [string]::IsNullOrWhiteSpace([string]$dynamo.kmsKeyArn)) "DynamoDB KMS encryption must be enabled with a key identifier."))
        $checks.Add((New-Mandate21Check "dynamodb.pitr" ($dynamo.pitrStatus -eq "ENABLED") "DynamoDB PITR must be ENABLED."))
    }

    $mskItems = @($Snapshot.stores.msk)
    $checks.Add((New-Mandate21Check "msk.unique" ($mskItems.Count -eq 1) "MSK cluster name must resolve exactly once."))
    if ($mskItems.Count -eq 1) {
        $msk = $mskItems[0]
        $checks.Add((New-Mandate21Check "msk.active" ($msk.status -eq "ACTIVE") "MSK must be ACTIVE."))
        $checks.Add((New-Mandate21Check "msk.brokers" ([int]$msk.brokerCount -ge 2) "MSK must have at least two brokers."))
        $checks.Add((New-Mandate21Check "msk.tls" ($msk.clientBrokerEncryption -eq "TLS") "MSK client-to-broker encryption must be TLS-only."))
    }

    $failed = @($checks | Where-Object { $_.status -ne "PASS" })
    [pscustomobject]@{
        status = if ($failed.Count -eq 0) { "PASS" } else { "FAIL" }
        checks = @($checks)
        privateRouteEvidence = @($routes)
    }
}

function Test-CapacityProbeSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Snapshot)

    $checks = [System.Collections.Generic.List[object]]::new()
    $baselineIds = @($Snapshot.baselineNodeClaims | ForEach-Object { [string]$_.uid })
    $baselineAt = [datetime]$Snapshot.baselineAt
    $newClaims = @($Snapshot.observedNodeClaims | Where-Object {
        $baselineIds -notcontains [string]$_.uid -and [datetime]$_.createdAt -gt $baselineAt
    })
    $readyNewClaims = @($newClaims | Where-Object {
        $_.availabilityZone -eq $Snapshot.survivingAz -and [bool]$_.ready
    })

    $checks.Add((New-Mandate21Check "nodeclaim.new" ($newClaims.Count -gt 0) "At least one NodeClaim must be created after the recorded baseline."))
    $checks.Add((New-Mandate21Check "nodeclaim.survivingAz" ($readyNewClaims.Count -gt 0) "At least one new Ready NodeClaim must be in the surviving AZ."))

    $samples = @($Snapshot.samples | Sort-Object { [datetime]$_.timestamp })
    $requiredSampleCount = [int]([math]::Floor([int]$Snapshot.soakSeconds / [int]$Snapshot.sampleIntervalSeconds)) + 1
    $fullSpan = $samples.Count -ge 2 -and (([datetime]$samples[-1].timestamp - [datetime]$samples[0].timestamp).TotalSeconds -ge [int]$Snapshot.soakSeconds)
    $cadenceComplete = $samples.Count -ge $requiredSampleCount
    for ($index = 1; $index -lt $samples.Count; $index++) {
        $gap = (([datetime]$samples[$index].timestamp - [datetime]$samples[$index - 1].timestamp).TotalSeconds)
        if ($gap -gt ([int]$Snapshot.sampleIntervalSeconds + 5)) { $cadenceComplete = $false }
    }
    $checks.Add((New-Mandate21Check "soak.fullDuration" ($fullSpan -and $cadenceComplete) "Soak evidence must span the full duration at the configured sampling cadence."))

    $allSamplesReady = $samples.Count -gt 0
    foreach ($sample in $samples) {
        $sampleReady = (
            [int]$sample.desiredReplicas -eq [int]$Snapshot.requestedLoad.replicas -and
            [int]$sample.readyReplicas -eq [int]$Snapshot.requestedLoad.replicas -and
            [int64]$sample.readyCpuMilli -ge [int64]$Snapshot.requestedLoad.cpuMilli -and
            [int64]$sample.readyMemoryBytes -ge [int64]$Snapshot.requestedLoad.memoryBytes
        )
        if (-not $sampleReady) { $allSamplesReady = $false }
    }
    $checks.Add((New-Mandate21Check "probe.readyLoad" $allSamplesReady "Every soak sample must show all replicas Ready and at least the requested CPU and memory load."))

    $readyClaimNodes = @($readyNewClaims | ForEach-Object { [string]$_.nodeName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $samplesLinked = $samples.Count -gt 0 -and $readyClaimNodes.Count -gt 0
    foreach ($sample in $samples) {
        $sampleNodes = @($sample.readyNodeNames | Select-Object -Unique)
        if ($sampleNodes.Count -eq 0 -or @($sampleNodes | Where-Object { $readyClaimNodes -notcontains $_ }).Count -gt 0) { $samplesLinked = $false }
    }
    $checks.Add((New-Mandate21Check "probe.newNodeClaimAttribution" $samplesLinked "Every Ready probe pod must run on a node owned by a new Ready NodeClaim in the surviving AZ."))

    $failed = @($checks | Where-Object { $_.status -ne "PASS" })
    [pscustomobject]@{
        status = if ($failed.Count -eq 0) { "PASS" } else { "FAIL" }
        checks = @($checks)
        newNodeClaims = $newClaims
        readyNewNodeClaims = $readyNewClaims
    }
}

Export-ModuleMember -Function Test-InfraPreflightSnapshot, Test-CapacityProbeSnapshot

# Change trail: @hungxqt - 2026-07-29 - Added pure fail-closed evaluators for Mandate 21 infrastructure and capacity evidence.
