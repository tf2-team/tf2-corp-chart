$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    Write-Host "[PASS] $Message"
}

Import-Module (Join-Path $repo "scripts/mandate21-cleanup.psm1") -Force

# --- Test Case 1: Completed experiment with all checks passing -> PASS ---
$state1 = New-FisCleanupState -FaultId "m21-test-1" -ExperimentId "exp-001" -TemplateId "EXT1" -Variant "1a-primary-in"
$exp1 = [pscustomobject]@{
    experiment = [pscustomobject]@{
        state = [pscustomobject]@{ status = "completed" }
        actions = [pscustomobject]@{
            StopEC2Instances = [pscustomobject]@{ state = [pscustomobject]@{ status = "completed" } }
            DisruptSubnetNetwork = [pscustomobject]@{ state = [pscustomobject]@{ status = "completed" } }
        }
    }
}
$subnets1 = @("subnet-1111")
$naclMap1 = @{ "subnet-1111" = "nacl-orig" }
$naclAssoc1 = @([pscustomobject]@{ SubnetId = "subnet-1111"; NetworkAclId = "nacl-orig" })
$nacls1 = @([pscustomobject]@{ NetworkAclId = "nacl-orig"; Associations = $naclAssoc1; Tags = @() })
$ec2_1 = @([pscustomobject]@{ InstanceId = "i-1111"; State = "running" })
$rds1 = [pscustomobject]@{ DBInstanceStatus = "available"; MultiAZ = $true; AvailabilityZone = "us-east-1b" }
$valkey1 = [pscustomobject]@{ Status = "available"; AutomaticFailover = "enabled"; PrimaryZone = "us-east-1b" }
$now1 = (Get-Date).ToUniversalTime()
$alarms1 = @(
    [pscustomobject]@{ AlarmName = "storefront-healthy-hosts"; StateValue = "OK"; Period = 60; EvaluationPeriods = 1; StateUpdatedTimestamp = $now1.AddMinutes(-10) },
    [pscustomobject]@{ AlarmName = "storefront-5xx-ratio"; StateValue = "OK"; Period = 60; EvaluationPeriods = 1; StateUpdatedTimestamp = $now1.AddMinutes(-10) },
    [pscustomobject]@{ AlarmName = "accepted-order-durability-gap"; StateValue = "OK"; Period = 60; EvaluationPeriods = 1; StateUpdatedTimestamp = $now1.AddMinutes(-10) },
    [pscustomobject]@{ AlarmName = "immutable-audit-control-health"; StateValue = "OK"; Period = 60; EvaluationPeriods = 1; StateUpdatedTimestamp = $now1.AddMinutes(-10) }
)

$res1 = Evaluate-FisCleanup -CleanupState $state1 -ExperimentData $exp1 -TargetSubnets $subnets1 -OriginalNaclMap $naclMap1 -CurrentNaclAssociations $naclAssoc1 -CurrentNacls $nacls1 -TargetInstances $ec2_1 -RdsInstance $rds1 -FaultZone "us-east-1a" -RdsFailoverExpected $true -ValkeyGroup $valkey1 -Alarms $alarms1 -RequiredAlarmWindows 2 -PendingPods @() -CordonedNodes @() -UnhealthyDeployments @() -UnhealthyArgoApps @() -ReconciliationExitCode 0
Assert-True ($res1.status -eq "PASS") "Test Case 1: Completed experiment with all checks passing produces PASS"

