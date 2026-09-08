<#
  RamdiskGuardian one-shot deployer  (run in an ELEVATED PowerShell)

  Prereqs (do these FIRST - see DEPLOY.md):
    1) Primo Ramdisk installed + licensed.
    2) The RAM disk created in Primo: NON-temporary, dynamic memory,
       NTFS, label RAMDISK, "enable image" on. (no CLI -> manual, 1 min)
    3) This repo present (you are running it from inside the repo).

  What this does (all idempotent / re-runnable):
    - disables Windows Fast Startup
    - creates .\logs
    - registers the legacy-named Task "RAMDisk_Code_Backup" (logon + every N min)
    - runs the guardian once (builds the cache-only Z: skeleton and root guide)
    - (re)creates the Chrome cache junction -> <Z>\Caches\ChromeCache

  Usage:
    powershell -ExecutionPolicy Bypass -File .\deploy.ps1
    powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -RamDrive R -IntervalMinutes 10
#>
param(
    [ValidatePattern('^[A-Za-z]$')]
    [string]$RamDrive        = 'Z',
    [string]$User            = $env:USERNAME,
    [int]   $IntervalMinutes = 15
)
$ErrorActionPreference = 'Stop'
$RamDrive = $RamDrive.ToUpperInvariant()
function Say($m){ Write-Host ("[deploy] " + $m) }
function Warn($m){ Write-Host ("[deploy] WARNING: " + $m) -ForegroundColor Yellow }

# 0) must be elevated
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw 'Run this in an ELEVATED PowerShell (Run as administrator).'
}

$repo = $PSScriptRoot
if (-not (Test-Path (Join-Path $repo 'zguardian.ps1'))) { throw "zguardian.ps1 not found next to deploy.ps1 ($repo)." }
$Z         = "${RamDrive}:"
Say "repo=$repo  ramDisk=$Z  user=$User  interval=${IntervalMinutes}m"

# Refuse to deploy against an existing volume unless it is the RAM disk
# defined by this product's setup contract.
if (Test-Path -LiteralPath "$Z\") {
    $ramVolume = Get-Volume -DriveLetter $RamDrive -ErrorAction Stop
    if (-not [string]::Equals([string]$ramVolume.FileSystemLabel, 'RAMDISK', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to deploy against $Z because its volume label is not RAMDISK."
    }
}

# 1) record non-default RAM drive letter for the guardian
$ramDriveConfig = Join-Path $repo 'ramdrive.txt'
if ($RamDrive -ne 'Z') {
    Set-Content -LiteralPath $ramDriveConfig -Value $RamDrive -Encoding ascii
    Say "wrote ramdrive.txt = $RamDrive"
} elseif (Test-Path -LiteralPath $ramDriveConfig) {
    Remove-Item -LiteralPath $ramDriveConfig -Force
    Say 'removed stale ramdrive.txt; guardian will use Z'
}

# 2) disable Windows Fast Startup (clean cold boot -> reliable Primo recreate)
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
Say 'Fast Startup disabled (HiberbootEnabled=0)'

# 3) folders
New-Item -ItemType Directory -Force (Join-Path $repo 'logs') | Out-Null
Say "ensured: $repo\logs"

# 4) scheduled task: logon + every N min, interactive session, highest, no overlap
$act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + (Join-Path $repo 'run_hidden.vbs') + '"')
$trg = New-ScheduledTaskTrigger -AtLogOn -User $User
$rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration ([TimeSpan]::FromDays(3650))).Repetition
$trg.Repetition = $rep
$prn = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'RAMDisk_Code_Backup' -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
Say 'Task RAMDisk_Code_Backup registered'

# 5) if the RAM disk is up, build skeleton + wire Chrome; else tell user to create it
if (-not (Test-Path "$Z\")) {
    Warn "$Z is not present yet. Create the disk in Primo (see DEPLOY.md), then re-run this script."
    Say 'Partial deploy done. Create the disk, re-run deploy.ps1.'
    return
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'zguardian.ps1')
if ($LASTEXITCODE -ne 0) { throw "Guardian failed (exit $LASTEXITCODE). Read logs\STATUS.txt before continuing deployment." }
Say 'guardian completed; inspect logs\STATUS.txt for health and resource warnings'

# 6) Chrome Cache, Code Cache, and GPUCache junctions -> <Z>\Caches  (only if Chrome profile exists)
$prof = "C:\Users\$User\AppData\Local\Google\Chrome\User Data\Default"
if (Test-Path $prof) {
    if (Get-Process chrome -ErrorAction SilentlyContinue) {
        Warn 'Chrome is running - skipping cache junctions. Close Chrome and re-run, or do it manually (see DEPLOY.md).'
    } else {
        $chromeDirs = @(
            @{ FolderName = 'Cache'; TargetName = 'ChromeCache' },
            @{ FolderName = 'Code Cache'; TargetName = 'ChromeCodeCache' },
            @{ FolderName = 'GPUCache'; TargetName = 'ChromeGPUCache' }
        )

        foreach ($cd in $chromeDirs) {
            $folderName = $cd.FolderName
            $targetName = $cd.TargetName
            $target     = "$Z\Caches\$targetName"
            New-Item -ItemType Directory -Force $target | Out-Null

            $cache  = Join-Path $prof $folderName
            $isLink = (Test-Path $cache) -and ((Get-Item $cache -Force).Attributes -match 'ReparsePoint')

            $needsRecreate = $false
            if ($isLink) {
                $currentTarget = (Get-Item $cache -Force).Target
                if ($currentTarget -ne $target) {
                    $needsRecreate = $true
                    Say "Junction target for '$folderName' changed from '$currentTarget' to '$target'. Recreating..."
                }
            }

            if (((Test-Path $cache) -and -not $isLink) -or $needsRecreate) {
                cmd /c ('rmdir /s /q "' + $cache + '"') 2>$null
            }
            if (-not (Test-Path $cache) -or $needsRecreate) {
                cmd /c ('mklink /J "' + $cache + '" "' + $target + '"') | Out-Null
            }
            Say "Chrome $folderName junction -> $target"
        }
    }
}

# 7) 360 zip - manual (its ini is UTF-16 and fiddly to patch safely)
Say "360 Zip: in 360 settings set Extract-temp-dir to  $Z\Caches\360zip_temp  (already created)"

Say 'DONE. At the next natural reboot, confirm Z: comes back automatically (12 GiB).'
Say ("Health any time:  Get-Content " + (Join-Path $repo 'logs\STATUS.txt'))
