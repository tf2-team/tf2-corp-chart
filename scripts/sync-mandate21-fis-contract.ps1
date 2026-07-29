[CmdletBinding()]
param(
    [string]$TerraformOutputJson = "",
    [string]$ContractPath = (Join-Path $PSScriptRoot "mandate21-fis-contract.json"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../evidence/mandate21/fis-contract-live.json"),
    [switch]$Sync
)
$ErrorActionPreference = "Stop"; Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot "mandate21-fis-contract.psm1") -Force
function Invoke-AwsJson([string[]]$Arguments) { $out = & aws @Arguments 2>&1; if ($LASTEXITCODE -ne 0) { throw "AWS read failed: $($Arguments[0..1] -join ' ')" }; return (($out -join "`n") | ConvertFrom-Json -Depth 100) }
function Read-BoundedJson([string]$Path) { $item = Get-Item -LiteralPath $Path -ErrorAction Stop; if ($item.PSIsContainer -or $item.Length -gt 1MB) { throw "JSON input must be a regular file no larger than 1 MiB." }; return (Get-Content -Raw -LiteralPath $item.FullName | ConvertFrom-Json -Depth 100) }
if ([string]::IsNullOrWhiteSpace($TerraformOutputJson)) { $contract = Read-BoundedJson $ContractPath } else { $raw = Read-BoundedJson $TerraformOutputJson; $valueProperty = $raw.PSObject.Properties["value"]; $fullProperty = $raw.PSObject.Properties["mandate21_fis_contract"]; $contract = if ($null -ne $valueProperty) { $valueProperty.Value } elseif ($null -ne $fullProperty -and $null -ne $fullProperty.Value.PSObject.Properties["value"]) { $fullProperty.Value.value } else { $raw } }
Assert-Mandate21Contract $contract | Out-Null
$variants = Get-Mandate21VariantMap $contract
$live = @()
foreach ($entry in $variants.GetEnumerator()) {
    $response = Invoke-AwsJson @("fis", "get-experiment-template", "--region", $contract.region, "--id", $entry.Value, "--output", "json")
    $template = $response.experimentTemplate
    if ($null -eq $template -or $template.id -ne $entry.Value) { throw "Live FIS template response is incomplete." }
    $validated = Assert-Mandate21LiveTemplate -Contract $contract -Variant $entry.Key -Template $template
    $live += [pscustomobject]@{ variant = $entry.Key; templateId = $entry.Value; revisionSha256 = $validated.revisionSha256; lastUpdateTime = $validated.lastUpdateTime; targets = $template.targets; actions = $template.actions; stopAlarmArns = $validated.stopAlarmArns; cleanup = $contract.cleanupByTemplateId.($entry.Value) }
}
$result = [ordered]@{ schemaVersion = 1; verifiedAt = (Get-Date).ToUniversalTime().ToString("o"); region = $contract.region; clusterContext = $contract.clusterContext; contractSha256 = Get-Mandate21Sha256 $contract; templates = $live }
if ($Sync) { $parent = Split-Path -Parent $OutputPath; if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }; $temp = "$OutputPath.tmp-$PID"; $result | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temp -Encoding utf8; Move-Item -LiteralPath $temp -Destination $OutputPath -Force; Write-Host "Synced verified contract evidence to $OutputPath" } else { $result | ConvertTo-Json -Depth 100 }

# Change trail: @hungxqt - 2026-07-29 - Verify authoritative Terraform and live FIS template contract metadata without mutation by default.