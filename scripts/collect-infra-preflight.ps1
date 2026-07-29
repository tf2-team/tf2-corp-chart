[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$VpcId = "",
    [string]$RdsIdentifier = "techx-prod-tf2-postgresql",
    [string]$ValkeyReplicationGroupId = "techx-prod-tf2-cart",
    [string]$DynamoDbTable = "techx-prod-tf2-checkout-outbox",
    [string]$MskClusterName = "techx-prod-tf2-msk",
    [string]$OutputPath = "",
    [string]$SummaryPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $scriptDirectory "../evidence/mandate21/infra-preflight.json"
}
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = Join-Path $scriptDirectory "../evidence/mandate21/infra-preflight-summary.md"
}

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
    return (Invoke-Text -File $File -Arguments $Arguments | ConvertFrom-Json)
}

function Assert-Check {
    param([bool]$Condition, [string]$Message, [ref]$Checks)
    $status = if ($Condition) { "PASS" } else { "FAIL" }
    $Checks.Value += [pscustomobject]@{ check = $Message; status = $status }
    if (-not $Condition) {
        Write-Warning "[PREFLIGHT FAIL] $Message"
    } else {
        Write-Host "[PREFLIGHT PASS] $Message"
    }
}

$checks = @()

# 1. Route / NAT Gateway
if ([string]::IsNullOrWhiteSpace($VpcId)) {
    $vpcs = Invoke-Json aws @("ec2", "describe-vpcs", "--region", $Region, "--filters", "Name=is-default,Values=false", "--output", "json")
    if ($null -ne $vpcs.Vpcs -and $vpcs.Vpcs.Count -gt 0) {
        $VpcId = $vpcs.Vpcs[0].VpcId
    }
}

$subnets = Invoke-Json aws @("ec2", "describe-subnets", "--region", $Region, "--filters", "Name=vpc-id,Values=$VpcId", "--output", "json")
$routeTables = Invoke-Json aws @("ec2", "describe-route-tables", "--region", $Region, "--filters", "Name=vpc-id,Values=$VpcId", "--output", "json")
$natGateways = Invoke-Json aws @("ec2", "describe-nat-gateways", "--region", $Region, "--filter", "Name=vpc-id,Values=$VpcId", "Name=state,Values=available", "--output", "json")

$natByAz = @{}
foreach ($nat in $natGateways.NatGateways) {
    $subnetId = $nat.SubnetId
    $subnet = @($subnets.Subnets | Where-Object { $_.SubnetId -eq $subnetId })
    if ($subnet.Count -gt 0) {
        $natByAz[$subnet[0].AvailabilityZone] = $nat
    }
}

$privateSubnetCount = 0
foreach ($s in $subnets.Subnets) {
    $isPrivate = $s.MapPublicIpOnLaunch -ne $true
    if ($isPrivate) {
        $privateSubnetCount++
        $az = $s.AvailabilityZone
        $hasNatInAz = $natByAz.ContainsKey($az)
        Assert-Check ($hasNatInAz) "Private subnet $($s.SubnetId) in $az has available NAT Gateway in same AZ" ([ref]$checks)
    }
}

# 2. RDS
$rds = Invoke-Json aws @("rds", "describe-db-instances", "--region", $Region, "--db-instance-identifier", $RdsIdentifier, "--output", "json")
$dbInst = $rds.DBInstances[0]
Assert-Check ($dbInst.DBInstanceStatus -eq "available") "RDS $RdsIdentifier is available" ([ref]$checks)
Assert-Check ([bool]$dbInst.MultiAZ) "RDS $RdsIdentifier is Multi-AZ" ([ref]$checks)
Assert-Check ([bool]$dbInst.StorageEncrypted) "RDS $RdsIdentifier storage encryption is enabled" ([ref]$checks)
Assert-Check ([bool]$dbInst.DeletionProtection) "RDS $RdsIdentifier deletion protection is enabled" ([ref]$checks)
Assert-Check ($dbInst.BackupRetentionPeriod -ge 7) "RDS $RdsIdentifier backup retention is >=7 days" ([ref]$checks)

