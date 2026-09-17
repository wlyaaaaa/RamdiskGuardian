#requires -Version 7.0
Set-StrictMode -Version Latest

function Write-RamdiskTextAtomically {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[AllowEmptyString()][string]$Text)
    $target=[IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    $candidate="$target.$([guid]::NewGuid().ToString('N')).candidate"
    try {
        [IO.File]::WriteAllText($candidate,$Text,[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($target)){[IO.File]::Replace($candidate,$target,"$target.previous",$true)}else{[IO.File]::Move($candidate,$target)}
    } finally {if([IO.File]::Exists($candidate)){[IO.File]::Delete($candidate)}}
}
function Write-RamdiskJson {
    param([string]$Path,[Parameter(Mandatory)]$Value)
    Write-RamdiskTextAtomically -Path $Path -Text (($Value|ConvertTo-Json -Depth 8)+"`n")
}
function Read-RamdiskJson {
    param([string]$Path,$Default)
    if(-not [IO.File]::Exists($Path)){return $Default}
    $args=@{AsHashtable=$true;ErrorAction='Stop'}
    if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$args.DateKind='String'}
    [IO.File]::ReadAllText($Path)|ConvertFrom-Json @args
}
function New-RamdiskRecoveryState {
    @{Schema='ramdisk.recovery-state.v1';LastSampleUtc=$null;PressureSinceUtc=$null;PressureReason=$null;PressureSamples=0;LastAttemptUtc=$null;LastOutcome='none';SuppressUntilUtc=$null}
}
function Get-RamdiskPressureReason {
    param([AllowNull()]$AvailableGB,[AllowNull()]$UsedGB,[AllowNull()]$UnaccountedGB,[double]$SoftLimitGB=8)
    if($null -eq $UsedGB -or $UsedGB -gt $SoftLimitGB){return $null}
    if($null -ne $AvailableGB -and $AvailableGB -lt 5){return 'low-host-memory'}
    if($null -ne $UnaccountedGB -and $UnaccountedGB -ge 8){return 'unaccounted-memory'}
    return $null
}
function Resolve-RamdiskRecoveryDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$State,[AllowNull()][string]$PressureReason,
        [datetimeoffset]$NowUtc=[datetimeoffset]::UtcNow,[switch]$Paused,
        [int]$ActiveLeaseCount=0,[switch]$LeaseEvidenceUnknown,
        [ValidateRange(1,10)][int]$RequiredSamples=3,[ValidateRange(0,120)][int]$MinimumPressureSeconds=10,
        [ValidateRange(60,86400)][int]$CooldownSeconds=3600
    )
    if($State.Schema -ne 'ramdisk.recovery-state.v1'){throw 'Unsupported recovery state.'}
    $next=@{};foreach($key in $State.Keys){$next[$key]=$State[$key]}
    $continuous=$false
    if($next.LastSampleUtc){$age=($NowUtc-[datetimeoffset]$next.LastSampleUtc).TotalSeconds;$continuous=$age -ge 0 -and $age -le 30}
    $next.LastSampleUtc=$NowUtc.ToString('o')
    $allowed=$false;$reason='no-pressure'
    if(-not $PressureReason -or $Paused -or $ActiveLeaseCount -gt 0 -or $LeaseEvidenceUnknown){
        $next.PressureSinceUtc=$null;$next.PressureReason=$null;$next.PressureSamples=0
        $reason=if($Paused){'recovery-paused'}elseif($LeaseEvidenceUnknown){'consumer-state-unknown'}elseif($ActiveLeaseCount -gt 0){'active-cache-consumer'}else{'no-pressure'}
    } else {
        if(-not $continuous -or $next.PressureReason -ne $PressureReason -or -not $next.PressureSinceUtc){$next.PressureSinceUtc=$NowUtc.ToString('o');$next.PressureSamples=0}
        $next.PressureReason=$PressureReason;$next.PressureSamples=[int]$next.PressureSamples+1
        $duration=($NowUtc-[datetimeoffset]$next.PressureSinceUtc).TotalSeconds
        $reason='confirming-pressure'
        if($next.SuppressUntilUtc -and [datetimeoffset]$next.SuppressUntilUtc -gt $NowUtc){$reason='no-benefit-or-failure-cooldown'}
        elseif($next.LastAttemptUtc -and ($NowUtc-[datetimeoffset]$next.LastAttemptUtc).TotalSeconds -lt $CooldownSeconds){$reason='recovery-cooldown'}
        elseif($next.PressureSamples -ge $RequiredSamples -and $duration -ge $MinimumPressureSeconds){$allowed=$true;$reason=$PressureReason}
    }
    [pscustomobject]@{Allowed=$allowed;Reason=$reason;State=$next}
}
function Get-RamdiskLeaseState {
    [CmdletBinding()]
    param([string]$Directory,[datetimeoffset]$NowUtc=[datetimeoffset]::UtcNow,[scriptblock]$ProcessProvider={param($Id)Get-Process -Id $Id -ErrorAction Stop})
    $active=0;$expired=0;$unknown=0
    if(-not [IO.Directory]::Exists($Directory)){return [pscustomobject]@{Active=0;Expired=0;Unknown=0}}
    foreach($file in Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -ErrorAction Stop){
        try {
            $lease=Read-RamdiskJson -Path $file.FullName
            if($lease.Schema -ne 'ramdisk.cache-lease.v1' -or [int]$lease.ProcessId -le 0){throw 'Invalid cache lease.'}
            if([datetimeoffset]$lease.ExpiresUtc -le $NowUtc){$expired++;continue}
            try{$process=& $ProcessProvider ([int]$lease.ProcessId)}catch{
                if($_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound){$expired++;continue};throw
            }
            if($null -eq $process){$expired++;continue}
            $start=$process.StartTime.ToUniversalTime()
            if([Math]::Abs(($start-([datetimeoffset]$lease.ProcessStartUtc).UtcDateTime).TotalSeconds) -ge 1){$expired++;continue}
            $active++
        } catch {$unknown++}
    }
    [pscustomobject]@{Active=$active;Expired=$expired;Unknown=$unknown}
}
function Get-RamdiskRecoveryBenefit {
    param([AllowNull()]$BeforeAvailableGB,[AllowNull()]$AfterAvailableGB,[AllowNull()]$BeforeUnaccountedGB,[AllowNull()]$AfterUnaccountedGB)
    $availableGain=$null;$unaccountedDrop=$null
    if($null -ne $BeforeAvailableGB -and $null -ne $AfterAvailableGB){$availableGain=[double]$AfterAvailableGB-[double]$BeforeAvailableGB}
    if($null -ne $BeforeUnaccountedGB -and $null -ne $AfterUnaccountedGB){$unaccountedDrop=[double]$BeforeUnaccountedGB-[double]$AfterUnaccountedGB}
    $state=if(($null -ne $availableGain -and $availableGain -ge 1) -or ($null -ne $unaccountedDrop -and $unaccountedDrop -ge 1)){'effective'}elseif($null -eq $availableGain -and $null -eq $unaccountedDrop){'unknown'}else{'no-benefit'}
    [pscustomobject]@{State=$state;AvailableGainGB=$availableGain;UnaccountedDropGB=$unaccountedDrop}
}
Export-ModuleMember -Function Write-RamdiskTextAtomically,Write-RamdiskJson,Read-RamdiskJson,New-RamdiskRecoveryState,Get-RamdiskPressureReason,Resolve-RamdiskRecoveryDecision,Get-RamdiskLeaseState,Get-RamdiskRecoveryBenefit