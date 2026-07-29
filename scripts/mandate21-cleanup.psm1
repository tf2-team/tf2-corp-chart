# Mandate 21 FIS Cleanup State Pure Evaluation Module
# Pure evaluation functions for FIS native cleanup verification.
# Contains zero mutating commands against AWS, Kubernetes, or Helm.

Set-StrictMode -Version Latest

function New-FisCleanupState {
    param(
        [Parameter(Mandatory)][string]$FaultId,
        [Parameter(Mandatory)][string]$ExperimentId,
        [Parameter(Mandatory)][string]$TemplateId,
        [Parameter(Mandatory)][string]$Variant,
        [string]$ActionsMode = "run-all",
        [string]$FisTerminalState = "PENDING",
        [string]$DeadlineAt = ""
    )

    $initialStatus = if ($ActionsMode -eq "skip-all") { "NOT_APPLICABLE" } else { "PENDING" }
    
    return [pscustomobject]@{
        schemaVersion              = 1
        faultId                    = $FaultId
        experimentId               = $ExperimentId
        templateId                 = $TemplateId
        variant                    = $Variant
        actionsMode                = $ActionsMode
        fisTerminalState           = $FisTerminalState
        status                     = $initialStatus
        capturedAt                 = (Get-Date).ToUniversalTime().ToString("o")
        deadlineAt                 = $DeadlineAt
        checks                     = [pscustomobject]@{
            fisPostActions           = [pscustomobject]@{ status = $initialStatus; reason = "Pending evaluation" }
            networkAclRestored       = [pscustomobject]@{ status = $initialStatus; reason = "Pending evaluation" }
            ec2Recovered             = [pscustomobject]@{ status = $initialStatus; reason = "Pending evaluation" }
            rdsHealthy               = [pscustomobject]@{ status = $initialStatus; reason = "Pending evaluation" }
            valkeyHealthy            = [pscustomobject]@{ status = $initialStatus; reason = "Pending evaluation" }
            stopAlarmsStable         = [pscustomobject]@{ status = $initialStatus; reason = "Pending evaluation" }
            kubernetesRecovered      = [pscustomobject]@{ status = $initialStatus; reason = "Pending evaluation" }
            durabilityReconciliation = [pscustomobject]@{ status = $initialStatus; reason = "Pending evaluation" }
        }
        manualInterventionRequired = $false
    }
}

function Save-FisCleanupState {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$FilePath
    )

    $parentDir = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $tmpPath = "$FilePath.tmp"
    $jsonContent = $State | ConvertTo-Json -Depth 100
    Set-Content -LiteralPath $tmpPath -Value $jsonContent -Encoding utf8
    Move-Item -LiteralPath $tmpPath -Destination $FilePath -Force
}

function Test-FisPostActions {
    param(
        [object]$ExperimentData
    )

    if ($null -eq $ExperimentData -or $null -eq $ExperimentData.experiment) {
        return [pscustomobject]@{ status = "FAIL"; reason = "Missing or null experiment response data" }
    }

    $expState = [string]$ExperimentData.experiment.state.status
    $terminalStates = @("completed", "stopped", "failed")
    if ($terminalStates -notcontains $expState.ToLower()) {
        return [pscustomobject]@{ status = "VERIFYING"; reason = "Experiment state is '$expState', awaiting terminal state" }
    }

    $actions = $ExperimentData.experiment.actions
    if ($null -ne $actions) {
        foreach ($prop in $actions.PSObject.Properties) {
            $actionObj = $prop.Value
            if ($null -ne $actionObj -and $null -ne $actionObj.state) {
                $actState = [string]$actionObj.state.status
                if (@("completed", "stopped", "failed", "cancelled") -notcontains $actState.ToLower()) {
                    return [pscustomobject]@{ status = "FAIL"; reason = "Action '$($prop.Name)' state is '$actState' while experiment is terminal" }
                }
            }
        }
    }

    return [pscustomobject]@{ status = "PASS"; reason = "Experiment state is '$expState' and all actions are terminal" }
}

