# =====================================================================
#  Z: RamDisk Guardian   (portable - lives in the RamdiskGuardian repo)
#  Run by Task "RAMDisk_Code_Backup" at logon + every 15 min,
#  in the interactive session (highest privilege).
#
#  PORTABLE PATHS (so it survives reinstall / new PC / moved repo):
#    - repo root       = the folder this script sits in ($PSScriptRoot)
#    - data drive      = the drive the repo is on (e.g. E:)
#    - backup folder   = <dataDrive>\Z_Drive_Backup
#    - RAM disk letter = 'Z' by default; override by putting a single
#                        letter (e.g. R) in  <repo>\ramdrive.txt
#
#  Driven by a hidden marker  <Z>:\.ramdisk_ready :
#    marker MISSING  -> fresh / just-dropped disk: rebuild skeleton +
#        cache dirs, RESTORE projects/docs/others from backup, write marker.
#    marker PRESENT  -> already initialised: ensure cache dirs, then
#        BACK UP projects/docs/others.
#
#  BACKUP is APPEND-ONLY & NEWER-WINS (robocopy /E /XO, no /PURGE):
#    never deletes from the backup and never overwrites a newer backup
#    file with an older disk file -> a drop or a stale post-crash image
#    can NEVER shrink/downgrade the backup. (Deleted files linger in the
#    backup by design - the deliberate trade for "never lose data".)
#
#  Health: logs\STATUS.txt (OK/WARN/ERROR) + logs\guardian.log +
#          logs\alerts.log + a one-shot msg.exe popup on WARN/ERROR.
#  ASCII-only on purpose (cmd/PowerShell code-page safe).
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

if ((Test-Path $log) -and ((Get-Item $log).Length -gt 1MB)) { Move-Item $log "$log.1" -Force }
Log "--- guardian run (root=$root data=$dataDrive ram=$Z) ---"

# wait up to 150s for the RAM disk to appear (Primo loads its image at boot)
$deadline = (Get-Date).AddSeconds(150)
while (-not (Test-Path "$Z\") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
if (-not (Test-Path "$Z\")) {
    Set-Health 'ERROR' "disk $Z is MISSING - check Primo / reboot"
    exit 0
}

# ensure skeleton + cache dirs (idempotent)
$dirs = @("$Z\projects","$Z\docs","$Z\others","$Z\Caches","$Z\Caches\ChromeCache","$Z\Caches\360zip_temp","$Z\TEMP")
foreach ($d in $dirs) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; Log "mkdir $d" } }

if (-not (Test-Path $marker)) {
    Log '=== FRESH/empty disk -> RESTORE from backup ==='
    foreach ($n in $names) {
        $src = Join-Path $backupRoot $n; $dst = "$Z\$n"
        $bk = (Test-Path $src) -and ((@(Get-ChildItem $src -Recurse -File -Force)).Count -gt 0)
        if ($bk) { Log "restore $src -> $dst"; robocopy $src $dst /E /R:0 /W:0 /MT:16 *> $null }
        else     { Log "backup empty, nothing to restore for $dst" }
    }
    New-Item -ItemType File -Path $marker -Force | Out-Null
    try { (Get-Item $marker -Force).Attributes = 'Hidden' } catch {}
    Log '=== restore done, marker written ==='
}
else {
    Log '=== normal run -> BACK UP to backup (append-only /E /XO) ==='
    foreach ($n in $names) {
        $src = "$Z\$n"; $dst = Join-Path $backupRoot $n
        $hasFiles = (@(Get-ChildItem $src -Recurse -File -Force)).Count -gt 0
        if (-not $hasFiles) { Log "[SKIP] $src has no files - backup preserved"; continue }
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        $rc = @($src, $dst, '/E', '/XO', '/R:0', '/W:0', '/MT:16')
        if ($n -eq 'projects') { $rc += @('/XD','target','venv','.venv','.idea','target-eclipse','bin','build') }
        Log "[SYNC] $src -> $dst"
        robocopy @rc *> $null
    }
    Log '=== backup done ==='
}

# health check: low space?
$vol = Get-Volume -DriveLetter $ramLetter -ErrorAction SilentlyContinue
if ($vol) {
    $free = [math]::Round($vol.SizeRemaining/1GB, 1)
    if ($free -lt 2) { Set-Health 'WARN' ("low space: {0} GB free on {1}" -f $free, $Z) }
    else             { Set-Health 'OK'   ("$Z present, {0} GB free" -f $free) }
} else {
    Set-Health 'WARN' "$Z present but volume query failed"
}
