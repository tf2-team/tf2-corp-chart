[CmdletBinding()]
param(
    [string]$ContractPath = (Join-Path $PSScriptRoot "mandate21-fis-contract.json"),
    [string]$EvidenceDirectory = (Join-Path $PSScriptRoot "../evidence/mandate21"),
    [string]$ApprovalFile = "", [string]$ChartGitSha = "", [string]$InfraGitSha = "",
    [string]$InfraPreflightPath = "", [string]$Capacity1aTo1bPath = "",
    [string]$Capacity1bTo1aPath = "", [string]$AuditEvidencePath = "",
    [switch]$Execute,
    [ValidateSet("skip-all", "run-all")][string]$ActionsMode = "skip-all",
    [ValidateRange(1,60)][int]$PollSeconds = 10,
    [ValidateRange(5,60)][int]$TimeoutMinutes = 30
)
$ErrorActionPreference="Stop"; Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "mandate21-fis-approval.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "mandate21-fis-orchestration.psm1") -Force
# The approval module imports the contract dependency in module scope. Import
# the contract last as well so its helpers remain available to this wrapper's
# script scope during both read-only validation and execution.
Import-Module (Join-Path $PSScriptRoot "mandate21-fis-contract.psm1") -Force
function Invoke-AwsJson([string[]]$Arguments) { $out=& aws @Arguments 2>&1; if($LASTEXITCODE -ne 0){throw "AWS command failed: $($Arguments[0..1] -join ' ')"}; try{return (($out -join "`n")|ConvertFrom-Json -Depth 100)}catch{throw "AWS returned invalid JSON."} }
function Read-BoundedJson([string]$Path,[int64]$MaxBytes=10MB) { $item=Get-Item -LiteralPath $Path -ErrorAction Stop; if($item.PSIsContainer -or $item.Length -gt $MaxBytes){throw "JSON input is not a bounded regular file."}; return (Get-Content -Raw -LiteralPath $item.FullName|ConvertFrom-Json -Depth 100) }
$contract=Read-BoundedJson $ContractPath 1MB; Assert-Mandate21Contract $contract|Out-Null
$identity=Invoke-AwsJson @("sts","get-caller-identity","--output","json"); $accountFromCluster=($contract.clusterContext -split ':')[4]
if($identity.Account -ne $accountFromCluster -or $identity.Account -ne $contract.accountId){throw "AWS caller account does not match the contract."}
$variantMap=Get-Mandate21VariantMap $contract; $liveTemplates=@()
foreach($entry in $variantMap.GetEnumerator()){ $response=Invoke-AwsJson @("fis","get-experiment-template","--region",$contract.region,"--id",$entry.Value,"--output","json"); $template=$response.experimentTemplate; if($null -eq $template){throw "Live FIS template response is incomplete."}; $liveTemplates+=Assert-Mandate21LiveTemplate -Contract $contract -Variant $entry.Key -Template $template }
$contractSha=Get-Mandate21Sha256 $contract
if(-not $Execute){[pscustomobject]@{mode='read-only';status='PASS';accountId=$identity.Account;region=$contract.region;clusterContext=$contract.clusterContext;contractSha256=$contractSha;templates=@($liveTemplates|Select-Object variant,templateId,revisionSha256,lastUpdateTime,stopAlarmArns)}|ConvertTo-Json -Depth 20;exit 0}
if($ActionsMode -eq 'run-all'){throw 'run-all is an explicit live-fault path and is outside this approved skip-all implementation; no experiment was started.'}
foreach($value in @($ApprovalFile,$ChartGitSha,$InfraGitSha,$InfraPreflightPath,$Capacity1aTo1bPath,$Capacity1bTo1aPath,$AuditEvidencePath)){if([string]::IsNullOrWhiteSpace($value)){throw 'Execute requires the approval, Git revisions, and four evidence paths.'}}
if($ChartGitSha -notmatch '^[0-9a-f]{40}$' -or $InfraGitSha -notmatch '^[0-9a-f]{40}$'){throw 'Git revisions must be lower-case 40-character SHAs.'}
$approval=Read-BoundedJson $ApprovalFile 1MB
Test-Mandate21Approval -Approval $approval -ExpectedAccountId $identity.Account -ExpectedRegion $contract.region -ExpectedClusterContext $contract.clusterContext -ExpectedChartGitSha $ChartGitSha -ExpectedInfraGitSha $InfraGitSha -ExpectedContractSha256 $contractSha -LiveTemplates $liveTemplates -InfraPreflightPath $InfraPreflightPath -Capacity1aTo1bPath $Capacity1aTo1bPath -Capacity1bTo1aPath $Capacity1bTo1aPath -AuditEvidencePath $AuditEvidencePath|Out-Null
$runId="m21-skip-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
if(-not(Test-Path -LiteralPath $EvidenceDirectory)){New-Item -ItemType Directory -Path $EvidenceDirectory -Force|Out-Null}
$outputPath=Join-Path $EvidenceDirectory "$runId-skip-all.json"; if(Test-Path -LiteralPath $outputPath){throw "Run evidence path already exists; refusing to overwrite."}; $transitions=[Collections.Generic.List[object]]::new()
$envelope=[ordered]@{schemaVersion=1;runId=$runId;actionsMode='skip-all';accountId=$identity.Account;region=$contract.region;clusterContext=$contract.clusterContext;chartGitSha=$ChartGitSha;infraGitSha=$InfraGitSha;contractSha256=$contractSha;approval=[ordered]@{approvedBy=$approval.approvedBy;changeReference=$approval.changeReference;approvedAt=$approval.approvedAt;expiresAt=$approval.expiresAt;evidence=$approval.evidence};startedAt=(Get-Date).ToUniversalTime().ToString('o');completedAt=$null;status='RUNNING';transitions=$transitions;experiments=@();failure=$null}
function Save-RunEnvelope { $temporary="$outputPath.tmp-$PID"; $envelope|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $temporary -Encoding utf8; Move-Item -LiteralPath $temporary -Destination $outputPath -Force }
Save-RunEnvelope
$deadline=(Get-Date).AddMinutes($TimeoutMinutes)
$startCallback={param($variant,$templateId,$callbackRunId) Invoke-AwsJson @("fis","start-experiment","--region",$contract.region,"--experiment-template-id",$templateId,"--experiment-options","actionsMode=skip-all","--tags","Mandate=21,Variant=$variant,RunId=$callbackRunId","--output","json")}
$getCallback={param($experimentId) Invoke-AwsJson @("fis","get-experiment","--region",$contract.region,"--id",$experimentId,"--output","json")}
$transitionCallback={param($transition) [void]$transitions.Add($transition); Save-RunEnvelope}
try{
    $records=@(Invoke-Mandate21SkipAll -VariantMap $variantMap -LiveTemplates $liveTemplates -StartExperiment $startCallback -GetExperiment $getCallback -Sleep {param($seconds)Start-Sleep -Seconds $seconds} -GetNow {(Get-Date).ToUniversalTime()} -Deadline $deadline -RunId $runId -OnTransition $transitionCallback -PollSeconds $PollSeconds)
    $envelope.experiments=$records; $envelope.status='PASS'; $envelope.completedAt=(Get-Date).ToUniversalTime().ToString('o'); Save-RunEnvelope
}catch{
    $envelope.status='FAIL'; $envelope.completedAt=(Get-Date).ToUniversalTime().ToString('o'); $envelope.failure=[string]$_.Exception.Message; Save-RunEnvelope; throw
}
Write-Host "Four-template skip-all PASS: $outputPath"

# Change trail: @hungxqt - 2026-07-29 - Enforce strict approvals and atomically record four real sequential FIS skip-all experiments.