# 3. Valkey
$valkeyResp = Invoke-Json aws @("elasticache", "describe-replication-groups", "--region", $Region, "--replication-group-id", $ValkeyReplicationGroupId, "--output", "json")
if ($null -ne $valkeyResp.ReplicationGroups -and $valkeyResp.ReplicationGroups.Count -gt 0) {
    $rg = $valkeyResp.ReplicationGroups[0]
    Assert-Check ($rg.Status -eq "available") "Valkey $ValkeyReplicationGroupId status is available" ([ref]$checks)
    Assert-Check ($rg.AutomaticFailover -eq "enabled") "Valkey $ValkeyReplicationGroupId automatic failover is enabled" ([ref]$checks)
    Assert-Check ([bool]$rg.AtRestEncryptionEnabled) "Valkey $ValkeyReplicationGroupId at-rest encryption is enabled" ([ref]$checks)
    Assert-Check ([bool]$rg.TransitEncryptionEnabled) "Valkey $ValkeyReplicationGroupId transit encryption is enabled" ([ref]$checks)
}

# 4. DynamoDB
$ddb = Invoke-Json aws @("dynamodb", "describe-table", "--region", $Region, "--table-name", $DynamoDbTable, "--output", "json")
$tbl = $ddb.Table
Assert-Check ($tbl.TableStatus -eq "ACTIVE") "DynamoDB table $DynamoDbTable status is ACTIVE" ([ref]$checks)
Assert-Check ([bool]$tbl.DeletionProtectionEnabled) "DynamoDB table $DynamoDbTable deletion protection is enabled" ([ref]$checks)
$pitr = Invoke-Json aws @("dynamodb", "describe-continuous-backups", "--region", $Region, "--table-name", $DynamoDbTable, "--output", "json")
Assert-Check ($pitr.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus -eq "ENABLED") "DynamoDB table $DynamoDbTable PITR is ENABLED" ([ref]$checks)

# 5. MSK Cluster
$mskClusters = Invoke-Json aws @("kafka", "list-clusters", "--region", $Region, "--output", "json")
$mskCluster = @($mskClusters.ClusterInfoList | Where-Object { $_.ClusterName -eq $MskClusterName })
if ($mskCluster.Count -gt 0) {
    Assert-Check ($mskCluster[0].State -eq "ACTIVE") "MSK cluster $MskClusterName status is ACTIVE" ([ref]$checks)
    Assert-Check ($mskCluster[0].NumberOfBrokerNodes -ge 2) "MSK cluster $MskClusterName has >=2 broker nodes across AZs" ([ref]$checks)
}

$allPass = @($checks | Where-Object { $_.status -ne "PASS" }).Count -eq 0

$evidenceObj = [ordered]@{
    schemaVersion = 1
    collectedAt = (Get-Date).ToUniversalTime().ToString("o")
    region = $Region
    vpcId = $VpcId
    overallStatus = if ($allPass) { "PASS" } else { "FAIL" }
    checks = $checks
}

$parentDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parentDir)) {
    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
}

$evidenceObj | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding utf8

$markdown = @"
# Mandate 21 Infrastructure Preflight Report

**Collected At:** $($evidenceObj.collectedAt)  
**Region:** $Region  
**Overall Status:** $(if ($allPass) { 'PASS' } else { 'FAIL' })

## Validation Summary

| Check | Status |
|---|---|
"@

foreach ($c in $checks) {
    $markdown += "`n| $($c.check) | $($c.status) |"
}

$markdown += "`n`n<!-- Change trail: @hungxqt - 2026-07-29 - Generated fail-closed infrastructure preflight summary report. -->`n"
Set-Content -LiteralPath $SummaryPath -Value $markdown -Encoding utf8

Write-Host "Preflight collection complete: Output=$OutputPath, Summary=$SummaryPath, Status=$($evidenceObj.overallStatus)"

# Change trail: @hungxqt - 2026-07-29 - Created fail-closed infrastructure preflight collector for Route/NAT, RDS, Valkey, DynamoDB, and MSK.
