Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "mandate21-fis-contract.psm1") -Force
function Assert-ExactProperties($Object, [string[]]$Allowed, [string]$Name) { $actual = @($Object.PSObject.Properties.Name); $missing = @($Allowed | Where-Object { $actual -notcontains $_ }); $extra = @($actual | Where-Object { $Allowed -notcontains $_ }); if ($missing.Count -gt 0 -or $extra.Count -gt 0) { throw "$Name has missing or unknown fields." } }
function Read-BoundedJson([string]$Path, [int64]$MaxBytes = 10MB) { $item = Get-Item -LiteralPath $Path -ErrorAction Stop; if ($item.PSIsContainer -or $item.Length -gt $MaxBytes) { throw "Bounded JSON evidence is invalid." }; return (Get-Content -Raw -LiteralPath $item.FullName | ConvertFrom-Json -Depth 100) }
function Assert-EvidenceStatus($Evidence, [string]$ExpectedDirection = "") { $statusProperty=$Evidence.PSObject.Properties["status"]; $overallProperty=$Evidence.PSObject.Properties["overallStatus"]; $values=@(); if ($null -ne $statusProperty){$values+=[string]$statusProperty.Value}; if($null -ne $overallProperty){$values+=[string]$overallProperty.Value}; if($values.Count -eq 0 -or @($values | Where-Object { $_ -ne "PASS" }).Count -gt 0){throw "Evidence status is missing, conflicting, or not PASS."}; if ($ExpectedDirection -and $Evidence.direction -ne $ExpectedDirection) { throw "Capacity evidence direction mismatch." } }
function ConvertTo-Mandate21UtcDateTime($Value, [string]$Name) {
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw "$Name must include a timezone." }
        return $Value.ToUniversalTime()
    }
    try {
        return [datetimeoffset]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).UtcDateTime
    } catch {
        throw "$Name is not a valid timezone-qualified timestamp."
    }
}
function Test-Mandate21Approval {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Approval, [Parameter(Mandatory)][string]$ExpectedAccountId, [Parameter(Mandatory)][string]$ExpectedRegion, [Parameter(Mandatory)][string]$ExpectedClusterContext, [Parameter(Mandatory)][string]$ExpectedChartGitSha, [Parameter(Mandatory)][string]$ExpectedInfraGitSha, [Parameter(Mandatory)][string]$ExpectedContractSha256, [Parameter(Mandatory)][object[]]$LiveTemplates, [Parameter(Mandatory)][string]$InfraPreflightPath, [Parameter(Mandatory)][string]$Capacity1aTo1bPath, [Parameter(Mandatory)][string]$Capacity1bTo1aPath, [Parameter(Mandatory)][string]$AuditEvidencePath, [datetime]$Now = (Get-Date).ToUniversalTime())
    $top = @('schemaVersion','accountId','region','clusterContext','chartGitSha','infraGitSha','contractSha256','templates','evidence','CapacityApproved','ChangeApproved','approvedBy','changeReference','approvedAt','expiresAt')
    Assert-ExactProperties $Approval $top 'approval'
    if ($Approval.schemaVersion -ne 1 -or $Approval.CapacityApproved -cne 'PASS' -or $Approval.ChangeApproved -cne 'PASS') { throw 'Approval gates are invalid.' }
    if ($Approval.accountId -ne $ExpectedAccountId -or $Approval.region -ne $ExpectedRegion -or $Approval.clusterContext -ne $ExpectedClusterContext) { throw 'Approval AWS context mismatch.' }
    if ($Approval.chartGitSha -ne $ExpectedChartGitSha -or $Approval.infraGitSha -ne $ExpectedInfraGitSha -or $Approval.contractSha256 -ne $ExpectedContractSha256) { throw 'Approval revision binding mismatch.' }
    if ($Approval.chartGitSha -notmatch '^[0-9a-f]{40}$' -or $Approval.infraGitSha -notmatch '^[0-9a-f]{40}$' -or $Approval.contractSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Approval hashes are invalid.' }
    $approvedAt = ConvertTo-Mandate21UtcDateTime $Approval.approvedAt 'approvedAt'
    $expiresAt = ConvertTo-Mandate21UtcDateTime $Approval.expiresAt 'expiresAt'
    if ($approvedAt -gt $Now.AddMinutes(5) -or $Now -lt $approvedAt -or $Now -ge $expiresAt -or $expiresAt -le $approvedAt -or ($expiresAt - $approvedAt).TotalHours -gt 24) { throw 'Approval is stale, future-dated, expired, or exceeds 24 hours.' }
    if ([string]::IsNullOrWhiteSpace([string]$Approval.approvedBy) -or [string]::IsNullOrWhiteSpace([string]$Approval.changeReference)) { throw 'Approval identity or change reference is missing.' }
    if (@($Approval.templates).Count -ne 4 -or @($LiveTemplates).Count -ne 4) { throw 'Exactly four template revisions are required.' }
    $requiredVariants = @("1a-primary-in","1a-primary-outside","1b-primary-in","1b-primary-outside")
    if (@($Approval.templates.variant | Select-Object -Unique).Count -ne 4 -or @($requiredVariants | Where-Object { $Approval.templates.variant -notcontains $_ }).Count -gt 0) { throw "Approval must contain each canonical variant exactly once." }
    foreach ($approvedTemplate in @($Approval.templates)) { Assert-ExactProperties $approvedTemplate @('variant','templateId','revisionSha256','lastUpdateTime') 'template approval'; $live = @($LiveTemplates | Where-Object { $_.variant -eq $approvedTemplate.variant }); if ($live.Count -ne 1 -or $live[0].templateId -ne $approvedTemplate.templateId -or $live[0].revisionSha256 -ne $approvedTemplate.revisionSha256 -or [string]$live[0].lastUpdateTime -ne [string]$approvedTemplate.lastUpdateTime) { throw 'Approved template revision does not match live metadata.' } }
    Assert-ExactProperties $Approval.evidence @('infraPreflightSha256','capacity1aTo1bSha256','capacity1bTo1aSha256','auditAlarmSha256') 'evidence hashes'
        if ((Get-FileSha256 $InfraPreflightPath) -ne $Approval.evidence.infraPreflightSha256 -or (Get-FileSha256 $Capacity1aTo1bPath) -ne $Approval.evidence.capacity1aTo1bSha256 -or (Get-FileSha256 $Capacity1bTo1aPath) -ne $Approval.evidence.capacity1bTo1aSha256 -or (Get-FileSha256 $AuditEvidencePath) -ne $Approval.evidence.auditAlarmSha256) { throw 'Evidence hash mismatch.' }
    $infra = Read-BoundedJson $InfraPreflightPath; $capA = Read-BoundedJson $Capacity1aTo1bPath; $capB = Read-BoundedJson $Capacity1bTo1aPath; $audit = Read-BoundedJson $AuditEvidencePath
    Assert-EvidenceStatus $infra; Assert-EvidenceStatus $capA '1a-to-1b'; Assert-EvidenceStatus $capB '1b-to-1a'
    if ([string]$infra.accountId -ne $ExpectedAccountId -or [string]$infra.region -ne $ExpectedRegion -or [string]$infra.cluster.arn -ne $ExpectedClusterContext -or [string]$infra.revision -ne $ExpectedInfraGitSha) { throw 'Infrastructure evidence context or revision mismatch.' }
    foreach ($capacity in @($capA, $capB)) {
        $runId = [string]$capacity.runId; $evidenceId = [string]$capacity.evidenceId
        $sourceRevision = [string]$capacity.sourceRevision
        $deployedRevision = [string]$capacity.deployedRevision
        $argoRevision = [string]$capacity.argoRevision
        if ([int]$capacity.schemaVersion -ne 2 -or
            $runId -notmatch '^[0-9A-Za-z._-]{3,80}$' -or
            $evidenceId -cne "$runId-capacity" -or
            $sourceRevision -notmatch '^[0-9a-f]{40}$' -or
            $deployedRevision -notmatch '^[0-9a-f]{40}$' -or
            $argoRevision -cne $deployedRevision) {
            throw 'Capacity evidence identity or GitOps revision binding mismatch.'
        }
        # Each direction is enabled and cleaned up through a separate reviewed
        # GitOps revision, so their deployed SHAs are expected to differ. Bind
        # each result to the exact Argo revision that produced it, its immutable
        # file hash above, and a bounded evidence window instead of requiring
        # both sequential probes to claim the current application SHA.
        $capacityCompletedAt = ConvertTo-Mandate21UtcDateTime $capacity.completedAt 'capacity completedAt'
        if ($capacityCompletedAt -gt $approvedAt -or
            ($approvedAt - $capacityCompletedAt).TotalHours -gt 72) {
            throw 'Capacity evidence is future-dated or older than 72 hours at approval time.'
        }
    }
    if ([string]$capA.runId -eq [string]$capB.runId) { throw 'Capacity directions must use distinct run identifiers.' }    $expectedAlarms = @('techx-prod-tf2-mandate12-immutable-audit-health-check-errors','techx-prod-tf2-mandate12-immutable-audit-health-lambda-dlq-visible','techx-prod-tf2-mandate12-immutable-audit-control-health')
    if ($audit.status -ne 'PASS' -or @($audit.alarms).Count -ne 3) { throw 'Audit evidence is incomplete.' }
    foreach ($alarm in @($audit.alarms)) { Assert-ExactProperties $alarm @('name','state','windowStatus','periodSeconds','evaluationPeriods','okDatapoints') 'audit alarm'; if ($expectedAlarms -notcontains $alarm.name -or $alarm.state -ne 'OK' -or $alarm.windowStatus -ne 'PASS' -or [int]$alarm.evaluationPeriods -lt 1 -or [int]$alarm.okDatapoints -lt [int]$alarm.evaluationPeriods -or [int]$alarm.periodSeconds -lt 1) { throw 'Audit alarm did not remain OK for its complete window.' } }
    if (@($audit.alarms.name | Select-Object -Unique).Count -ne 3) { throw 'Audit alarm names are not unique.' }
    return $true
}
Export-ModuleMember -Function Test-Mandate21Approval, Assert-ExactProperties, Read-BoundedJson

# Change trail: @hungxqt - 2026-07-29 - Added strict revision, evidence, gate, and audit-window approval validation without a cost gate.