# --- Test Case 2: Stopped experiment with cleanup passing -> PASS ---
$state2 = New-FisCleanupState -FaultId "m21-test-2" -ExperimentId "exp-002" -TemplateId "EXT1" -Variant "1a-primary-in"
$exp2 = [pscustomobject]@{
    experiment = [pscustomobject]@{
        state = [pscustomobject]@{ status = "stopped" }
        actions = [pscustomobject]@{
            StopEC2Instances = [pscustomobject]@{ state = [pscustomobject]@{ status = "completed" } }
        }
    }
}
$res2 = Evaluate-FisCleanup -CleanupState $state2 -ExperimentData $exp2 -TargetSubnets $subnets1 -OriginalNaclMap $naclMap1 -CurrentNaclAssociations $naclAssoc1 -CurrentNacls $nacls1 -TargetInstances $ec2_1 -RdsInstance $rds1 -FaultZone "us-east-1a" -RdsFailoverExpected $true -ValkeyGroup $valkey1 -Alarms $alarms1 -RequiredAlarmWindows 2 -PendingPods @() -CordonedNodes @() -UnhealthyDeployments @() -UnhealthyArgoApps @() -ReconciliationExitCode 0
Assert-True ($res2.status -eq "PASS") "Test Case 2: Stopped experiment with clean resources produces PASS"

# --- Test Case 3: Residual FIS NACL -> FAIL ---
$state3 = New-FisCleanupState -FaultId "m21-test-3" -ExperimentId "exp-003" -TemplateId "EXT1" -Variant "1a-primary-in"
$fisNacl = [pscustomobject]@{
    NetworkAclId = "nacl-fis-temp"
    Associations = @([pscustomobject]@{ SubnetId = "subnet-1111" })
    Tags = @([pscustomobject]@{ Key = "managedByFIS"; Value = "true" })
}
$nacls3 = @($nacls1[0], $fisNacl)
$res3 = Evaluate-FisCleanup -CleanupState $state3 -ExperimentData $exp1 -TargetSubnets $subnets1 -OriginalNaclMap $naclMap1 -CurrentNaclAssociations $naclAssoc1 -CurrentNacls $nacls3 -TargetInstances $ec2_1 -RdsInstance $rds1 -FaultZone "us-east-1a" -RdsFailoverExpected $true -ValkeyGroup $valkey1 -Alarms $alarms1 -RequiredAlarmWindows 2 -PendingPods @() -CordonedNodes @() -UnhealthyDeployments @() -UnhealthyArgoApps @() -ReconciliationExitCode 0
Assert-True ($res3.status -eq "FAIL") "Test Case 3: Residual associated FIS NACL produces FAIL"
Assert-True ($res3.checks.networkAclRestored.status -eq "FAIL") "Test Case 3: networkAclRestored check fails"

# --- Test Case 4: EC2 target still stopped -> FAIL ---
$state4 = New-FisCleanupState -FaultId "m21-test-4" -ExperimentId "exp-004" -TemplateId "EXT1" -Variant "1a-primary-in"
$ec2_4 = @([pscustomobject]@{ InstanceId = "i-1111"; State = "stopped" })
$res4 = Evaluate-FisCleanup -CleanupState $state4 -ExperimentData $exp1 -TargetSubnets $subnets1 -OriginalNaclMap $naclMap1 -CurrentNaclAssociations $naclAssoc1 -CurrentNacls $nacls1 -TargetInstances $ec2_4 -RdsInstance $rds1 -FaultZone "us-east-1a" -RdsFailoverExpected $true -ValkeyGroup $valkey1 -Alarms $alarms1 -RequiredAlarmWindows 2 -PendingPods @() -CordonedNodes @() -UnhealthyDeployments @() -UnhealthyArgoApps @() -ReconciliationExitCode 0
Assert-True ($res4.status -eq "FAIL") "Test Case 4: Stopped EC2 target produces FAIL"
Assert-True ($res4.checks.ec2Recovered.status -eq "FAIL") "Test Case 4: ec2Recovered check fails"

# --- Test Case 5: Terminated EC2 target with healthy replacement -> PASS ---
$state5 = New-FisCleanupState -FaultId "m21-test-5" -ExperimentId "exp-005" -TemplateId "EXT1" -Variant "1a-primary-in"
$ec2_5 = @([pscustomobject]@{ InstanceId = "i-1111"; State = "terminated" })
$res5 = Evaluate-FisCleanup -CleanupState $state5 -ExperimentData $exp1 -TargetSubnets $subnets1 -OriginalNaclMap $naclMap1 -CurrentNaclAssociations $naclAssoc1 -CurrentNacls $nacls1 -TargetInstances $ec2_5 -RdsInstance $rds1 -FaultZone "us-east-1a" -RdsFailoverExpected $true -ValkeyGroup $valkey1 -Alarms $alarms1 -RequiredAlarmWindows 2 -PendingPods @() -CordonedNodes @() -UnhealthyDeployments @() -UnhealthyArgoApps @() -ReconciliationExitCode 0
Assert-True ($res5.status -eq "PASS") "Test Case 5: Terminated EC2 target with healthy K8s capacity produces PASS"

