#requires -Version 7.0
# Z: RamDisk Guardian (cache-only). The legacy RAMDisk_Code_Backup task name
# is retained for compatibility. This is not a data backup or restore service.
[CmdletBinding()]
param([switch]$Inspect,[switch]$Json,[switch]$NoRecovery,[ValidateRange(0,150)][int]$WaitSeconds=150)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=$PSScriptRoot
$script:guardianModuleSha256=(Get-FileHash -LiteralPath (Join-Path $root 'ramdisk-guardian.psm1')).Hash
Import-Module (Join-Path $root 'ramdisk-guardian.psm1') -Force
if((Get-FileHash -LiteralPath (Join-Path $root 'ramdisk-guardian.psm1')).Hash -ne $script:guardianModuleSha256){throw 'Guardian module changed during loading.'}
if($Inspect){& (Join-Path $root 'Get-RamdiskHealth.ps1') -Json:$Json;return}
$logDir=Join-Path $root 'logs'
$log=Join-Path $logDir 'guardian.log'
$statusF=Join-Path $logDir 'STATUS.txt'
$alertF=Join-Path $logDir 'alerts.log'
$lastF=Join-Path $logDir '.lasthealth'
$ramLetter='Z'
$cacheSoftLimitGB = 8
$minimumAvailableMemoryGB = 8
$minimumCommitHeadroomGB = 4
$rxprd='C:\Program Files\Primo Ramdisk\rxprd.exe'
$script:latestMetrics=$null
$script:latestRecovery=$null
function Log($message){
    if([IO.File]::Exists($log) -and (Get-Item -LiteralPath $log).Length -ge 1MB){[IO.File]::Move($log,"$log.1",$true)}
    [IO.File]::AppendAllText($log,('{0}  {1}{2}' -f [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'),$message,[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}
function Set-Health([string]$health,[string]$detail){
    $line='{0}  {1}  {2}' -f [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'),$health,$detail
    $last=Get-Content -LiteralPath $lastF -ErrorAction SilentlyContinue|Select-Object -First 1
    $report=[ordered]@{Schema='ramdisk.health-observation.v1';ObservedUtc=[datetime]::UtcNow.ToString('o');Health=$health;Detail=$detail;Drive=$ramLetter;Metrics=$script:latestMetrics;Recovery=$script:latestRecovery;WorkerSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;ModuleSha256=$script:guardianModuleSha256}
    Write-RamdiskJson -Path (Join-Path $logDir 'health.json') -Value $report
    Write-RamdiskTextAtomically -Path $statusF -Text ($line+"`n")
    # WARN is intentionally silent. Only an ERROR transition interrupts the user.
    if ($health -eq 'ERROR' -and $health -ne $last) {
        if([IO.File]::Exists($alertF) -and (Get-Item -LiteralPath $alertF).Length -ge 1MB){[IO.File]::Move($alertF,"$alertF.1",$true)}
        [IO.File]::AppendAllText($alertF,$line+"`n",[Text.UTF8Encoding]::new($false))
        try{& "$env:WINDIR\System32\msg.exe" * '/TIME:60' "RamDisk($Z) $health - $detail"|Out-Null}catch{}
    }
    Write-RamdiskTextAtomically -Path $lastF -Text ($health+"`n")
    Log "health $health - $detail"
}

function Read-RamDiskSpace {
    for ($i = 0; $i -lt 3; $i++) {
        $volume = Get-Volume -DriveLetter $ramLetter -ErrorAction SilentlyContinue
        if ($volume -and $volume.SizeRemaining) {
            return @([math]::Round($volume.SizeRemaining / 1GB, 1), [math]::Round($volume.Size / 1GB, 1))
        }
        try {
            $driveInfo = New-Object System.IO.DriveInfo($ramLetter)
            if ($driveInfo.IsReady) {
                return @([math]::Round($driveInfo.AvailableFreeSpace / 1GB, 1), [math]::Round($driveInfo.TotalSize / 1GB, 1))
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    return @($null, $null)
}

function Read-UnaccountedGB {
    try {
        $c = Get-Counter '\Memory\Available Bytes','\Memory\Modified Page List Bytes','\Memory\Cache Bytes','\Memory\Pool Paged Bytes','\Memory\Pool Nonpaged Bytes','\Process(_Total)\Working Set' -ErrorAction Stop
        $avail = 0; $mod = 0; $cache = 0; $paged = 0; $nonpaged = 0; $ws = 0
        foreach ($s in $c.CounterSamples) {
            if ($s.Path -match 'available bytes$') { $avail = $s.CookedValue }
            elseif ($s.Path -match 'modified page list bytes$') { $mod = $s.CookedValue }
            elseif ($s.Path -match 'cache bytes$') { $cache = $s.CookedValue }
            elseif ($s.Path -match 'pool paged bytes$') { $paged = $s.CookedValue }
            elseif ($s.Path -match 'pool nonpaged bytes$') { $nonpaged = $s.CookedValue }
            elseif ($s.Path -match 'working set$') { $ws = $s.CookedValue }
        }
        $totalBytes = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).TotalVisibleMemorySize * 1KB
        $inUse = $totalBytes - $avail
        return [math]::Round(($inUse - ($ws + $paged + $nonpaged + $cache + $mod)) / 1GB, 1)
    } catch {
        return $null
    }
}

function Invoke-PrimoCommand([string[]]$Arguments) {
    $ErrorActionPreference = 'Stop'
    $output = & $rxprd @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Primo $($Arguments[0]) failed (exit $LASTEXITCODE): $($output -join ' ')"
    }
    return $output
}

function Resolve-PrimoDiskIndex {
    $listing = Invoke-PrimoCommand @('ls')
    $matchesForDrive = @()
    foreach ($line in $listing) {
        if ([string]$line -match '^\s*#(\d+)\s+(.+)$') {
            $index = [int]$Matches[1]
            $volumes = @([regex]::Matches($Matches[2], '(?i)(?<![A-Z0-9])([A-Z]):(?:\\)?(?=\s|$)') |
                ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() })
            if ($volumes -contains $ramLetter) {
                if ($volumes.Count -ne 1) { throw "Primo disk #$index contains additional volumes; refusing recovery of $Z" }
                $matchesForDrive += $index
            }
        }
    }
    if ($matchesForDrive.Count -ne 1) {
        throw "Primo listing does not identify exactly one disk for $Z"
    }
    return $matchesForDrive[0]
}

$guardianMutex=[Threading.Mutex]::new($false,'Global\RamdiskGuardian-v2')
$mutexTaken=$false
try{
    try{$mutexTaken=$guardianMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$mutexTaken=$true}
    if(-not $mutexTaken){throw 'Another RamdiskGuardian instance is active.'}
    [void][IO.Directory]::CreateDirectory($logDir)
    $override=Join-Path $root 'ramdrive.txt'
    if(Test-Path -LiteralPath $override){
        $letter=([IO.File]::ReadAllText($override)).Trim()
        if($letter -notmatch '^[A-Za-z]$'){throw 'invalid ramdrive.txt value; expected a single drive letter'}
        $ramLetter=$letter.ToUpperInvariant()
    }
    $Z="${ramLetter}:"
    $marker="$Z\.ramdisk_ready"
    Log "--- guardian run (root=$root ram=$Z) ---"
    $deadline=[datetime]::UtcNow.AddSeconds($WaitSeconds)
    while(-not (Test-Path -LiteralPath "$Z\") -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Seconds 3}
    if(-not (Test-Path -LiteralPath "$Z\")){throw "disk $Z is MISSING - check Primo at the next maintenance opportunity"}
    $ramVolume=Get-Volume -DriveLetter $ramLetter -ErrorAction Stop
    $ramVolumeLabel=[string]$ramVolume.FileSystemLabel
    if(-not [string]::Equals($ramVolumeLabel, 'RAMDISK', [StringComparison]::OrdinalIgnoreCase)){throw "refusing $Z because its volume is not RAMDISK"}
    $verifiedPrimoIndex=Resolve-PrimoDiskIndex
    $dirs = @(
        "$Z\Caches", "$Z\Caches\Personal", "$Z\Caches\Work",
        "$Z\Caches\ChromeCache", "$Z\Caches\ChromeCodeCache", "$Z\Caches\ChromeGPUCache",
        "$Z\Caches\360zip_temp", "$Z\Caches\WeFlow",
        "$Z\Scratch", "$Z\Scratch\Personal", "$Z\Scratch\Work", "$Z\TEMP"
    )
    foreach($dir in $dirs){
        if(-not (Test-Path -LiteralPath $dir -PathType Container)){[void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop)}
        if(-not (Test-Path -LiteralPath $dir -PathType Container)){throw "Cache directory readback failed: $dir"}
        if((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Cache skeleton unexpectedly redirects: $dir"}
    }
    $usageSources=@(Get-ChildItem -LiteralPath $root -Filter 'Z_*.md' -File -ErrorAction Stop)
    if($usageSources.Count -ne 1){throw 'Canonical root usage guide is missing or ambiguous.'}
    $usageSource=$usageSources[0]
    $usageTarget=Join-Path "$Z\" $usageSource.Name.Substring(2)
    if(-not (Test-Path -LiteralPath $usageTarget) -or (Get-FileHash -LiteralPath $usageSource.FullName).Hash -ne (Get-FileHash -LiteralPath $usageTarget).Hash){
        Copy-Item -LiteralPath $usageSource.FullName -Destination $usageTarget -Force -ErrorAction Stop
    }
    if((Get-FileHash -LiteralPath $usageSource.FullName).Hash -ne (Get-FileHash -LiteralPath $usageTarget).Hash){throw 'Root usage guide readback mismatch.'}
    if(-not (Test-Path -LiteralPath $marker)){[void](New-Item -ItemType File -Path $marker -ErrorAction Stop)}
    (Get-Item -LiteralPath $marker -Force -ErrorAction Stop).Attributes='Hidden'
    $space=Read-RamDiskSpace
    if($null -eq $space[0]){throw 'RAM disk space query is unavailable.'}
    $free=$space[0];$total=$space[1];$used=[Math]::Round($total-$free,1)
    $warnings=@()
    $availableMemoryGB=$null;$commitHeadroomGB=$null
    try{
        $memory=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $availableMemoryGB=[Math]::Round($memory.AvailableMBytes/1024,1)
        $commitHeadroomGB=[Math]::Round(($memory.CommitLimit-$memory.CommittedBytes)/1GB,1)
    }catch{$warnings+='host memory query failed'}
    $unaccountedGB=Read-UnaccountedGB
    $recoveryStatePath=Join-Path $logDir 'recovery-state.json'
    $recoveryState=Read-RamdiskJson -Path $recoveryStatePath -Default (New-RamdiskRecoveryState)
    $control=Read-RamdiskJson -Path (Join-Path $logDir 'recovery-control.json') -Default @{Paused=$false}
    if($control.Paused -isnot [bool]){throw 'Invalid recovery control state.'}
    $consumerState=Get-RamdiskLeaseState -Directory (Join-Path $logDir 'leases')
    $pressureReason=Get-RamdiskPressureReason -AvailableGB $availableMemoryGB -UsedGB $used -UnaccountedGB $unaccountedGB
    $decision=Resolve-RamdiskRecoveryDecision -State $recoveryState -PressureReason $pressureReason -Paused:($NoRecovery -or $control.Paused) -ActiveLeaseCount $consumerState.Active -LeaseEvidenceUnknown:($consumerState.Unknown -gt 0)
    for($sampleNumber=0;$sampleNumber -lt 2 -and $decision.Reason -eq 'confirming-pressure';$sampleNumber++){
        Start-Sleep -Seconds 5
        $memory=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $availableMemoryGB=[Math]::Round($memory.AvailableMBytes/1024,1)
        $commitHeadroomGB=[Math]::Round(($memory.CommitLimit-$memory.CommittedBytes)/1GB,1)
        $unaccountedGB=Read-UnaccountedGB
        $space=Read-RamDiskSpace
        if($null -eq $space[0]){throw 'Disk query failed during pressure confirmation.'}
        $free=$space[0];$total=$space[1];$used=[Math]::Round($total-$free,1)
        $pressureReason=Get-RamdiskPressureReason -AvailableGB $availableMemoryGB -UsedGB $used -UnaccountedGB $unaccountedGB
        $consumerState=Get-RamdiskLeaseState -Directory (Join-Path $logDir 'leases')
        $decision=Resolve-RamdiskRecoveryDecision -State $decision.State -PressureReason $pressureReason -ActiveLeaseCount $consumerState.Active -LeaseEvidenceUnknown:($consumerState.Unknown -gt 0)
    }
    $recoveryState=$decision.State
    Write-RamdiskJson -Path $recoveryStatePath -Value $recoveryState
    $script:latestRecovery=@{Decision=$decision.Reason;Allowed=$decision.Allowed;ActiveConsumers=$consumerState.Active;UnknownConsumers=$consumerState.Unknown;LastOutcome=$recoveryState.LastOutcome;LastAttemptUtc=$recoveryState.LastAttemptUtc;SuppressUntilUtc=$recoveryState.SuppressUntilUtc}
    $releaseReason=if($decision.Allowed){$decision.Reason}else{$null}
    if($pressureReason -and -not $decision.Allowed){$warnings+="automatic recovery deferred: $($decision.Reason)"}
    $beforeAvailableMemoryGB=$availableMemoryGB;$beforeUnaccountedGB=$unaccountedGB
    if ($releaseReason) {
        try{
            $diskIndex=Resolve-PrimoDiskIndex
            $currentVolume=Get-Volume -DriveLetter $ramLetter -ErrorAction Stop
            if($diskIndex -ne $verifiedPrimoIndex -or $currentVolume.UniqueId -ne $ramVolume.UniqueId -or $currentVolume.FileSystemLabel -ine 'RAMDISK'){throw 'RAM disk identity changed before recovery.'}
            $consumerState=Get-RamdiskLeaseState -Directory (Join-Path $logDir 'leases')
            $control=Read-RamdiskJson -Path (Join-Path $logDir 'recovery-control.json') -Default @{Paused=$false}
            if($consumerState.Active -gt 0 -or $consumerState.Unknown -gt 0 -or $control.Paused -ne $false){throw 'A consumer or pause appeared before recovery.'}
            $recoveryState.LastAttemptUtc=[datetime]::UtcNow.ToString('o');$recoveryState.LastOutcome='attempting'
            Write-RamdiskJson -Path $recoveryStatePath -Value $recoveryState
            Log "EMERGENCY release: $releaseReason - reinitializing Primo disk #$diskIndex"
            Invoke-PrimoCommand @('init',[string]$diskIndex,'-s')|Out-Null
            Start-Sleep -Seconds 2
            $afterVolume=Get-Volume -DriveLetter $ramLetter -ErrorAction Stop
            if($afterVolume.FileSystemLabel -ine 'RAMDISK'){throw 'Recovered volume identity is not RAMDISK.'}
            foreach($dir in $dirs){if(-not (Test-Path -LiteralPath $dir)){[void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop)}}
            Copy-Item -LiteralPath $usageSource.FullName -Destination $usageTarget -Force -ErrorAction Stop
            if((Get-FileHash $usageSource.FullName).Hash -ne (Get-FileHash $usageTarget).Hash){throw 'Recovery guide hash mismatch.'}
            [void](New-Item -ItemType File -Path $marker -Force -ErrorAction Stop)
            (Get-Item -LiteralPath $marker -Force -ErrorAction Stop).Attributes='Hidden'
            Invoke-PrimoCommand @('save',[string]$diskIndex,'-s')|Out-Null
            $space=Read-RamDiskSpace
            if($null -eq $space[0]){throw 'Post-recovery disk query unavailable.'}
            $free=$space[0];$total=$space[1];$used=[Math]::Round($total-$free,1)
            $availableMemoryGB=$null;$commitHeadroomGB=$null
            try{
                $memory=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
                $availableMemoryGB=[Math]::Round($memory.AvailableMBytes/1024,1)
                $commitHeadroomGB=[Math]::Round(($memory.CommitLimit-$memory.CommittedBytes)/1GB,1)
            }catch{$warnings+='post-recovery memory query unavailable'}
            $unaccountedGB=Read-UnaccountedGB
            $benefit=Get-RamdiskRecoveryBenefit -BeforeAvailableGB $beforeAvailableMemoryGB -AfterAvailableGB $availableMemoryGB -BeforeUnaccountedGB $beforeUnaccountedGB -AfterUnaccountedGB $unaccountedGB
            $recoveryState.LastOutcome=$benefit.State
            if($benefit.State -ne 'effective'){$recoveryState.SuppressUntilUtc=[datetime]::UtcNow.AddHours(6).ToString('o');$warnings+="memory relief $($benefit.State); repeated recovery suppressed for six hours"}
            Write-RamdiskJson -Path $recoveryStatePath -Value $recoveryState
            $script:latestRecovery=@{Decision=$decision.Reason;Allowed=$true;LastOutcome=$benefit.State;LastAttemptUtc=$recoveryState.LastAttemptUtc;SuppressUntilUtc=$recoveryState.SuppressUntilUtc;VolumeRebuilt=$true}
            Log "EMERGENCY release done: memory relief=$($benefit.State), $Z use $used GB"
            $warnings+='RAM disk was auto-reinitialized after confirmed pressure'
        }catch{
            $failure=$_.Exception.Message
            $recoveryState.LastOutcome='failed';$recoveryState.SuppressUntilUtc=[datetime]::UtcNow.AddHours(1).ToString('o')
            Write-RamdiskJson -Path $recoveryStatePath -Value $recoveryState
            Set-Health 'ERROR' "RAM disk recovery failed: $failure"
            exit 1
        }
    }
    if($free -lt 2){$warnings+="low RAM-disk space: $free GB free"}
    if($used -gt $cacheSoftLimitGB){$warnings+="RAM-disk use $used GB exceeds $cacheSoftLimitGB GB cache soft limit"}
    if($null -ne $availableMemoryGB -and $availableMemoryGB -lt $minimumAvailableMemoryGB){$warnings+="host available memory $availableMemoryGB GB is below $minimumAvailableMemoryGB GB"}
    if($null -ne $commitHeadroomGB -and $commitHeadroomGB -lt $minimumCommitHeadroomGB){$warnings+="commit headroom $commitHeadroomGB GB is below $minimumCommitHeadroomGB GB"}
    if($null -ne $unaccountedGB -and $unaccountedGB -ge 4){$warnings+="unaccounted host memory $unaccountedGB GB exceeds 4 GB"}
    $script:latestMetrics=@{UsedGB=$used;FreeGB=$free;TotalGB=$total;AvailableMemoryGB=$availableMemoryGB;CommitHeadroomGB=$commitHeadroomGB;UnaccountedGB=$unaccountedGB}
    $detail="$Z present, $used GB used, $free GB free; host available $availableMemoryGB GB, commit headroom $commitHeadroomGB GB, unaccounted $unaccountedGB GB"
    if($warnings.Count){Set-Health 'WARN' (($warnings -join '; ')+'; '+$detail)}else{Set-Health 'OK' $detail}
    exit 0
}catch{
    $failure=$_.Exception.Message
    try{Set-Health 'ERROR' $failure}catch{}
    Write-Error -Message $failure -ErrorAction Continue
    exit 1
}finally{
    if($mutexTaken){$guardianMutex.ReleaseMutex()}
    $guardianMutex.Dispose()
}