Set-StrictMode -Version Latest
function Invoke-Mandate21SkipAll {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$VariantMap,[Parameter(Mandatory)][object[]]$LiveTemplates,[Parameter(Mandatory)][scriptblock]$StartExperiment,[Parameter(Mandatory)][scriptblock]$GetExperiment,[Parameter(Mandatory)][scriptblock]$Sleep,[Parameter(Mandatory)][scriptblock]$GetNow,[Parameter(Mandatory)][datetime]$Deadline,[Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][scriptblock]$OnTransition,[int]$PollSeconds=10)
    $expectedOrder=@('1a-primary-in','1a-primary-outside','1b-primary-in','1b-primary-outside')
    if (@($VariantMap.Keys).Count -ne 4 -or (@($VariantMap.Keys) -join ',') -ne ($expectedOrder -join ',')) { throw 'Variant execution order is invalid.' }
    $records=@()
    foreach ($variant in $expectedOrder) {
        $templateId=[string]$VariantMap[$variant]; $live=@($LiveTemplates | Where-Object { $_.variant -eq $variant })
        if ($live.Count -ne 1) { throw "Live metadata is missing for $variant." }
        $startedAt=& $GetNow; $null = & $OnTransition ([pscustomobject]@{event="starting";variant=$variant;templateId=$templateId;at=$startedAt.ToUniversalTime().ToString("o")}); $start=& $StartExperiment $variant $templateId $RunId; $experimentId=[string]$start.experiment.id
        if ($experimentId -notmatch '^EXP[A-Za-z0-9]+$') { throw "FIS returned an invalid experiment ID for $variant." }
        $null = & $OnTransition ([pscustomobject]@{event="started";variant=$variant;templateId=$templateId;experimentId=$experimentId;at=((& $GetNow).ToUniversalTime().ToString("o"))})
        do { if ((& $GetNow) -ge $Deadline) { throw "Timed out waiting for $experimentId." }; & $Sleep $PollSeconds; $current=& $GetExperiment $experimentId; $state=[string]$current.experiment.state.status; $null = & $OnTransition ([pscustomobject]@{event="poll";variant=$variant;templateId=$templateId;experimentId=$experimentId;state=$state;at=((& $GetNow).ToUniversalTime().ToString("o"))}) } while ($state -notin @('completed','stopped','failed'))
        $null = & $OnTransition ([pscustomobject]@{event="terminal";variant=$variant;templateId=$templateId;experimentId=$experimentId;state=$state;at=((& $GetNow).ToUniversalTime().ToString("o"))})
        if ($state -ne 'completed') { throw "FIS skip-all experiment $experimentId ended in $state; remaining variants were not started." }
        $records += [pscustomobject]@{variant=$variant;templateId=$templateId;revisionSha256=$live[0].revisionSha256;lastUpdateTime=$live[0].lastUpdateTime;startedAt=$startedAt.ToUniversalTime().ToString('o');terminalAt=((& $GetNow).ToUniversalTime().ToString('o'));experimentId=$experimentId;terminalState=$state;resolvedTargets=$current.experiment.targets;stopAlarmArns=$live[0].stopAlarmArns;cleanupStatus='NOT_APPLICABLE'}
    }
    if ($records.Count -ne 4 -or @($records | Where-Object { $_.terminalState -ne 'completed' -or $_.cleanupStatus -ne 'NOT_APPLICABLE' }).Count -gt 0) { throw 'Four-template skip-all aggregate did not pass.' }
    return @($records)
}
Export-ModuleMember -Function Invoke-Mandate21SkipAll

# Change trail: @hungxqt - 2026-07-29 - Added injectable fixed-order fail-fast orchestration for four real FIS skip-all experiments.