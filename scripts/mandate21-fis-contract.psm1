Set-StrictMode -Version Latest

function ConvertTo-CanonicalValue {
    param([Parameter(Mandatory, ValueFromPipeline)]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        $keys=@($Value.Keys); [Array]::Sort($keys,[StringComparer]::Ordinal); foreach ($key in $keys) { $ordered[$key] = ConvertTo-CanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return @($Value | ForEach-Object { ConvertTo-CanonicalValue $_ }) }
    $ordered = [ordered]@{}
    $names=@($Value.PSObject.Properties.Name); [Array]::Sort($names,[StringComparer]::Ordinal); foreach ($name in $names) { $ordered[$name] = ConvertTo-CanonicalValue $Value.PSObject.Properties[$name].Value }
    return $ordered
}
function Get-Mandate21Sha256 {
    param([Parameter(Mandatory)]$Value)
    $canonical = ConvertTo-CanonicalValue $Value | ConvertTo-Json -Depth 100 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path, [int64]$MaxBytes = 10485760)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer -and $item.Length -le $MaxBytes) { return (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    throw "Evidence file is missing, not regular, or exceeds the size limit."
}
function Assert-Mandate21Contract {
    param([Parameter(Mandatory)]$Contract)
    if ($Contract.schemaVersion -ne 1 -or $Contract.region -ne "us-east-1" -or $Contract.accountId -ne "493499579600") { throw "Contract schema, region, or production account is invalid." }
    if ([string]$Contract.clusterContext -notmatch '^arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod$' -or ($Contract.clusterContext -split ':' )[4] -ne $Contract.accountId) { throw "Contract cluster context/account binding is invalid." }
    if ($Contract.rdsInstanceIdentifier -ne "techx-prod-tf2-postgresql") { throw "Contract RDS identifier is invalid." }
    $ids = @($Contract.zones.'us-east-1a'.primaryInZoneTemplateId, $Contract.zones.'us-east-1a'.primaryOutsideZoneTemplateId, $Contract.zones.'us-east-1b'.primaryInZoneTemplateId, $Contract.zones.'us-east-1b'.primaryOutsideZoneTemplateId)
    if ($ids.Count -ne 4 -or @($ids | Where-Object { $_ -notmatch '^EXT[A-Za-z0-9]+$' }).Count -gt 0 -or @($ids | Select-Object -Unique).Count -ne 4) { throw "Contract must contain four unique FIS template IDs." }
    foreach ($id in $ids) { if ($null -eq $Contract.cleanupByTemplateId.PSObject.Properties[$id]) { throw "Cleanup contract is missing for template $id." } }
    $variants = Get-Mandate21VariantMap $Contract
    foreach ($entry in $variants.GetEnumerator()) { $revision = $Contract.templateRevisions.PSObject.Properties[$entry.Key].Value; if ($null -eq $revision -or $revision.templateId -ne $entry.Value -or $revision.revisionSha256 -notmatch "^[0-9a-f]{64}$") { throw "Expected canonical revision is missing for $($entry.Key)." } }
    $alarmPattern="^arn:aws:cloudwatch:us-east-1:493499579600:alarm:[A-Za-z0-9_.:/+=,@-]+$"
    if (@($Contract.requiredStopAlarmArns).Count -ne 4 -or @($Contract.requiredStopAlarmArns | Select-Object -Unique).Count -ne 4 -or @($Contract.requiredStopAlarmArns | Where-Object { $_ -notmatch $alarmPattern }).Count -gt 0) { throw "Exactly four unique production CloudWatch alarm ARNs are required." }
    return $true
}
function Get-Mandate21VariantMap {
    param([Parameter(Mandatory)]$Contract)
    [ordered]@{
        '1a-primary-in' = [string]$Contract.zones.'us-east-1a'.primaryInZoneTemplateId
        '1a-primary-outside' = [string]$Contract.zones.'us-east-1a'.primaryOutsideZoneTemplateId
        '1b-primary-in' = [string]$Contract.zones.'us-east-1b'.primaryInZoneTemplateId
        '1b-primary-outside' = [string]$Contract.zones.'us-east-1b'.primaryOutsideZoneTemplateId
    }
}
function Assert-Mandate21LiveTemplate {
    param([Parameter(Mandatory)]$Contract, [Parameter(Mandatory)][string]$Variant, [Parameter(Mandatory)]$Template)
    $expected = $Contract.templateRevisions.PSObject.Properties[$Variant].Value
    if ($null -eq $expected -or $Template.id -ne $expected.templateId) { throw "Live template ID mismatch for $Variant." }
    $hash = Get-Mandate21Sha256 $Template
    if ($hash -ne $expected.revisionSha256) { throw "Live template canonical revision drift for $Variant." }
    if ($Template.experimentOptions.emptyTargetResolutionMode -ne 'fail' -or $Template.tags.CleanupPolicy -ne 'fis-native-verify-v1') { throw "Live template fail-closed or cleanup policy drift for $Variant." }
    $alarms = @($Template.stopConditions | ForEach-Object { if ($_.value) { [string]$_.value } else { [string]$_.source } })
    if ($alarms.Count -ne 4 -or @($alarms | Where-Object { $Contract.requiredStopAlarmArns -notcontains $_ }).Count -gt 0 -or @($Contract.requiredStopAlarmArns | Where-Object { $alarms -notcontains $_ }).Count -gt 0) { throw "Live template stop-alarm drift for $Variant." }
    return [pscustomobject]@{ variant=$Variant;templateId=$Template.id;revisionSha256=$hash;lastUpdateTime=[string]$Template.lastUpdateTime;stopAlarmArns=$alarms;template=$Template }
}Export-ModuleMember -Function ConvertTo-CanonicalValue, Get-Mandate21Sha256, Get-FileSha256, Assert-Mandate21Contract, Get-Mandate21VariantMap, Assert-Mandate21LiveTemplate

# Change trail: @hungxqt - 2026-07-29 - Added canonical hashing and strict four-variant FIS contract validation.