function Test-NetworkAclRestored {
    param(
        [object[]]$TargetSubnets,
        [hashtable]$OriginalNaclMap,
        [object[]]$CurrentNaclAssociations,
        [object[]]$CurrentNacls
    )

    if ($null -eq $TargetSubnets -or $TargetSubnets.Count -eq 0) {
        return [pscustomobject]@{ status = "PASS"; reason = "No target subnets specified for NACL verification" }
    }

    if ($null -eq $OriginalNaclMap -or $OriginalNaclMap.Count -eq 0) {
        return [pscustomobject]@{ status = "FAIL"; reason = "Original NACL mapping not provided" }
    }

    foreach ($subnetId in $TargetSubnets) {
        $expectedNacl = [string]$OriginalNaclMap[$subnetId]
        if ([string]::IsNullOrWhiteSpace($expectedNacl)) {
            return [pscustomobject]@{ status = "FAIL"; reason = "Missing baseline NACL for subnet $subnetId" }
        }

        $assoc = @($CurrentNaclAssociations | Where-Object { $_.SubnetId -eq $subnetId })
        if ($assoc.Count -eq 0) {
            return [pscustomobject]@{ status = "FAIL"; reason = "No NACL association found for subnet $subnetId" }
        }

        $currentNacl = [string]$assoc[0].NetworkAclId
        if ($currentNacl -ne $expectedNacl) {
            return [pscustomobject]@{ status = "FAIL"; reason = "Subnet $subnetId associated with NACL '$currentNacl' instead of original '$expectedNacl'" }
        }
    }

    if ($null -ne $CurrentNacls) {
        foreach ($nacl in $CurrentNacls) {
            $tags = $nacl.Tags
            $isManagedByFis = $false
            if ($null -ne $tags) {
                foreach ($t in $tags) {
                    if ($t.Key -eq "managedByFIS" -and ([string]$t.Value).ToLower() -eq "true") {
                        $isManagedByFis = $true
                        break
                    }
                }
            }
            if ($isManagedByFis) {
                $assocList = @($nacl.Associations)
                if ($assocList.Count -gt 0) {
                    return [pscustomobject]@{ status = "FAIL"; reason = "Residual FIS-managed NACL '$($nacl.NetworkAclId)' is still associated with subnets" }
                }
            }
        }
    }

    return [pscustomobject]@{ status = "PASS"; reason = "All target subnets restored to original NACLs; no residual FIS NACL associated" }
}

function Test-Ec2Recovered {
    param(
        [object[]]$TargetInstances,
        [bool]$KubernetesHealthy = $true
    )

    if ($null -eq $TargetInstances -or $TargetInstances.Count -eq 0) {
        return [pscustomobject]@{ status = "PASS"; reason = "No EC2 target instances were resolved for experiment" }
    }

    $stopped = @($TargetInstances | Where-Object { [string]$_.State -in @("stopped", "stopping") })
    if ($stopped.Count -gt 0) {
        $ids = ($stopped | ForEach-Object { $_.InstanceId }) -join ", "
        return [pscustomobject]@{ status = "FAIL"; reason = "EC2 target instance(s) remain stopped/stopping: $ids" }
    }

    $terminated = @($TargetInstances | Where-Object { [string]$_.State -in @("terminated", "shutting-down") })
    if ($terminated.Count -gt 0) {
        if (-not $KubernetesHealthy) {
            $ids = ($terminated | ForEach-Object { $_.InstanceId }) -join ", "
            return [pscustomobject]@{ status = "FAIL"; reason = "EC2 target instance(s) terminated ($ids) but Kubernetes capacity is unhealthy" }
        }
    }

    return [pscustomobject]@{ status = "PASS"; reason = "All target EC2 instances are running or healthily replaced with healthy K8s capacity" }
}