# --- Test Case 6: Incorrect RDS failover direction -> FAIL ---
$state6 = New-FisCleanupState -FaultId "m21-test-6" -ExperimentId "exp-006" -TemplateId "EXT1" -Variant "1a-primary-in"
$rds6 = [pscustomobject]@{ DBInstanceStatus = "available"; MultiAZ = $true; AvailabilityZone = "us-east-1a" } # Fault zone is us-east-1a!
$res6 = Evaluate-FisCleanup -CleanupState $state6 -ExperimentData $exp1 -TargetSubnets $subnets1 -OriginalNaclMap $naclMap1 -CurrentNaclAssociations $naclAssoc1 -CurrentNacls $nacls1 -TargetInstances $ec2_1 -RdsInstance $rds6 -FaultZone "us-east-1a" -RdsFailoverExpected $true -ValkeyGroup $valkey1 -Alarms $alarms1 -RequiredAlarmWindows 2 -PendingPods @() -CordonedNodes @() -UnhealthyDeployments @() -UnhealthyArgoApps @() -ReconciliationExitCode 0
Assert-True ($res6.status -eq "FAIL") "Test Case 6: Incorrect RDS failover direction produces FAIL"
Assert-True ($res6.checks.rdsHealthy.status -eq "FAIL") "Test Case 6: rdsHealthy check fails"

# --- Test Case 7: Valkey unavailable or primary still in fault AZ -> FAIL ---
$state7 = New-FisCleanupState -FaultId "m21-test-7" -ExperimentId "exp-007" -TemplateId "EXT1" -Variant "1a-primary-in"
$valkey7 = [pscustomobject]@{ Status = "rebooting"; AutomaticFailover = "enabled"; PrimaryZone = "us-east-1b" }
$res7 = Evaluate-FisCleanup -CleanupState $state7 -ExperimentData $exp1 -TargetSubnets $subnets1 -OriginalNaclMap $naclMap1 -CurrentNaclAssociations $naclAssoc1 -CurrentNacls $nacls1 -TargetInstances $ec2_1 -RdsInstance $rds1 -FaultZone "us-east-1a" -RdsFailoverExpected $true -ValkeyGroup $valkey7 -Alarms $alarms1 -RequiredAlarmWindows 2 -PendingPods @() -CordonedNodes @() -UnhealthyDeployments @() -UnhealthyArgoApps @() -ReconciliationExitCode 0
Assert-True ($res7.status -eq "FAIL") "Test Case 7: Valkey rebooting produces FAIL"
Assert-True ($res7.checks.valkeyHealthy.status -eq "FAIL") "Test Case 7: valkeyHealthy check fails"

