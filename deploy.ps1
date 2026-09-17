#requires -Version 7.0
<##
RamdiskGuardian deployment. Default is a read-only plan.
-Apply installs the existing task and verifies the guardian without recovery.
-TaskOnly changes only the task definition; it never modifies Windows power settings or Chrome.
-DisableFastStartup and -WireChromeCaches opt in to those independent changes.
Existing files, task XML and power settings are recorded for exact rollback.
##>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z]$')][string]$RamDrive='Z',
    [string]$User='', [ValidateRange(1,1440)][int]$IntervalMinutes=15,
    [switch]$Apply,[switch]$TaskOnly,[switch]$DisableFastStartup,[switch]$WireChromeCaches,
    [string]$PwshPath='C:\Program Files\PowerShell\7\pwsh.exe',
    [switch]$Json
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$RamDrive = $RamDrive.ToUpperInvariant()
$repo=$PSScriptRoot;$taskName='RAMDisk_Code_Backup'
Import-Module (Join-Path $repo 'ramdisk-guardian.psm1') -Force
if($TaskOnly -and ($DisableFastStartup -or $WireChromeCaches)){throw 'TaskOnly cannot include power or Chrome changes.'}
foreach($required in @($PwshPath,(Join-Path $repo 'zguardian.ps1'),(Join-Path $repo 'run_hidden.vbs'),(Join-Path $repo 'Get-RamdiskHealth.ps1'))){
    if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Missing deployment dependency: $required"}
}
$existingTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if(-not $User){
    if($existingTask){$User=[string]$existingTask.Principal.UserId}
    else{$User=[Security.Principal.WindowsIdentity]::GetCurrent().Name}
}
try {
    $sid=if($User -match '^S-1-') {[Security.Principal.SecurityIdentifier]::new($User)}else{[Security.Principal.NTAccount]::new($User).Translate([Security.Principal.SecurityIdentifier])}
    if($sid.Value -in @('S-1-5-18','S-1-5-19','S-1-5-20')){throw 'An interactive user must be supplied, not a service account.'}
    $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($sid.Value)'" -ErrorAction Stop
    if(-not $profile -or -not $profile.LocalPath){throw 'Interactive user profile not found.'}
}catch{throw "Cannot resolve the deployment user: $($_.Exception.Message)"}
$Z="${RamDrive}:"
$volume=Get-Volume -DriveLetter $RamDrive -ErrorAction SilentlyContinue
if($volume -and -not [string]::Equals([string]$volume.FileSystemLabel, 'RAMDISK', [StringComparison]::OrdinalIgnoreCase)){throw "Refusing to deploy against $Z because its volume label is not RAMDISK."}
if(-not $volume -and -not $TaskOnly){throw 'RAM disk is not mounted. Create it in Primo before applying a full deployment.'}
$ramDriveConfig=Join-Path $repo 'ramdrive.txt'
$currentDrive=if(Test-Path $ramDriveConfig){([IO.File]::ReadAllText($ramDriveConfig)).Trim().ToUpperInvariant()}else{'Z'}
if($TaskOnly -and $currentDrive -ne $RamDrive){throw 'TaskOnly cannot change the configured RAM disk. Use a full deployment.'}
$wscript=Join-Path $env:WINDIR 'System32\wscript.exe'
$launcher=Join-Path $repo 'run_hidden.vbs'
$taskArguments='//B //Nologo "{0}" "{1}"' -f $launcher,$PwshPath
$plan=[ordered]@{Schema='ramdisk.deployment.v1';Mode='Preflight';Applied=$false;Task=$taskName;TaskOnly=[bool]$TaskOnly;RamDrive=$RamDrive;IntervalMinutes=$IntervalMinutes;PowerChange=[bool]$DisableFastStartup;ChromeChange=[bool]$WireChromeCaches;Runtime=$PwshPath;RollbackPath=$null;Chrome='not-requested';Guardian='not-run';RequiresNaturalRebootAcceptance=$true}
if(-not $Apply -or -not $PSCmdlet.ShouldProcess('RamdiskGuardian selected deployment changes','Apply')){
    if($Json){[pscustomobject]$plan|ConvertTo-Json -Depth 6}else{[pscustomobject]$plan};return
}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Deployment requires an elevated PowerShell 7 process.'}
$mutex=[Threading.Mutex]::new($false,'Global\RamdiskGuardian-v2');$taken=$false
$backup=Join-Path $repo ('logs\deploy-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
$journal=@{Schema='ramdisk.deploy-preimage.v1';TaskExisted=($null -ne $existingTask);TaskEnabled=if($existingTask){$existingTask.Settings.Enabled}else{$false};OverrideExisted=(Test-Path $ramDriveConfig);PowerRequested=[bool]$DisableFastStartup;PowerExisted=$false;PowerValue=$null;Chrome=@()}
$taskChanged=$false;$overrideChanged=$false;$powerChanged=$false;$chromeMoves=[Collections.Generic.List[object]]::new()
function Restore-RamdiskDeployment {
    param([string]$failure)

    $rollbackFailures=[Collections.Generic.List[string]]::new()
    if($taskChanged){try{
        if($journal.TaskExisted){[void](Register-ScheduledTask -TaskName $taskName -Xml ([IO.File]::ReadAllText((Join-Path $backup 'task.xml'))) -Force)}
        else{Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
    }catch{$rollbackFailures.Add('task: '+$_.Exception.Message)}}
    for($i=$chromeMoves.Count-1;$i -ge 0;$i--){try{
        $move=$chromeMoves[$i]
        if($move.LinkCreated){[IO.Directory]::Delete($move.Path)}
        if($move.Existed){Move-Item -LiteralPath $move.Preimage -Destination $move.Path -ErrorAction Stop}
    }catch{$rollbackFailures.Add('chrome: '+$_.Exception.Message)}}
    if($powerChanged){try{if($journal.PowerExisted){Set-ItemProperty $powerPath -Name HiberbootEnabled -Value $journal.PowerValue -Type DWord}else{Remove-ItemProperty $powerPath -Name HiberbootEnabled -ErrorAction Stop}}catch{$rollbackFailures.Add('power: '+$_.Exception.Message)}}
    if($overrideChanged){try{if($journal.OverrideExisted){[IO.File]::Copy((Join-Path $backup 'ramdrive.txt'),$ramDriveConfig,$true)}elseif(Test-Path $ramDriveConfig){[IO.File]::Delete($ramDriveConfig)}}catch{$rollbackFailures.Add('override: '+$_.Exception.Message)}}
    throw "Deployment failed: $failure; rollback failures: $($rollbackFailures -join '; '); preimage: $backup"

}

try {
    try{$taken=$mutex.WaitOne([timespan]::FromSeconds(30))}catch [Threading.AbandonedMutexException]{$taken=$true}
    if(-not $taken){throw 'Guardian is active; deployment did not begin.'}
    [void][IO.Directory]::CreateDirectory($backup)
    if($existingTask){[IO.File]::WriteAllText((Join-Path $backup 'task.xml'),(Export-ScheduledTask -TaskName $taskName),[Text.UTF8Encoding]::new($false))}
    if($journal.OverrideExisted){[IO.File]::Copy($ramDriveConfig,(Join-Path $backup 'ramdrive.txt'))}
    $powerPath='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    if($DisableFastStartup){
        $power=Get-ItemProperty -LiteralPath $powerPath -Name HiberbootEnabled -ErrorAction SilentlyContinue
        $journal.PowerExisted=($null -ne $power)
        if($power){$journal.PowerValue=[int]$power.HiberbootEnabled}
    }
    Write-RamdiskJson -Path (Join-Path $backup 'preimage.json') -Value $journal
    if(-not $TaskOnly){
        $overrideChanged=$true
        if($RamDrive -ne 'Z'){Write-RamdiskTextAtomically -Path $ramDriveConfig -Text ($RamDrive+"`n")}
        elseif(Test-Path -LiteralPath $ramDriveConfig){Remove-Item -LiteralPath $ramDriveConfig -Force}
    }
    if($DisableFastStartup){
        $powerChanged=$true
        Set-ItemProperty -LiteralPath $powerPath -Name HiberbootEnabled -Value 0 -Type DWord -ErrorAction Stop
        if((Get-ItemProperty -LiteralPath $powerPath -Name HiberbootEnabled).HiberbootEnabled -ne 0){throw 'Fast Startup readback mismatch.'}
    }
    if($WireChromeCaches){
        $chromeProfile=Join-Path $profile.LocalPath 'AppData\Local\Google\Chrome\User Data\Default'
        if(Get-Process chrome -ErrorAction SilentlyContinue){$plan.Chrome='deferred-chrome-running'}
        elseif(-not(Test-Path $chromeProfile -PathType Container)){$plan.Chrome='profile-not-present'}
        else{
            $chromeDirs=@(@{FolderName='Cache';TargetName='ChromeCache'},@{FolderName='Code Cache';TargetName='ChromeCodeCache'},@{FolderName='GPUCache';TargetName='ChromeGPUCache'})
            foreach($cd in $chromeDirs){
                $target="$Z\Caches\$($cd.TargetName)";[void][IO.Directory]::CreateDirectory($target)
                $cache=Join-Path $chromeProfile $cd.FolderName
                $item=Get-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
                if($item -and $item.LinkType -eq 'Junction' -and [IO.Path]::GetFullPath([string]$item.Target) -ieq [IO.Path]::GetFullPath($target)){continue}
                # Preserve the exact old directory/link beside itself; never recursively delete user content.
                $preimage="$cache.ramdisk-preimage-"+[guid]::NewGuid().ToString('N')
                $move=[pscustomobject]@{Path=$cache;Preimage=$preimage;Existed=($null -ne $item);Target=$target;LinkCreated=$false}
                $journal.Chrome=@($chromeMoves)+@($move)
                Write-RamdiskJson -Path (Join-Path $backup 'preimage.json') -Value $journal
                if($item){Move-Item -LiteralPath $cache -Destination $preimage -ErrorAction Stop}
                $chromeMoves.Add($move)
                [void](New-Item -ItemType Junction -Path $cache -Target $target -ErrorAction Stop)
                $move.LinkCreated=$true
                $actual=Get-Item -LiteralPath $cache -Force -ErrorAction Stop
                if($actual.LinkType -ne 'Junction' -or [IO.Path]::GetFullPath([string]$actual.Target) -ine [IO.Path]::GetFullPath($target)){throw 'Chrome junction readback mismatch.'}
            }
            $plan.Chrome='verified'
        }
    }
    $action=New-ScheduledTaskAction -Execute $wscript -Argument $taskArguments -WorkingDirectory $repo
    $trigger=@(
        (New-ScheduledTaskTrigger -AtLogOn -User $sid.Value),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($IntervalMinutes) -RepetitionInterval ([timespan]::FromMinutes($IntervalMinutes)) -RepetitionDuration ([timespan]::FromDays(3650)))
    )

    $taskPrincipal=New-ScheduledTaskPrincipal -UserId $sid.Value -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::FromMinutes(10))
    $taskChanged=$true
    [void](Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Force)
    if($existingTask -and -not $journal.TaskEnabled){[void](Disable-ScheduledTask -TaskName $taskName)}
    $readback=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if($readback.Actions.Count -ne 1 -or $readback.Actions[0].Execute -ine $wscript -or $readback.Actions[0].Arguments -cne $taskArguments -or $readback.Principal.LogonType -ne 'Interactive' -or $readback.Settings.MultipleInstances -ne 'IgnoreNew'){throw 'Scheduled task readback mismatch.'}
    $journal.Chrome=@($chromeMoves);Write-RamdiskJson -Path (Join-Path $backup 'preimage.json') -Value $journal
    $plan.Mode='Apply';$plan.Applied=$true;$plan.RollbackPath=$backup
} catch { Restore-RamdiskDeployment -failure $_.Exception.Message } finally {if($taken){$mutex.ReleaseMutex()};$mutex.Dispose()}
# A separate child cannot inherit the deployment mutex. Release it before bounded initialization.
if(-not $TaskOnly){
    try {
    & $PwshPath -NoProfile -NonInteractive -File (Join-Path $repo 'zguardian.ps1') -NoRecovery -WaitSeconds 0
    if($LASTEXITCODE -ne 0){throw "Task installed, but guardian initialization failed. Retained rollback preimage: $backup"}
    $plan.Guardian='verified-without-reinitialization'
    } catch {
        $failure=$_.Exception.Message
        $rollbackMutex=[Threading.Mutex]::new($false,'Global\RamdiskGuardian-v2');$rollbackOwned=$false
        try {
            try{$rollbackOwned=$rollbackMutex.WaitOne([timespan]::FromSeconds(30))}catch [Threading.AbandonedMutexException]{$rollbackOwned=$true}
            if(-not $rollbackOwned){throw "Initialization failed: $failure; active guardian prevents safe deployment rollback; preimage retained at $backup"}
            Restore-RamdiskDeployment -failure $failure
        } finally {if($rollbackOwned){$rollbackMutex.ReleaseMutex()};$rollbackMutex.Dispose()}
    }
}
if($Json){[pscustomobject]$plan|ConvertTo-Json -Depth 6}else{[pscustomobject]$plan}