function Test-RdsHealthy {
    param(
        [object]$RdsInstance,
        [string]$FaultZone,
        [bool]$RdsFailoverExpected
    )

    if ($null -eq $RdsInstance) {
        return [pscustomobject]@{ status = "FAIL"; reason = "RDS instance state data missing" }
    }

    $status = [string]$RdsInstance.DBInstanceStatus
    if ($status.ToLower() -ne "available") {
        return [pscustomobject]@{ status = "FAIL"; reason = "RDS instance status is '$status', expected 'available'" }
    }

    if (-not [bool]$RdsInstance.MultiAZ) {
        return [pscustomobject]@{ status = "FAIL"; reason = "RDS Multi-AZ is disabled" }
    }

    $currentPrimaryZone = [string]$RdsInstance.AvailabilityZone
    if ($RdsFailoverExpected) {
        if ($currentPrimaryZone -eq $FaultZone) {
            return [pscustomobject]@{ status = "FAIL"; reason = "RDS primary AZ is '$currentPrimaryZone', which is still in fault AZ '$FaultZone' after expected failover" }
        }
    }

    return [pscustomobject]@{ status = "PASS"; reason = "RDS is available, Multi-AZ, and primary AZ '$currentPrimaryZone' satisfies failover expectation" }
}

function Test-ValkeyHealthy {
    param(
        [object]$ValkeyGroup,
        [string]$FaultZone
    )

    if ($null -eq $ValkeyGroup) {
        return [pscustomobject]@{ status = "FAIL"; reason = "Valkey replication group data missing" }
    }

    $status = [string]$ValkeyGroup.Status
    if ($status.ToLower() -ne "available") {
        return [pscustomobject]@{ status = "FAIL"; reason = "Valkey replication group status is '$status', expected 'available'" }
    }

    $autoFailover = [string]$ValkeyGroup.AutomaticFailover
    if ($autoFailover.ToLower() -notmatch "enabled|enabling") {
        return [pscustomobject]@{ status = "FAIL"; reason = "Valkey automatic failover is '$autoFailover', expected enabled" }
    }

    if ($null -ne $ValkeyGroup.PrimaryZone -and [string]$ValkeyGroup.PrimaryZone -eq $FaultZone) {
        return [pscustomobject]@{ status = "FAIL"; reason = "Valkey primary node AZ is '$($ValkeyGroup.PrimaryZone)', which is still in fault AZ '$FaultZone'" }
    }

    return [pscustomobject]@{ status = "PASS"; reason = "Valkey replication group is available, automatic failover enabled, primary outside fault AZ" }
}

function Test-StopAlarmsStable {
    param(
        [object[]]$Alarms,
        [int]$RequiredAlarmWindows = 2,
        [DateTime]$EvaluationTime = (Get-Date).ToUniversalTime()
    )

    if ($null -eq $Alarms -or $Alarms.Count -lt 4) {
        return [pscustomobject]@{ status = "FAIL"; reason = "Fewer than four stop alarms provided for evaluation" }
    }

    foreach ($alarm in $Alarms) {
        $name = [string]$alarm.AlarmName
        $state = [string]$alarm.StateValue
        if ($state -ne "OK") {
            return [pscustomobject]@{ status = "FAIL"; reason = "Stop alarm '$name' is in state '$state', expected OK" }
        }

        $period = if ($alarm.PSObject.Properties["Period"] -and $null -ne $alarm.Period -and [int]$alarm.Period -gt 0) {
            [int]$alarm.Period
        } else {
            60
        }
        $evalPeriods = if ($alarm.PSObject.Properties["EvaluationPeriods"] -and $null -ne $alarm.EvaluationPeriods -and [int]$alarm.EvaluationPeriods -gt 0) {
            [int]$alarm.EvaluationPeriods
        } else {
            1
        }
        $windowSeconds = $period * $evalPeriods
        $requiredSeconds = $RequiredAlarmWindows * $windowSeconds

        if ($alarm.PSObject.Properties["StateUpdatedTimestamp"] -and $null -ne $alarm.StateUpdatedTimestamp) {
            $updatedAt = [DateTime]$alarm.StateUpdatedTimestamp
            $elapsedSeconds = ($EvaluationTime - $updatedAt.ToUniversalTime()).TotalSeconds
            if ($elapsedSeconds -lt $requiredSeconds) {
                return [pscustomobject]@{ status = "FAIL"; reason = "Stop alarm '$name' has been OK for [math]::Round($elapsedSeconds) seconds, which is less than required $requiredSeconds seconds ($RequiredAlarmWindows windows)" }
            }
        }
    }

    return [pscustomobject]@{ status = "PASS"; reason = "All stop alarms are OK and have been stable for at least $RequiredAlarmWindows evaluation windows" }
}

