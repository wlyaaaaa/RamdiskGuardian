# =====================================================================
#  Z: RamDisk Guardian (cache-only)
#  Run by the legacy-named task "RAMDisk_Code_Backup" at logon and every
#  15 minutes. The task name is retained for compatibility; no data backup
#  or restore is performed.
#
#  Responsibilities:
#    - wait for the RAM disk and report health
#    - rebuild the bounded cache/scratch directory skeleton
#    - restore the root usage guide from this repository
#    - monitor RAM-disk space, host memory, and commit headroom
#
#  Health: logs\STATUS.txt + guardian.log + alerts.log
#  ASCII-only source so Windows PowerShell has no source-encoding ambiguity.
# =====================================================================
$ErrorActionPreference = 'SilentlyContinue'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { $root = 'E:\Projects\Tools\RamdiskGuardian' }

$logDir = Join-Path $root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir 'guardian.log'
$statusF = Join-Path $logDir 'STATUS.txt'
$alertF = Join-Path $logDir 'alerts.log'
$lastF = Join-Path $logDir '.lasthealth'

$ramLetter = 'Z'
$rdf = Join-Path $root 'ramdrive.txt'
if (Test-Path -LiteralPath $rdf) {
    $configuredLetter = Get-Content -LiteralPath $rdf -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($configuredLetter) { $ramLetter = $configuredLetter.Trim() }
}
$Z = "${ramLetter}:"
$marker = "$Z\.ramdisk_ready"
$cacheSoftLimitGB = 8
$minimumAvailableMemoryGB = 8
$minimumCommitHeadroomGB = 4

function Log($message) {
    ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message) | Out-File -FilePath $log -Append -Encoding utf8
}

function Set-Health([string]$health, [string]$detail) {
    $line = "{0}  {1}  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $health, $detail
    Set-Content -LiteralPath $statusF -Value $line -Encoding utf8
    $last = Get-Content -LiteralPath $lastF -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($health -ne 'OK' -and $health -ne $last) {
        $line | Out-File -FilePath $alertF -Append -Encoding utf8
        try { & "$env:WINDIR\System32\msg.exe" * "/TIME:60" "RamDisk($Z) $health - $detail" } catch {}
    }
    Set-Content -LiteralPath $lastF -Value $health -Encoding utf8
    Log "health $health - $detail"
}

if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt 1MB)) {
    Move-Item -LiteralPath $log -Destination "$log.1" -Force
}
Log "--- guardian run (root=$root ram=$Z) ---"

$deadline = (Get-Date).AddSeconds(150)
while (-not (Test-Path -LiteralPath "$Z\") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
if (-not (Test-Path -LiteralPath "$Z\")) {
    Set-Health 'ERROR' "disk $Z is MISSING - check Primo / reboot"
    exit 0
}

$dirs = @(
    "$Z\Caches", "$Z\Caches\Personal", "$Z\Caches\Work",
    "$Z\Caches\ChromeCache", "$Z\Caches\ChromeCodeCache", "$Z\Caches\ChromeGPUCache",
    "$Z\Caches\360zip_temp", "$Z\Caches\WeFlow",
    "$Z\Scratch", "$Z\Scratch\Personal", "$Z\Scratch\Work",
    "$Z\TEMP"
)
foreach ($dir in $dirs) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Log "mkdir $dir"
    }
}

$usageSource = Get-ChildItem -LiteralPath $root -Filter 'Z_*.md' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $usageSource) {
    Set-Health 'ERROR' 'canonical root usage guide is missing from guardian repository'
    exit 0
}
$usageTarget = Join-Path "$Z\" $usageSource.Name.Substring(2)
$copyUsage = -not (Test-Path -LiteralPath $usageTarget)
if (-not $copyUsage) {
    try {
        $copyUsage = (Get-FileHash -LiteralPath $usageSource.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $usageTarget -Algorithm SHA256).Hash
    } catch {
        $copyUsage = $true
    }
}
if ($copyUsage) {
    try {
        Copy-Item -LiteralPath $usageSource.FullName -Destination $usageTarget -Force
        Log "refreshed root usage guide: $usageTarget"
    } catch {
        Set-Health 'ERROR' "failed to refresh root usage guide: $($_.Exception.Message)"
        exit 0
    }
}

if (-not (Test-Path -LiteralPath $marker)) {
    New-Item -ItemType File -Path $marker -Force | Out-Null
    try { (Get-Item -LiteralPath $marker -Force).Attributes = 'Hidden' } catch {}
    Log 'marker written'
}

$free = $null
$total = $null
for ($i = 0; $i -lt 3 -and $null -eq $free; $i++) {
    $volume = Get-Volume -DriveLetter $ramLetter -ErrorAction SilentlyContinue
    if ($volume -and $volume.SizeRemaining) {
        $free = [math]::Round($volume.SizeRemaining / 1GB, 1)
        $total = [math]::Round($volume.Size / 1GB, 1)
        break
    }
    try {
        $driveInfo = New-Object System.IO.DriveInfo($ramLetter)
        if ($driveInfo.IsReady) {
            $free = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 1)
            $total = [math]::Round($driveInfo.TotalSize / 1GB, 1)
            break
        }
    } catch {}
    Start-Sleep -Milliseconds 500
}

if ($null -eq $free) {
    Set-Health 'WARN' "$Z present but volume query failed"
    exit 0
}

$warnings = @()
$used = if ($null -ne $total) { [math]::Round($total - $free, 1) } else { $null }
if ($free -lt 2) { $warnings += "low RAM-disk space: $free GB free" }
if ($null -ne $used -and $used -gt $cacheSoftLimitGB) {
    $warnings += "RAM-disk use $used GB exceeds $cacheSoftLimitGB GB cache soft limit"
}

$memoryDetail = 'host memory unavailable'
try {
    $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    $availableMemoryGB = [math]::Round($memory.AvailableMBytes / 1024, 1)
    $commitHeadroomGB = [math]::Round(($memory.CommitLimit - $memory.CommittedBytes) / 1GB, 1)
    $memoryDetail = "host available $availableMemoryGB GB, commit headroom $commitHeadroomGB GB"
    if ($availableMemoryGB -lt $minimumAvailableMemoryGB) {
        $warnings += "host available memory $availableMemoryGB GB is below $minimumAvailableMemoryGB GB"
    }
    if ($commitHeadroomGB -lt $minimumCommitHeadroomGB) {
        $warnings += "commit headroom $commitHeadroomGB GB is below $minimumCommitHeadroomGB GB"
    }
} catch {
    $warnings += 'host memory query failed'
}

$diskDetail = if ($null -ne $used) { "$Z present, $used GB used, $free GB free" } else { "$Z present, $free GB free" }
if ($warnings.Count -gt 0) {
    Set-Health 'WARN' (($warnings -join '; ') + "; $diskDetail; $memoryDetail")
} else {
    Set-Health 'OK' "$diskDetail; $memoryDetail"
}