# --- Test Case 8: Alarm OK for less than two windows -> FAIL ---
$state8 = New-FisCleanupState -FaultId "m21-test-8" -ExperimentId "exp-008" -TemplateId "EXT1" -Variant "1a-primary-in"
$alarms8 = @(
    [pscustomobject]@{ AlarmName = "storefront-healthy-hosts"; StateValue = "OK"; Period = 60; EvaluationPeriods = 1; StateUpdatedTimestamp = $now1.AddSeconds(-30) }, # only 30s ago!
    [pscustomobject]@{ AlarmName = "storefront-5xx-ratio"; StateValue = "OK"; Period = 60; EvaluationPeriods = 1; StateUpdatedTimestamp = $now1.AddMinutes(-10) },
    [pscustomobject]@{ AlarmName = "accepted-order-durability-gap"; StateValue = "OK"; Period = 60; EvaluationPeriods = 1; StateUpdatedTimestamp = $now1.AddMinutes(-10) },
    [pscustomobject]@{ AlarmName = "immutable-audit-control-health"; StateValue = "OK"; Period = 60; EvaluationPeriods = 1; StateUpdatedTimestamp = $now1.AddMinutes(-10) }
)
$res8 = Evaluate-FisCleanup -CleanupState $state8 -ExperimentData $exp1 -TargetSubnets $subnets1 -OriginalNaclMap $naclMap1 -CurrentNaclAssociations $naclAssoc1 -CurrentNacls $nacls1 -TargetInstances $ec2_1 -RdsInstance $rds1 -FaultZone "us-east-1a" -RdsFailoverExpected $true -ValkeyGroup $valkey1 -Alarms $alarms8 -RequiredAlarmWindows 2 -PendingPods @() -CordonedNodes @() -UnhealthyDeployments @() -UnhealthyArgoApps @() -ReconciliationExitCode 0 -EvaluationTime $now1
Assert-True ($res8.status -eq "FAIL") "Test Case 8: Alarm OK for less than 2 windows produces FAIL"
Assert-True ($res8.checks.stopAlarmsStable.status -eq "FAIL") "Test Case 8: stopAlarmsStable check fails"

# --- Test Case 9: AWS/kubectl read failure -> FAIL ---
$state9 = New-FisCleanupState -FaultId "m21-test-9" -ExperimentId "exp-009" -TemplateId "EXT1" -Variant "1a-primary-in"
$res9 = Evaluate-FisCleanup -CleanupState $state9 -QueryFailed $true -QueryFailureReason "AWS API rate limited"
Assert-True ($res9.status -eq "FAIL") "Test Case 9: Read query failure produces FAIL"
Assert-True ($res9.checks.fisPostActions.status -eq "FAIL") "Test Case 9: fisPostActions records failure reason"

# --- Test Case 10: skip-all producing NOT_APPLICABLE ---
$state10 = New-FisCleanupState -FaultId "m21-test-10" -ExperimentId "exp-010" -TemplateId "EXT1" -Variant "1a-primary-in" -ActionsMode "skip-all"
$res10 = Evaluate-FisCleanup -CleanupState $state10
Assert-True ($res10.status -eq "NOT_APPLICABLE") "Test Case 10: skip-all produces NOT_APPLICABLE"

# --- Test Case 11: Static proof that cleanup code contains no mutating AWS, kubectl or Helm command ---
$cleanupModuleCode = Get-Content -LiteralPath (Join-Path $repo "scripts/mandate21-cleanup.psm1") -Raw

$mutatingAwsPatterns = @('start-instances', 'stop-instances', 'terminate-instances', 'replace-network-acl-association', 'create-network-acl', 'delete-network-acl', 'reboot-db-instances', 'set-alarm-state')
foreach ($cmd in $mutatingAwsPatterns) {
    Assert-True ($cleanupModuleCode -notmatch "(?i)\b$cmd\b") "Cleanup module contains no mutating AWS command: $cmd"
}

$mutatingK8sPatterns = @('apply', 'create', 'delete', 'patch', 'edit', 'replace', 'scale', 'cordon', 'uncordon', 'drain', 'rollout')
foreach ($cmd in $mutatingK8sPatterns) {
    Assert-True ($cleanupModuleCode -notmatch "(?i)\bkubectl\b.*\b$cmd\b") "Cleanup module contains no mutating kubectl command: $cmd"
}

$mutatingHelmPatterns = @('install', 'upgrade', 'rollback', 'uninstall')
foreach ($cmd in $mutatingHelmPatterns) {
    Assert-True ($cleanupModuleCode -notmatch "(?i)\bhelm\b.*\b$cmd\b") "Cleanup module contains no mutating Helm command: $cmd"
}

Write-Host "All 11 FIS cleanup verification tests PASSED."

# Change trail: @hungxqt - 2026-07-29 - Created fixture-driven unit tests for FIS cleanup state evaluation.
