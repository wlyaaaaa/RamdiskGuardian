# =====================================================================
#  Z: RamDisk Guardian   (portable - lives in the RamdiskGuardian repo)
#  Run by Task "RAMDisk_Code_Backup" at logon + every 15 min,
#  in the interactive session (highest privilege).
#
#  PORTABLE PATHS (survives reinstall / new PC / moved repo):
#    repo root = $PSScriptRoot ; data drive = drive of the repo ;
#    backup = <dataDrive>\Z_Drive_Backup ; RAM letter = 'Z' or repo\ramdrive.txt
#
#  WHEN DOES IT PULL FROM BACKUP (heal/restore)?  -> only when needed:
#    * marker  <Z>\.ramdisk_ready  MISSING  = disk is fresh / just dropped
#      & recreated mid-session  -> restore.
#    * FIRST run after a (re)boot = disk was just loaded from the Primo
#      image, which may be STALE vs the backup -> heal.
#    In both cases it pulls only files where the BACKUP is NEWER than the
#    disk (robocopy /E /XO), so a stale image is corrected automatically.
#    On every OTHER run it does NOT pull, so files you delete on Z are
#    respected (not resurrected).
#
#  BACKUP (every run, append-only & newer-wins, robocopy /E /XO, no /PURGE):
#    never deletes from the backup, never overwrites a newer backup file
#    with an older disk file. A drop / stale image can NEVER shrink or
#    downgrade the backup. (Deleted files linger in the backup by design.)
#
#  Health: logs\STATUS.txt (OK/WARN/ERROR) + guardian.log + alerts.log
#          + one-shot msg.exe popup on WARN/ERROR.  ASCII-only on purpose.
# =====================================================================
$ErrorActionPreference = 'SilentlyContinue'

# ---- portable locations -------------------------------------------------
$root = $PSScriptRoot; if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { $root = 'E:\RamdiskGuardian' }
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log    = Join-Path $logDir 'guardian.log'
$statusF= Join-Path $logDir 'STATUS.txt'
$alertF = Join-Path $logDir 'alerts.log'
$lastF  = Join-Path $logDir '.lasthealth'
$bootF  = Join-Path $logDir '.lastboot'

$dataDrive  = Split-Path $root -Qualifier            # e.g. 'E:'
$backupRoot = Join-Path "$dataDrive\" 'Z_Drive_Backup'

$ramLetter = 'Z'
$rdf = Join-Path $root 'ramdrive.txt'
if (Test-Path $rdf) { $t = (Get-Content $rdf -EA SilentlyContinue | Select-Object -First 1); if ($t) { $ramLetter = $t.Trim() } }
$Z = "${ramLetter}:"
$marker = "$Z\.ramdisk_ready"
$names  = @('projects','docs','others')

function Log($m){ ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Out-File -FilePath $log -Append -Encoding utf8 }
function Set-Health([string]$health,[string]$detail){
    $line = "{0}  {1}  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $health, $detail
    Set-Content -Path $statusF -Value $line -Encoding utf8
    $last = (Get-Content $lastF -EA SilentlyContinue | Select-Object -First 1)
    if ($health -ne 'OK' -and $health -ne $last) {
        $line | Out-File -FilePath $alertF -Append -Encoding utf8
        try { & "$env:WINDIR\System32\msg.exe" * "/TIME:60" "RamDisk($Z) $health - $detail" } catch {}
    }
    Set-Content -Path $lastF -Value $health -Encoding utf8
    Log "health $health - $detail"
}
function NewestUtc($p){
    if (-not (Test-Path $p)) { return [datetime]::MinValue }
    $f = Get-ChildItem $p -Recurse -File -Force -EA SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($f) { return $f.LastWriteTimeUtc } else { return [datetime]::MinValue }
}

if ((Test-Path $log) -and ((Get-Item $log).Length -gt 1MB)) { Move-Item $log "$log.1" -Force }
Log "--- guardian run (root=$root data=$dataDrive ram=$Z) ---"

