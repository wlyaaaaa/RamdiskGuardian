#requires -Version 7.0
[CmdletBinding()]
param([string]$Root=$PSScriptRoot,[switch]$Json)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'ramdisk-guardian.psm1') -Force
$result=[ordered]@{Schema='ramdisk.health.v1';ObservedUtc=[datetime]::UtcNow.ToString('o');Status='unknown';WriteMode='zero_write';Reasons=@();Drive='Z';Observation=$null;Task=$null;Volume=$null;Recovery=$null}
$reasons=[Collections.Generic.List[string]]::new()
try{
    $override=Join-Path $Root 'ramdrive.txt'
    if(Test-Path -LiteralPath $override){$letter=([IO.File]::ReadAllText($override)).Trim();if($letter -notmatch '^[A-Za-z]$'){throw 'invalid drive override'};$result.Drive=$letter.ToUpperInvariant()}
    $volume=Get-Volume -DriveLetter $result.Drive -ErrorAction Stop
    $result.Volume=@{LabelMatches=($volume.FileSystemLabel -ieq 'RAMDISK');FileSystem=$volume.FileSystem;Health=[string]$volume.HealthStatus;UsedGiB=[Math]::Round(($volume.Size-$volume.SizeRemaining)/1GB,2);FreeGiB=[Math]::Round($volume.SizeRemaining/1GB,2)}
    if(-not $result.Volume.LabelMatches -or $volume.HealthStatus -ne 'Healthy'){$reasons.Add('volume-health-or-identity-mismatch')}
    if ($volume.FileSystem -ine 'NTFS') { $reasons.Add('volume-filesystem-mismatch') }
    $disk=$result.Drive+':\'
    $paths=@('Caches\Personal','Caches\Work','Scratch\Personal','Scratch\Work','.ramdisk_ready')
    $missing=@($paths|Where-Object{-not(Test-Path -LiteralPath (Join-Path $disk $_))})
    $result.Skeleton=@{Missing=$missing}
    if($missing.Count){$reasons.Add('cache-skeleton-incomplete')}
    $sources=@(Get-ChildItem -LiteralPath $Root -Filter 'Z_*.md' -File)
    if($sources.Count -ne 1){throw 'canonical usage guide unavailable'}
    $target=Join-Path $disk $sources[0].Name.Substring(2)
    $result.GuideMatches=(Get-FileHash $sources[0].FullName).Hash -eq (Get-FileHash $target).Hash
    if(-not $result.GuideMatches){$reasons.Add('usage-guide-drift')}
}catch{$reasons.Add('volume-or-guide-query-unavailable')}
try{
    $task=Get-ScheduledTask -TaskName 'RAMDisk_Code_Backup' -ErrorAction Stop;$info=$task|Get-ScheduledTaskInfo
    $interval=[timespan]::FromMinutes(15)
    $periodic=@($task.Triggers|Where-Object{$_.Enabled -ne $false -and $_.Repetition.Interval}|Select-Object -First 1)
    if($periodic.Count){$interval=[System.Xml.XmlConvert]::ToTimeSpan($periodic[0].Repetition.Interval)}
    $result.Task=@{Name=$task.TaskName;State=[string]$task.State;Enabled=$task.Settings.Enabled;LastRun=$info.LastRunTime;NextRun=$info.NextRunTime;LastTaskResult=$info.LastTaskResult;IntervalSeconds=$interval.TotalSeconds}
    if(-not $task.Settings.Enabled){$reasons.Add('guardian-task-paused')}
    if ($periodic.Count -eq 0) { $reasons.Add('guardian-periodic-trigger-missing') }
    if ($interval.TotalSeconds -le 0) { throw 'Invalid recurring trigger interval.' }
    if ($null -eq $info.LastTaskResult) { $reasons.Add('guardian-last-run-result-unavailable') }
    elseif ($task.State -ne 'Running' -and [long]$info.LastTaskResult -ne 0) { $reasons.Add('guardian-last-run-failed') }
    $staleSeconds=$interval.TotalSeconds*2+180
}catch{$staleSeconds=1980;$reasons.Add('guardian-task-unavailable')}
try{
    $observation=Read-RamdiskJson -Path (Join-Path $Root 'logs\health.json')
    if($null -eq $observation -or $observation.Schema -ne 'ramdisk.health-observation.v1'){throw 'no structured guardian observation'}
    $age=([datetimeoffset]::UtcNow-[datetimeoffset]$observation.ObservedUtc).TotalSeconds
    $current=(Get-FileHash (Join-Path $Root 'zguardian.ps1')).Hash -eq $observation.WorkerSha256
    $current=$current -and $observation.Contains('ModuleSha256') -and (Get-FileHash (Join-Path $Root 'ramdisk-guardian.psm1')).Hash -eq $observation.ModuleSha256
    $result.Observation=@{Health=$observation.Health;AgeSeconds=[Math]::Round($age,1);Fresh=($age -ge 0 -and $age -lt $staleSeconds);SourceCurrent=$current;Metrics=$observation.Metrics}
    if(-not $result.Observation.Fresh){$reasons.Add('guardian-observation-stale')}
    if(-not $current){$reasons.Add('guardian-source-not-yet-observed')}
    if($observation.Health -ne 'OK'){$reasons.Add('guardian-'+$observation.Health.ToLowerInvariant())}
}catch{$reasons.Add('guardian-observation-unavailable')}
try{
    $state=Read-RamdiskJson -Path (Join-Path $Root 'logs\recovery-state.json') -Default (New-RamdiskRecoveryState)
    $control=Read-RamdiskJson -Path (Join-Path $Root 'logs\recovery-control.json') -Default @{Paused=$false}
    if ($null -eq $state -or $state.Schema -ne 'ramdisk.recovery-state.v1' -or $state.LastOutcome -notin @('none','attempting','effective','no-benefit','unknown','failed')) { throw 'Invalid recovery state.' }
    if ($null -eq $control -or $control.Paused -isnot [bool]) { throw 'Recovery pause must be an explicit boolean.' }
    if ($control.Paused) { $reasons.Add('automatic-recovery-paused') }
    if ($state.LastOutcome -eq 'failed') { $reasons.Add('last-recovery-failed') }
    if ($state.LastOutcome -eq 'attempting') { $reasons.Add('recovery-not-yet-confirmed') }
    $leases=Get-RamdiskLeaseState -Directory (Join-Path $Root 'logs\leases')
    $result.Recovery=@{Paused=$control.Paused;LastOutcome=$state.LastOutcome;LastAttemptUtc=$state.LastAttemptUtc;SuppressUntilUtc=$state.SuppressUntilUtc;ActiveConsumers=$leases.Active;UnknownConsumers=$leases.Unknown}
    if($leases.Unknown -gt 0){$reasons.Add('consumer-state-unknown')}
}catch{$reasons.Add('recovery-state-unavailable')}
$result.Reasons=@($reasons);$result.Status=if($reasons.Count){'attention'}else{'healthy'}
if($null -ne $result.Observation -and $result.Observation.Health -eq 'ERROR'){$result.Status='error'}
if($Json){[pscustomobject]$result|ConvertTo-Json -Depth 10}else{[pscustomobject]$result}