function Test-KubernetesRecovered {
    param(
        [object[]]$PendingPods,
        [object[]]$CordonedNodes,
        [object[]]$UnhealthyDeployments,
        [object[]]$UnhealthyArgoApps
    )

    if ($null -ne $PendingPods -and $PendingPods.Count -gt 0) {
        return [pscustomobject]@{ status = "FAIL"; reason = "Cluster has $($PendingPods.Count) Pending pod(s)" }
    }

    if ($null -ne $CordonedNodes -and $CordonedNodes.Count -gt 0) {
        return [pscustomobject]@{ status = "FAIL"; reason = "Cluster has $($CordonedNodes.Count) cordoned node(s)" }
    }

    if ($null -ne $UnhealthyDeployments -and $UnhealthyDeployments.Count -gt 0) {
        return [pscustomobject]@{ status = "FAIL"; reason = "$($UnhealthyDeployments.Count) application Deployment(s) are not fully Available" }
    }

    if ($null -ne $UnhealthyArgoApps -and $UnhealthyArgoApps.Count -gt 0) {
        return [pscustomobject]@{ status = "FAIL"; reason = "$($UnhealthyArgoApps.Count) Argo CD application(s) drift or are unhealthy" }
    }

    return [pscustomobject]@{ status = "PASS"; reason = "Kubernetes cluster fully recovered: zero Pending pods, zero cordoned nodes, Deployments Available, Argo CD Synced/Healthy" }
}

