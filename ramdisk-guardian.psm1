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
    param([AllowNull()]$AvailableGB,[AllowNull()]$UsedGB,[AllowNull()]$UnaccountedGB,[AllowNull()]$CorrelatedGrowthGB,[double]$SoftLimitGB=8)
    if($null -eq $UsedGB -or -not [double]::IsFinite($UsedGB) -or $UsedGB -lt 0 -or $UsedGB -gt $SoftLimitGB){return $null}
    if($null -eq $UnaccountedGB -or -not [double]::IsFinite($UnaccountedGB)){return $null}
    # Retain the historical strong signal, including during baseline warm-up.
    if($UnaccountedGB -ge 8){return 'unaccounted-memory'}
    if($null -eq $CorrelatedGrowthGB -or -not [double]::IsFinite($CorrelatedGrowthGB)){return $null}
    if($CorrelatedGrowthGB -ge 8){return 'relative-unaccounted-memory'}
    if($null -ne $AvailableGB -and [double]::IsFinite($AvailableGB) -and $AvailableGB -ge 0 -and $AvailableGB -lt 5 -and $CorrelatedGrowthGB -ge 4){return 'low-memory-with-unaccounted-growth'}
    return $null
}
function Get-RamdiskMemoryAssessment {
    [CmdletBinding()]
    param(
        [AllowNull()][Collections.IDictionary]$State,[Parameter(Mandatory)][string]$Identity,
        [AllowNull()]$AvailableGB,[AllowNull()]$UsedGB,[AllowNull()]$UnaccountedGB,
        [datetimeoffset]$NowUtc=[datetimeoffset]::UtcNow
    )
    # This is a workload-relative residual, NOT a measurement of driver allocation.
    # Subtract live cache growth from both signals so useful cache is not a leak.
    $next=@{Schema='ramdisk.memory-baseline.v1';Identity=$Identity;LastSampleUtc=$null;WarmSinceUtc=$null;WarmSamples=0;TrendSinceUtc=$null;Samples=@();Frozen=$null}
    $result=[ordered]@{State=$next;Status='unavailable';BaselineResidualGB=$null;BaselineAvailableGB=$null;ResidualGrowthGB=$null;AvailableLossGB=$null;CorrelatedGrowthGB=$null;TrendReady=$false}
    if($State -and $State.Schema -ne $next.Schema){throw 'Unsupported memory baseline state.'}
    # A failed read supplies no identity evidence. Keep the last GOOD state and
    # timestamp; compare identity and the observation gap on the next valid read.
    $valid=$true
    foreach($value in @($AvailableGB,$UsedGB,$UnaccountedGB)){
        if($null -eq $value -or -not [double]::IsFinite($value)){$valid=$false}
    }
    if(-not $valid -or $AvailableGB -lt 0 -or $UsedGB -lt 0){
        if($State){$result.State=$State}
        return [pscustomobject]$result
    }
    if($State){
        if($State.Identity -eq $Identity -and $State.LastSampleUtc){
            $gap=($NowUtc-[datetimeoffset]$State.LastSampleUtc).TotalSeconds
            if($gap -ge 0 -and $gap -le 7200){
                $next.LastSampleUtc=$State.LastSampleUtc
                $next.WarmSinceUtc=$State.WarmSinceUtc;$next.WarmSamples=$State.WarmSamples
                if($gap -le 1200){$next.TrendSinceUtc=$State.TrendSinceUtc}
                $next.Samples=@($State.Samples | Where-Object {($NowUtc-[datetimeoffset]$_.Utc).TotalHours -le 24})
                $next.Frozen=$State.Frozen
            }
        }
    }
    $residual=[double]$UnaccountedGB-[double]$UsedGB
    $available=[double]$AvailableGB+[double]$UsedGB
    if(-not $next.WarmSinceUtc){$next.WarmSinceUtc=$NowUtc.ToString('o')}
    $next.WarmSamples=[Math]::Min(3,$next.WarmSamples+1)
    $ready=$next.WarmSamples -ge 3 -and ($NowUtc-[datetimeoffset]$next.WarmSinceUtc).TotalMinutes -ge 30
    $baseline=$next.Frozen
    if(-not $baseline -and $next.Samples.Count -gt 0){
        $residuals=@($next.Samples | ForEach-Object {[double]$_.ResidualGB} | Sort-Object)
        $availability=@($next.Samples | ForEach-Object {[double]$_.AvailableGB} | Sort-Object)
        $lo=[int][Math]::Floor(($residuals.Count-1)/2);$hi=[int][Math]::Floor($residuals.Count/2)
        $baseline=@{ResidualGB=($residuals[$lo]+$residuals[$hi])/2;AvailableGB=($availability[$lo]+$availability[$hi])/2}
    }
    $learn=$true
    $result.Status='warming-up'
    if($baseline){
        if($ready){$result.Status='ready'}
        $result.BaselineResidualGB=$baseline.ResidualGB
        $result.BaselineAvailableGB=$baseline.AvailableGB
        $result.ResidualGrowthGB=[Math]::Round($residual-$baseline.ResidualGB,2)
        $result.AvailableLossGB=[Math]::Round($baseline.AvailableGB-$available,2)
        $growth=[Math]::Round([Math]::Max(0,[Math]::Min($result.ResidualGrowthGB,$result.AvailableLossGB)),2)
        if($ready){$result.CorrelatedGrowthGB=$growth}
        # Do not learn ANY correlated rise. Even a sub-threshold daily leak would
        # otherwise become the rolling median and disappear from detection.
        $learn=$growth -le 0
        $next.Frozen=if($learn){$null}else{$baseline}
    }
    if($learn -and $UnaccountedGB -lt 4 -and ($next.Samples.Count -eq 0 -or ($NowUtc-[datetimeoffset]$next.Samples[-1].Utc).TotalMinutes -ge 5)){
        $next.Samples=@(($next.Samples + @{Utc=$NowUtc.ToString('o');ResidualGB=$residual;AvailableGB=$available}) | Select-Object -Last 288)
    }
    # A workload-relative signal is weaker than the absolute historical signal.
    # Require it in separate observations before entering the short confirmation
    # loop. This filters isolated scheduler samples that recover by themselves.
    if($null -ne $result.CorrelatedGrowthGB -and ($result.CorrelatedGrowthGB -ge 8 -or ($AvailableGB -lt 5 -and $result.CorrelatedGrowthGB -ge 4))){
        if(-not $next.TrendSinceUtc){$next.TrendSinceUtc=$NowUtc.ToString('o')}
        $result.TrendReady=($NowUtc-[datetimeoffset]$next.TrendSinceUtc).TotalMinutes -ge 5
    }else{$next.TrendSinceUtc=$null}
    $next.LastSampleUtc=$NowUtc.ToString('o')
    return [pscustomobject]$result
}
function Resolve-RamdiskRecoveryDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$State,[AllowNull()][string]$PressureReason,
        [datetimeoffset]$NowUtc=[datetimeoffset]::UtcNow,[switch]$Paused,
        [int]$ActiveLeaseCount=0,[switch]$LeaseEvidenceUnknown,[switch]$RelativeEvidenceReady,
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
        if(-not $continuous -or -not $next.PressureSinceUtc){$next.PressureSinceUtc=$NowUtc.ToString('o');$next.PressureSamples=0}
        $next.PressureReason=$PressureReason;$next.PressureSamples=[int]$next.PressureSamples+1
        $duration=($NowUtc-[datetimeoffset]$next.PressureSinceUtc).TotalSeconds
        $reason='confirming-pressure'
        if($next.SuppressUntilUtc -and [datetimeoffset]$next.SuppressUntilUtc -gt $NowUtc){$reason='no-benefit-or-failure-cooldown'}
        elseif($next.LastAttemptUtc -and ($NowUtc-[datetimeoffset]$next.LastAttemptUtc).TotalSeconds -lt $CooldownSeconds){$reason='recovery-cooldown'}
        elseif($PressureReason -in @('relative-unaccounted-memory','low-memory-with-unaccounted-growth') -and -not $RelativeEvidenceReady){
            $reason='confirming-memory-trend';$next.PressureSinceUtc=$null;$next.PressureSamples=0
        }
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
Export-ModuleMember -Function Write-RamdiskTextAtomically,Write-RamdiskJson,Read-RamdiskJson,New-RamdiskRecoveryState,Get-RamdiskPressureReason,Get-RamdiskMemoryAssessment,Resolve-RamdiskRecoveryDecision,Get-RamdiskLeaseState,Get-RamdiskRecoveryBenefit
