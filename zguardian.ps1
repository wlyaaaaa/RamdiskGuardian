# =====================================================================
#  Z: RamDisk Guardian   (lives in the E:\RamdiskGuardian git repo)
#  Run by Task "RAMDisk_Code_Backup" at logon + every 15 min,
#  in the interactive session (user 10979, highest privilege).
#
#  Driven by a hidden marker  Z:\.ramdisk_ready :
#    marker MISSING  -> disk is brand-new / just dropped & recreated:
#        rebuild skeleton + cache dirs, RESTORE projects/docs/others
#        from E:\Z_Drive_Backup, then write the marker.   (auto-recover)
#    marker PRESENT  -> disk already initialised this boot:
#        ensure cache dirs, then BACK UP projects/docs/others to
#        E:\Z_Drive_Backup (mirror, but NEVER mirror a fileless source,
#        so a drop can't wipe the backup; honours deliberate deletes).
#
#  Health surfacing (so you always know when something is wrong):
#    - logs\STATUS.txt   : one line, latest health (OK / WARN / ERROR)
#    - logs\guardian.log : full history
#    - logs\alerts.log   : only problems
#    - a popup (msg.exe)  : fires once when health turns WARN/ERROR
#  ASCII-only on purpose (cmd/PowerShell code-page safe).
# =====================================================================
$ErrorActionPreference = 'SilentlyContinue'
$root   = 'E:\RamdiskGuardian'
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log    = Join-Path $logDir 'guardian.log'
$statusF= Join-Path $logDir 'STATUS.txt'
$alertF = Join-Path $logDir 'alerts.log'
$lastF  = Join-Path $logDir '.lasthealth'
$backupRoot = 'E:\Z_Drive_Backup'
$names  = @('projects','docs','others')

function Log($m){ ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Out-File -FilePath $log -Append -Encoding utf8 }
function Set-Health([string]$health,[string]$detail){
    $line = "{0}  {1}  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $health, $detail
    Set-Content -Path $statusF -Value $line -Encoding utf8
    $last = (Get-Content $lastF -EA SilentlyContinue | Select-Object -First 1)
    if ($health -ne 'OK' -and $health -ne $last) {
        $line | Out-File -FilePath $alertF -Append -Encoding utf8
        try { & "$env:WINDIR\System32\msg.exe" * "/TIME:60" "RamDisk(Z:) $health - $detail" } catch {}
    }
    Set-Content -Path $lastF -Value $health -Encoding utf8
}

if ((Test-Path $log) -and ((Get-Item $log).Length -gt 1MB)) { Move-Item $log "$log.1" -Force }
Log '--- guardian run ---'

# wait up to 60s for Z: to appear
$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-Path 'Z:\') -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
if (-not (Test-Path 'Z:\')) {
    Log '[ABORT] Z: not present after 60s - backup untouched'
    Set-Health 'ERROR' 'disk Z: is MISSING - check Primo / reboot'
    exit 0
}

# ensure skeleton + cache dirs (idempotent)
$dirs = @('Z:\projects','Z:\docs','Z:\others','Z:\Caches','Z:\Caches\ChromeCache','Z:\Caches\360zip_temp','Z:\TEMP')
foreach ($d in $dirs) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; Log "mkdir $d" } }

$marker = 'Z:\.ramdisk_ready'
if (-not (Test-Path $marker)) {
    Log '=== FRESH/empty disk -> RESTORE from backup ==='
    foreach ($n in $names) {
        $src = Join-Path $backupRoot $n; $dst = "Z:\$n"
        $bk = (Test-Path $src) -and ((@(Get-ChildItem $src -Recurse -File -Force)).Count -gt 0)
        if ($bk) { Log "restore $src -> $dst"; robocopy $src $dst /E /R:0 /W:0 /MT:16 *> $null }
        else     { Log "backup empty, nothing to restore for $dst" }
    }
    New-Item -ItemType File -Path $marker -Force | Out-Null
    try { (Get-Item $marker -Force).Attributes = 'Hidden' } catch {}
    Log '=== restore done, marker written ==='
}
else {
    Log '=== normal run -> BACK UP Z: to E: ==='
    foreach ($n in $names) {
        $src = "Z:\$n"; $dst = Join-Path $backupRoot $n
        $hasFiles = (@(Get-ChildItem $src -Recurse -File -Force)).Count -gt 0
        if (-not $hasFiles) { Log "[SKIP] $src has no files - backup preserved"; continue }
        if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
        $rc = @($src, $dst, '/MIR', '/R:0', '/W:0', '/MT:16')
        if ($n -eq 'projects') { $rc += @('/XD','target','venv','.venv','.idea','target-eclipse','bin','build') }
        Log "[SYNC] $src -> $dst"
        robocopy @rc *> $null
    }
    Log '=== backup done ==='
}

# health check: low space?
$free = [math]::Round((Get-Volume -DriveLetter Z).SizeRemaining/1GB, 1)
if ($free -lt 2) { Set-Health 'WARN' ("low space: {0} GB free on Z:" -f $free) }
else             { Set-Health 'OK'   ("Z: present, {0} GB free" -f $free) }
Log "health OK, free=${free}GB"
