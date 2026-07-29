$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "../../scripts/mandate21-evidence.psm1") -Force

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Copy-Fixture($Value) { return ($Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100) }
function New-InfraFixture {
    [pscustomobject]@{
        cluster = [pscustomobject]@{ vpcId = "vpc-1"; subnetIds = @("subnet-a", "subnet-b") }
        subnets = @(
            [pscustomobject]@{ id = "subnet-a"; availabilityZone = "us-east-1a"; routeTableId = "rtb-a"; defaultRoutes = @([pscustomobject]@{ natGatewayId = "nat-a"; state = "active" }); natGateway = [pscustomobject]@{ id = "nat-a"; availabilityZone = "us-east-1a"; state = "available" } },
            [pscustomobject]@{ id = "subnet-b"; availabilityZone = "us-east-1b"; routeTableId = "rtb-b"; defaultRoutes = @([pscustomobject]@{ natGatewayId = "nat-b"; state = "active" }); natGateway = [pscustomobject]@{ id = "nat-b"; availabilityZone = "us-east-1b"; state = "available" } }
        )
        stores = [pscustomobject]@{
            rds = @([pscustomobject]@{ status = "available"; multiAz = $true; storageEncrypted = $true; deletionProtection = $true; backupRetentionDays = 7 })
            valkey = @([pscustomobject]@{ status = "available"; multiAz = "enabled"; automaticFailover = "enabled"; transitEncryption = $true; atRestEncryption = $true })
            dynamoDb = @([pscustomobject]@{ status = "ACTIVE"; deletionProtection = $true; sseStatus = "ENABLED"; sseType = "KMS"; kmsKeyArn = "arn:aws:kms:us-east-1:123456789012:key/example"; pitrStatus = "ENABLED" })
            msk = @([pscustomobject]@{ status = "ACTIVE"; brokerCount = 2; clientBrokerEncryption = "TLS" })
        }
    }
}
function New-CapacityFixture {
    $start = [datetime]"2026-07-29T00:00:00Z"
    $samples = 0..10 | ForEach-Object { [pscustomobject]@{ timestamp = $start.AddSeconds($_ * 30).ToString("o"); desiredReplicas = 2; readyReplicas = 2; readyCpuMilli = 2400; readyMemoryBytes = 2516582400; readyNodeNames = @("node-new") } }
    [pscustomobject]@{
        baselineAt = $start.ToString("o")
        baselineNodeClaims = @([pscustomobject]@{ uid = "old"; createdAt = $start.AddMinutes(-5).ToString("o"); availabilityZone = "us-east-1a"; ready = $true })
        observedNodeClaims = @([pscustomobject]@{ uid = "old"; createdAt = $start.AddMinutes(-5).ToString("o"); availabilityZone = "us-east-1a"; ready = $true }, [pscustomobject]@{ uid = "new"; createdAt = $start.AddSeconds(1).ToString("o"); availabilityZone = "us-east-1b"; nodeName = "node-new"; ready = $true })
        survivingAz = "us-east-1b"
        requestedLoad = [pscustomobject]@{ replicas = 2; cpuMilli = 2000; memoryBytes = 2147483648 }
        soakSeconds = 300
        sampleIntervalSeconds = 30
        samples = @($samples)
    }
}

Assert-True ((Test-InfraPreflightSnapshot (New-InfraFixture)).status -eq "PASS") "valid infrastructure fixture must pass"
$wrongNat = New-InfraFixture; $wrongNat.subnets[0].natGateway.availabilityZone = "us-east-1b"
Assert-True ((Test-InfraPreflightSnapshot $wrongNat).status -eq "FAIL") "wrong-AZ NAT must fail"
foreach ($store in @("rds", "valkey", "dynamoDb", "msk")) { $fixture = New-InfraFixture; $fixture.stores.$store = @(); Assert-True ((Test-InfraPreflightSnapshot $fixture).status -eq "FAIL") "missing $store must fail" }
$mutations = @(
    { param($x) $x.stores.rds[0].status = "failed" }, { param($x) $x.stores.rds[0].multiAz = $false }, { param($x) $x.stores.rds[0].storageEncrypted = $false }, { param($x) $x.stores.rds[0].deletionProtection = $false }, { param($x) $x.stores.rds[0].backupRetentionDays = 6 },
    { param($x) $x.stores.valkey[0].status = "creating" }, { param($x) $x.stores.valkey[0].multiAz = "disabled" }, { param($x) $x.stores.valkey[0].automaticFailover = "disabled" }, { param($x) $x.stores.valkey[0].transitEncryption = $false }, { param($x) $x.stores.valkey[0].atRestEncryption = $false },
    { param($x) $x.stores.dynamoDb[0].status = "UPDATING" }, { param($x) $x.stores.dynamoDb[0].deletionProtection = $false }, { param($x) $x.stores.dynamoDb[0].sseType = "AES256" }, { param($x) $x.stores.dynamoDb[0].pitrStatus = "DISABLED" },
    { param($x) $x.stores.msk[0].status = "CREATING" }, { param($x) $x.stores.msk[0].brokerCount = 1 }, { param($x) $x.stores.msk[0].clientBrokerEncryption = "TLS_PLAINTEXT" }
)
$index = 0
foreach ($mutation in $mutations) { $index++; $fixture = New-InfraFixture; & $mutation $fixture; Assert-True ((Test-InfraPreflightSnapshot $fixture).status -eq "FAIL") "store invariant mutation $index must fail" }

Assert-True ((Test-CapacityProbeSnapshot (New-CapacityFixture)).status -eq "PASS") "valid capacity fixture must pass"
$noNew = New-CapacityFixture; $noNew.observedNodeClaims = @($noNew.baselineNodeClaims)
Assert-True ((Test-CapacityProbeSnapshot $noNew).status -eq "FAIL") "existing NodeClaim must not count as new"
$wrongZone = New-CapacityFixture; $wrongZone.observedNodeClaims[1].availabilityZone = "us-east-1a"
Assert-True ((Test-CapacityProbeSnapshot $wrongZone).status -eq "FAIL") "new wrong-zone NodeClaim must fail"
$insufficient = New-CapacityFixture; $insufficient.samples[5].readyCpuMilli = 1000
Assert-True ((Test-CapacityProbeSnapshot $insufficient).status -eq "FAIL") "insufficient Ready load must fail"
$unlinked = New-CapacityFixture; $unlinked.samples | ForEach-Object { $_.readyNodeNames = @("unrelated-node") }
Assert-True ((Test-CapacityProbeSnapshot $unlinked).status -eq "FAIL") "probe pods not linked to the new NodeClaim must fail"
$truncated = New-CapacityFixture; $truncated.samples = @($truncated.samples | Select-Object -First 10)
Assert-True ((Test-CapacityProbeSnapshot $truncated).status -eq "FAIL") "truncated soak must fail"
Write-Host "Mandate 21 capacity/preflight fixture checks passed."

# Change trail: @hungxqt - 2026-07-29 - Added fail-closed fixtures for network, stores, NodeClaims, Ready load, and soak duration.