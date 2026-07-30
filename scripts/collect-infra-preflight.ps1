[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$ClusterName = "techx-tf2-prod",
    [Parameter(Mandatory)][ValidatePattern("^[0-9A-Za-z._/-]{7,128}$")][string]$Revision,
    [string]$RdsIdentifier = "techx-prod-tf2-postgresql",
    [string]$ValkeyReplicationGroupId = "techx-prod-tf2-cart",
    [string]$DynamoDbTable = "techx-prod-tf2-checkout-outbox",
    [string]$MskClusterName = "techx-prod-tf2-msk",
    [string]$OutputPath = (Join-Path $PSScriptRoot "../evidence/mandate21/infra-preflight.json"),
    [string]$SummaryPath = (Join-Path $PSScriptRoot "../evidence/mandate21/infra-preflight-summary.md")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "mandate21-evidence.psm1") -Force

function Invoke-Json {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "AWS read failed: $($Arguments[0..1] -join ' ')" }
    try { return (($output -join "`n") | ConvertFrom-Json -Depth 100) }
    catch { throw "AWS returned invalid JSON for $($Arguments[0..1] -join ' ')" }
}

function Require-One {
    param([object[]]$Items, [string]$Name)
    $bounded = @($Items)
    if ($bounded.Count -ne 1) { throw "$Name must resolve exactly once; found $($bounded.Count)." }
    return $bounded[0]
}

$startedAt = (Get-Date).ToUniversalTime()
$identity = Invoke-Json @("sts", "get-caller-identity", "--output", "json")
if ([string]::IsNullOrWhiteSpace([string]$identity.Account)) { throw "AWS account identity is missing." }
$clusterResponse = Invoke-Json @("eks", "describe-cluster", "--region", $Region, "--name", $ClusterName, "--output", "json")
$cluster = $clusterResponse.cluster
if ($null -eq $cluster -or $cluster.status -ne "ACTIVE") { throw "Configured EKS cluster is missing or not ACTIVE." }
$vpcId = [string]$cluster.resourcesVpcConfig.vpcId
$subnetIds = @($cluster.resourcesVpcConfig.subnetIds)
if ([string]::IsNullOrWhiteSpace($vpcId) -or $subnetIds.Count -eq 0) { throw "EKS VPC/subnet contract is incomplete." }
$subnetResponse = Invoke-Json (@("ec2", "describe-subnets", "--region", $Region, "--subnet-ids") + $subnetIds + @("--output", "json"))
if (@($subnetResponse.Subnets).Count -ne $subnetIds.Count) { throw "Not every EKS subnet resolved." }

$routeEvidence = @()
foreach ($subnet in @($subnetResponse.Subnets)) {
    if ($subnet.VpcId -ne $vpcId) { throw "EKS subnet VPC mismatch." }
    $explicit = Invoke-Json @("ec2", "describe-route-tables", "--region", $Region, "--filters", "Name=association.subnet-id,Values=$($subnet.SubnetId)", "--output", "json")
    $tables = @($explicit.RouteTables)
    if ($tables.Count -eq 0) {
        $main = Invoke-Json @("ec2", "describe-route-tables", "--region", $Region, "--filters", "Name=vpc-id,Values=$vpcId", "Name=association.main,Values=true", "--output", "json")
        $tables = @($main.RouteTables)
    }
    $table = Require-One $tables "Route table for subnet $($subnet.SubnetId)"
    # AWS route objects are heterogeneous: IPv6 and prefix-list routes do not
    # expose DestinationCidrBlock, while Internet Gateway routes may not expose
    # NatGatewayId. Inspect optional properties explicitly so StrictMode does
    # not abort the preflight before the IPv4 NAT route can be evaluated.
    $defaults = @($table.Routes | Where-Object {
        $destination = $_.PSObject.Properties["DestinationCidrBlock"]
        $natGateway = $_.PSObject.Properties["NatGatewayId"]
        $null -ne $destination -and
            [string]$destination.Value -eq "0.0.0.0/0" -and
            $null -ne $natGateway -and
            -not [string]::IsNullOrWhiteSpace([string]$natGateway.Value)
    })
    $nat = $null
    if ($defaults.Count -eq 1) {
        $natResponse = Invoke-Json @("ec2", "describe-nat-gateways", "--region", $Region, "--nat-gateway-ids", $defaults[0].NatGatewayId, "--output", "json")
        $nat = Require-One @($natResponse.NatGateways) "NAT gateway $($defaults[0].NatGatewayId)"
        $natSubnetResponse = Invoke-Json @("ec2", "describe-subnets", "--region", $Region, "--subnet-ids", $nat.SubnetId, "--output", "json")
        $natSubnet = Require-One @($natSubnetResponse.Subnets) "NAT subnet $($nat.SubnetId)"
    }
    $routeEvidence += [pscustomobject]@{
        id = $subnet.SubnetId
        availabilityZone = $subnet.AvailabilityZone
        routeTableId = $table.RouteTableId
        defaultRoutes = @($defaults | ForEach-Object { [pscustomobject]@{ natGatewayId = $_.NatGatewayId; state = $_.State } })
        natGateway = if ($null -eq $nat) { $null } else { [pscustomobject]@{ id = $nat.NatGatewayId; state = $nat.State; availabilityZone = $natSubnet.AvailabilityZone; subnetId = $nat.SubnetId } }
    }
}

