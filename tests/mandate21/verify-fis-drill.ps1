$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "../../scripts/mandate21-fis-orchestration.psm1") -Force
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
$map=[ordered]@{'1a-primary-in'='EXTA';'1a-primary-outside'='EXTB';'1b-primary-in'='EXTC';'1b-primary-outside'='EXTD'}
$live=@($map.GetEnumerator() | ForEach-Object {[pscustomobject]@{variant=$_.Key;templateId=$_.Value;revisionSha256=('a'*64);lastUpdateTime='t';stopAlarmArns=@('a','b','c','d')}})
$starts=[Collections.Generic.List[string]]::new(); $counter=0; $now=[datetime]'2026-07-29T00:00:00Z'
$start={param($variant,$templateId,$runId)$starts.Add($variant);$script:counter++;[pscustomobject]@{experiment=[pscustomobject]@{id="EXP$script:counter"}}}
$get={param($id)[pscustomobject]@{experiment=[pscustomobject]@{state=[pscustomobject]@{status='completed'};targets=[pscustomobject]@{resolved=$true}}}}
$records=@(Invoke-Mandate21SkipAll -VariantMap $map -LiveTemplates $live -StartExperiment $start -GetExperiment $get -Sleep {param($s)} -GetNow {$now} -Deadline $now.AddMinutes(1) -RunId 'run-123456' -OnTransition {param($t)})
Assert-True (($starts -join ',') -eq (($map.Keys) -join ',')) "must start exact fixed order"
Assert-True ($records.Count -eq 4 -and @($records | Where-Object {$_.terminalState -ne 'completed' -or $_.cleanupStatus -ne 'NOT_APPLICABLE'}).Count -eq 0) "aggregate requires completed and NOT_APPLICABLE"
$starts.Clear();$script:counter=0
$failedGet={param($id)$state=if($id -eq 'EXP2'){'failed'}else{'completed'};[pscustomobject]@{experiment=[pscustomobject]@{state=[pscustomobject]@{status=$state};targets=$null}}}
try { Invoke-Mandate21SkipAll -VariantMap $map -LiveTemplates $live -StartExperiment $start -GetExperiment $failedGet -Sleep {param($s)} -GetNow {$now} -Deadline $now.AddMinutes(1) -RunId 'run-123456' -OnTransition {param($t)} | Out-Null; throw 'failure accepted' } catch { Assert-True ($_.Exception.Message -ne 'failure accepted') "failed terminal rejected" }
Assert-True ($starts.Count -eq 2) "failure on second must prevent third and fourth start"
$transitionRecords=[Collections.Generic.List[object]]::new(); $starts.Clear(); $script:counter=0
$recordsWithCallback=@(Invoke-Mandate21SkipAll -VariantMap $map -LiveTemplates $live -StartExperiment $start -GetExperiment $get -Sleep {param($s)} -GetNow {$now} -Deadline $now.AddMinutes(1) -RunId 'run-123456' -OnTransition {param($t)[void]$transitionRecords.Add($t)})
Assert-True ($recordsWithCallback.Count -eq 4 -and $transitionRecords.Count -ge 12) "transition callback must not pollute four experiment records"
$wrapperPath=Join-Path $PSScriptRoot "../../scripts/mandate21-fis-drill.ps1"; $tokens=$null;$parseErrors=$null;[Management.Automation.Language.Parser]::ParseFile($wrapperPath,[ref]$tokens,[ref]$parseErrors)|Out-Null;Assert-True ($parseErrors.Count -eq 0) "wrapper must parse"
$wrapper=Get-Content -Raw (Join-Path $PSScriptRoot "../../scripts/mandate21-fis-drill.ps1"); Assert-True ($wrapper.IndexOf('if(-not $Execute)') -ge 0 -and $wrapper.IndexOf('start-experiment') -gt $wrapper.IndexOf('if(-not $Execute)')) "no-Execute exit precedes starts"; Assert-True ($wrapper.Contains('NewGuid') -and $wrapper.Contains('refusing to overwrite')) "run evidence path must be collision-resistant"
Assert-True ($wrapper.Contains('Save-RunEnvelope') -and $wrapper.IndexOf('Save-RunEnvelope') -lt $wrapper.IndexOf('Invoke-Mandate21SkipAll')) "run evidence saved before first start"
Assert-True (-not $wrapper.Contains('CostApproved') -and -not $wrapper.Contains('ConfirmationToken') -and -not $wrapper.Contains('m21-preview')) "legacy and synthetic paths absent"
Write-Host "FIS drill mocked orchestration checks passed."

# Change trail: @hungxqt - 2026-07-29 - Added mocked fixed-order, completed-only, cleanup, fail-fast, and read-only wrapper checks.