function Evaluate-FisCleanup {
    param(
        [Parameter(Mandatory)][object]$CleanupState,
        [object]$ExperimentData,
        [object[]]$TargetSubnets,
        [hashtable]$OriginalNaclMap,
        [object[]]$CurrentNaclAssociations,
        [object[]]$CurrentNacls,
        [object[]]$TargetInstances,
        [object]$RdsInstance,
        [string]$FaultZone,
        [bool]$RdsFailoverExpected,
        [object]$ValkeyGroup,
        [object[]]$Alarms,
        [int]$RequiredAlarmWindows = 2,
        [object[]]$PendingPods,
        [object[]]$CordonedNodes,
        [object[]]$UnhealthyDeployments,
        [object[]]$UnhealthyArgoApps,
        [Nullable[int]]$ReconciliationExitCode = $null,
        [bool]$QueryFailed = $false,
        [string]$QueryFailureReason = "",
        [DateTime]$EvaluationTime = (Get-Date).ToUniversalTime()
    )

    $CleanupState.capturedAt = $EvaluationTime.ToString("o")

    if ($CleanupState.actionsMode -eq "skip-all") {
        $CleanupState.status = "NOT_APPLICABLE"
        $CleanupState.fisTerminalState = "completed"
        foreach ($prop in $CleanupState.checks.PSObject.Properties) {
            $prop.Value = [pscustomobject]@{ status = "NOT_APPLICABLE"; reason = "Actions mode skip-all injects no fault and does not execute post-actions" }
        }
        $CleanupState.manualInterventionRequired = $false
        return $CleanupState
    }

    if ($QueryFailed) {
        $CleanupState.status = "FAIL"
        $CleanupState.checks.fisPostActions = [pscustomobject]@{ status = "FAIL"; reason = "Read query failure: $QueryFailureReason" }
        return $CleanupState
    }

    $k8sCheck = Test-KubernetesRecovered -PendingPods $PendingPods -CordonedNodes $CordonedNodes -UnhealthyDeployments $UnhealthyDeployments -UnhealthyArgoApps $UnhealthyArgoApps
    $CleanupState.checks.kubernetesRecovered = $k8sCheck
    $k8sHealthy = $k8sCheck.status -eq "PASS"

    $fisCheck = Test-FisPostActions -ExperimentData $ExperimentData
    $CleanupState.checks.fisPostActions = $fisCheck

    if ($null -ne $ExperimentData -and $null -ne $ExperimentData.experiment -and $null -ne $ExperimentData.experiment.state) {
        $CleanupState.fisTerminalState = [string]$ExperimentData.experiment.state.status
    }

    $CleanupState.checks.networkAclRestored = Test-NetworkAclRestored -TargetSubnets $TargetSubnets -OriginalNaclMap $OriginalNaclMap -CurrentNaclAssociations $CurrentNaclAssociations -CurrentNacls $CurrentNacls
    $CleanupState.checks.ec2Recovered = Test-Ec2Recovered -TargetInstances $TargetInstances -KubernetesHealthy $k8sHealthy
    $CleanupState.checks.rdsHealthy = Test-RdsHealthy -RdsInstance $RdsInstance -FaultZone $FaultZone -RdsFailoverExpected $RdsFailoverExpected
    $CleanupState.checks.valkeyHealthy = Test-ValkeyHealthy -ValkeyGroup $ValkeyGroup -FaultZone $FaultZone
    $CleanupState.checks.stopAlarmsStable = Test-StopAlarmsStable -Alarms $Alarms -RequiredAlarmWindows $RequiredAlarmWindows -EvaluationTime $EvaluationTime

    if ($null -eq $ReconciliationExitCode) {
        $CleanupState.checks.durabilityReconciliation = [pscustomobject]@{ status = "PENDING"; reason = "Durability reconciliation not yet executed" }
    } elseif ($ReconciliationExitCode -eq 0) {
        $CleanupState.checks.durabilityReconciliation = [pscustomobject]@{ status = "PASS"; reason = "Person 2 durability reconciliation passed with exit code 0" }
    } else {
        $CleanupState.checks.durabilityReconciliation = [pscustomobject]@{ status = "FAIL"; reason = "Person 2 durability reconciliation failed with exit code $ReconciliationExitCode" }
    }

    $allPass = $true
    $hasFail = $false
    $hasVerifying = $false

    foreach ($prop in $CleanupState.checks.PSObject.Properties) {
        $chkStatus = [string]$prop.Value.status
        if ($chkStatus -eq "FAIL") { $hasFail = $true; $allPass = $false }
        elseif ($chkStatus -in @("PENDING", "VERIFYING")) { $hasVerifying = $true; $allPass = $false }
    }

    if ($hasFail) {
        $CleanupState.status = "FAIL"
    } elseif ($allPass) {
        $CleanupState.status = "PASS"
    } else {
        $CleanupState.status = "VERIFYING"
    }

    if (-not [string]::IsNullOrWhiteSpace($CleanupState.deadlineAt)) {
        $deadline = [DateTime]::Parse($CleanupState.deadlineAt).ToUniversalTime()
        if ($EvaluationTime -gt $deadline -and $CleanupState.status -ne "PASS") {
            $CleanupState.status = "FAIL"
            if ($null -ne $ExperimentData -and $null -ne $ExperimentData.experiment -and $null -ne $ExperimentData.experiment.state) {
                $st = [string]$ExperimentData.experiment.state.status
                if ($st.ToLower() -notmatch "completed|stopped|failed") {
                    $CleanupState.manualInterventionRequired = $true
                }
            }
        }
    }

    return $CleanupState
}

Export-ModuleMember -Function New-FisCleanupState, Save-FisCleanupState, Test-FisPostActions, Test-NetworkAclRestored, Test-Ec2Recovered, Test-RdsHealthy, Test-ValkeyHealthy, Test-StopAlarmsStable, Test-KubernetesRecovered, Evaluate-FisCleanup

# Change trail: @hungxqt - 2026-07-29 - Added pure evaluation functions for deterministic FIS cleanup verification.