$rdsResponse = Invoke-Json @("rds", "describe-db-instances", "--region", $Region, "--db-instance-identifier", $RdsIdentifier, "--output", "json")
$rds = @($rdsResponse.DBInstances | ForEach-Object { [pscustomobject]@{ id = $_.DBInstanceIdentifier; status = $_.DBInstanceStatus; multiAz = $_.MultiAZ; storageEncrypted = $_.StorageEncrypted; deletionProtection = $_.DeletionProtection; backupRetentionDays = $_.BackupRetentionPeriod } })
$valkeyResponse = Invoke-Json @("elasticache", "describe-replication-groups", "--region", $Region, "--replication-group-id", $ValkeyReplicationGroupId, "--output", "json")
$valkey = @($valkeyResponse.ReplicationGroups | ForEach-Object { [pscustomobject]@{ id = $_.ReplicationGroupId; status = $_.Status; multiAz = $_.MultiAZ; automaticFailover = $_.AutomaticFailover; transitEncryption = $_.TransitEncryptionEnabled; atRestEncryption = $_.AtRestEncryptionEnabled } })
$ddbResponse = Invoke-Json @("dynamodb", "describe-table", "--region", $Region, "--table-name", $DynamoDbTable, "--output", "json")
$pitrResponse = Invoke-Json @("dynamodb", "describe-continuous-backups", "--region", $Region, "--table-name", $DynamoDbTable, "--output", "json")
$dynamo = if ($null -eq $ddbResponse.Table) { @() } else { @([pscustomobject]@{ name = $ddbResponse.Table.TableName; status = $ddbResponse.Table.TableStatus; deletionProtection = $ddbResponse.Table.DeletionProtectionEnabled; sseStatus = $ddbResponse.Table.SSEDescription.Status; sseType = $ddbResponse.Table.SSEDescription.SSEType; kmsKeyArn = $ddbResponse.Table.SSEDescription.KMSMasterKeyArn; pitrStatus = $pitrResponse.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus }) }
$mskResponse = Invoke-Json @("kafka", "list-clusters-v2", "--region", $Region, "--cluster-name-filter", $MskClusterName, "--output", "json")
$msk = @($mskResponse.ClusterInfoList | Where-Object { $_.ClusterName -eq $MskClusterName } | ForEach-Object { [pscustomobject]@{ name = $_.ClusterName; arn = $_.ClusterArn; status = $_.State; brokerCount = $_.Provisioned.NumberOfBrokerNodes; clientBrokerEncryption = $_.Provisioned.EncryptionInfo.EncryptionInTransit.ClientBroker } })

$snapshot = [pscustomobject]@{
    cluster = [pscustomobject]@{ name = $cluster.name; arn = $cluster.arn; status = $cluster.status; vpcId = $vpcId; subnetIds = $subnetIds }
    subnets = $routeEvidence
    stores = [pscustomobject]@{ rds = $rds; valkey = $valkey; dynamoDb = $dynamo; msk = $msk }
}
$evaluation = Test-InfraPreflightSnapshot -Snapshot $snapshot
$evidence = [ordered]@{ schemaVersion = 2; startedAt = $startedAt.ToString("o"); completedAt = (Get-Date).ToUniversalTime().ToString("o"); accountId = [string]$identity.Account; region = $Region; cluster = [pscustomobject]@{ name = $cluster.name; arn = $cluster.arn; vpcId = $vpcId }; revision = $Revision; resourceIds = [pscustomobject]@{ rds = $RdsIdentifier; valkey = $ValkeyReplicationGroupId; dynamoDb = $DynamoDbTable; msk = $MskClusterName }; observedStores = $snapshot.stores; overallStatus = $evaluation.status; privateRouteEvidence = $evaluation.privateRouteEvidence; checks = $evaluation.checks }
foreach ($target in @($OutputPath, $SummaryPath)) { $parent = Split-Path -Parent $target; if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null } }
$evidence | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$lines = @("# Mandate 21 Infrastructure Preflight", "", "Account: $($evidence.accountId)", "Region: $Region", "Cluster: $ClusterName", "Revision: $Revision", "Status: $($evaluation.status)", "", "| Check | Status | Detail |", "|---|---|---|")
foreach ($check in $evaluation.checks) { $lines += "| $($check.check) | $($check.status) | $($check.detail) |" }
$lines += ""; $lines += "<!-- Change trail: @hungxqt - 2026-07-29 - Generated revision-bound fail-closed infrastructure preflight evidence. -->"
$lines | Set-Content -LiteralPath $SummaryPath -Encoding utf8
Write-Host "Preflight evidence: $OutputPath ($($evaluation.status))"
if ($evaluation.status -ne "PASS") { exit 1 }

# Change trail: @hungxqt - 2026-07-29 - Derive and validate fail-closed infrastructure evidence from the configured EKS cluster.