# detect "first run since this boot" (the boot-loaded image may be stale)
$bootTicks = "0"
try { $bootTicks = "$(((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUniversalTime().Ticks)" } catch {}
$prevBoot  = (Get-Content $bootF -EA SilentlyContinue | Select-Object -First 1)
$firstRunThisBoot = ($bootTicks -ne "0") -and ($bootTicks -ne "$prevBoot")
if ($bootTicks -ne "0") { Set-Content -Path $bootF -Value $bootTicks -Encoding ascii }

# wait up to 150s for the RAM disk to appear (Primo loads its image at boot)
$deadline = (Get-Date).AddSeconds(150)
while (-not (Test-Path "$Z\") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
if (-not (Test-Path "$Z\")) {
    Set-Health 'ERROR' "disk $Z is MISSING - check Primo / reboot"
    exit 0
}

# ensure skeleton + cache dirs (idempotent)
$dirs = @("$Z\projects","$Z\docs","$Z\others","$Z\Caches","$Z\Caches\ChromeCache","$Z\Caches\ChromeCodeCache","$Z\Caches\ChromeGPUCache","$Z\Caches\360zip_temp","$Z\TEMP")
foreach ($d in $dirs) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; Log "mkdir $d" } }

$markerMissing = -not (Test-Path $marker)
$doHeal = $markerMissing -or $firstRunThisBoot   # pull newer-from-backup only in these cases
if ($doHeal) { Log "HEAL pass (markerMissing=$markerMissing firstRunThisBoot=$firstRunThisBoot)" }

foreach ($n in $names) {
    $src = "$Z\$n"; $dst = Join-Path $backupRoot $n   # NB: never name a var $z (collides with $Z - PS is case-insensitive)
    # 1) HEAL/RESTORE: pull files where the backup is NEWER than the disk
    if ($doHeal) {
        $sNew = NewestUtc $src; $dNew = NewestUtc $dst
        if ($dNew -gt $sNew) {
            Log "[HEAL] $dst -> $src (backup newer)"
            robocopy $dst $src /E /XO /R:0 /W:0 /MT:16 *> $null
        }
    }
    # 2) BACKUP: push live disk content -> backup (append-only, never downgrade/delete)
    if ((@(Get-ChildItem $src -Recurse -File -Force)).Count -gt 0) {
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        $rc = @($src, $dst, '/E', '/XO', '/R:0', '/W:0', '/MT:16')
        if ($n -eq 'projects') { $rc += @('/XD','target','venv','.venv','.idea','target-eclipse','bin','build') }
        Log "[SYNC] $src -> $dst"
        robocopy @rc *> $null
    } else {
        Log "[SKIP backup] $src has no files - backup preserved"
    }
}

# (re)assert the ready marker
if ($markerMissing) {
    New-Item -ItemType File -Path $marker -Force | Out-Null
    try { (Get-Item $marker -Force).Attributes = 'Hidden' } catch {}
    Log 'marker written'
}

# health check: low space?
# NB: Get-Volume on a Primo RAM disk intermittently returns nothing even
# though the disk is fine (storage-provider hiccup; the filesystem is OK).
# So retry, and fall back to .NET DriveInfo which reads free space straight
# from the filesystem. Only WARN if every attempt truly fails.
$free = $null
for ($i = 0; $i -lt 3 -and $null -eq $free; $i++) {
    $vol = Get-Volume -DriveLetter $ramLetter -ErrorAction SilentlyContinue
    if ($vol -and $vol.SizeRemaining) { $free = [math]::Round($vol.SizeRemaining/1GB, 1); break }
    try {
        $di = New-Object System.IO.DriveInfo($ramLetter)
        if ($di.IsReady) { $free = [math]::Round($di.AvailableFreeSpace/1GB, 1); break }
    } catch {}
    Start-Sleep -Milliseconds 500
}
if ($null -ne $free) {
    if ($free -lt 2) { Set-Health 'WARN' ("low space: {0} GB free on {1}" -f $free, $Z) }
    else             { Set-Health 'OK'   ("$Z present, {0} GB free" -f $free) }
} else {
    Set-Health 'WARN' "$Z present but volume query failed"
}
