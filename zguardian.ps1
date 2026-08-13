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
#    - watchdog for unaccounted host memory (stuck RAM-disk allocation)
#    - emergency auto-release of a stuck RAM-disk driver allocation
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
$emergencyAvailableMemoryGB = 5
$stuckWarnGB = 4
$stuckReleaseGB = 8
$rxprd = 'C:\Program Files\Primo Ramdisk\rxprd.exe'

function Log($message) {
    ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message) | Out-File -FilePath $log -Append -Encoding utf8
}

function Set-Health([string]$health, [string]$detail) {
    $line = "{0}  {1}  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $health, $detail
    Set-Content -LiteralPath $statusF -Value $line -Encoding utf8
    $last = Get-Content -LiteralPath $lastF -ErrorAction SilentlyContinue | Select-Object -First 1
    # WARN remains recorded for health inspection, but is intentionally silent.
    # Only an ERROR transition should interrupt the interactive user session.
    if ($health -eq 'ERROR' -and $health -ne $last) {
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

$space = Read-RamDiskSpace
$free = $space[0]
$total = $space[1]

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
$availableMemoryGB = $null
$commitHeadroomGB = $null
try {
    $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    $availableMemoryGB = [math]::Round($memory.AvailableMBytes / 1024, 1)
    $commitHeadroomGB = [math]::Round(($memory.CommitLimit - $memory.CommittedBytes) / 1GB, 1)
} catch {
    $warnings += 'host memory query failed'
}

# Unaccounted-memory watchdog: physical memory in use that belongs to no
# process, pool, cache or modified list. A RAM-disk driver allocation stuck
# at its high-water mark shows up here and nowhere else (incident
# 2026-07-23). Healthy baseline measured 2026-07-23 is about -4 GB because
# the _Total working-set counter double-counts shared pages; thresholds are
# set well above that noise floor.
$unaccountedGB = $null
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
$unaccountedGB = Read-UnaccountedGB

# Emergency auto-release: if the host is starving, or the watchdog sees a
# large unaccounted block, while the cache disk holds little data, the
# RAM-disk driver allocation map is stuck (DMM release failure). Wiping the
# cache-only disk returns all driver-held memory; content loss is harmless
# by contract and the skeleton plus usage guide are rebuilt below.
$releaseReason = $null
if ($null -ne $availableMemoryGB -and $null -ne $used -and
    $availableMemoryGB -lt $emergencyAvailableMemoryGB -and $used -le $cacheSoftLimitGB) {
    $releaseReason = "host available $availableMemoryGB GB < $emergencyAvailableMemoryGB GB"
} elseif ($null -ne $unaccountedGB -and $null -ne $used -and
    $unaccountedGB -ge $stuckReleaseGB -and $used -le $cacheSoftLimitGB) {
    $releaseReason = "unaccounted host memory $unaccountedGB GB >= $stuckReleaseGB GB (stuck RAM-disk allocation)"
}

if ($releaseReason) {
    Log "EMERGENCY release: $releaseReason with $Z use $used GB <= $cacheSoftLimitGB GB - reinitializing RAM disk"
    & $rxprd init 0 -s | Out-Null
    Start-Sleep -Seconds 2
    & $rxprd save 0 -s | Out-Null
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    try { Copy-Item -LiteralPath $usageSource.FullName -Destination $usageTarget -Force } catch {}
    New-Item -ItemType File -Path $marker -Force | Out-Null
    $space = Read-RamDiskSpace
    if ($null -ne $space[0]) {
        $free = $space[0]
        $total = $space[1]
        $used = if ($null -ne $total) { [math]::Round($total - $free, 1) } else { $null }
    }
    try {
        $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $availableMemoryGB = [math]::Round($memory.AvailableMBytes / 1024, 1)
        $commitHeadroomGB = [math]::Round(($memory.CommitLimit - $memory.CommittedBytes) / 1GB, 1)
    } catch {}
    $unaccountedGB = Read-UnaccountedGB
    Log "EMERGENCY release done: host available $availableMemoryGB GB, commit headroom $commitHeadroomGB GB, unaccounted $unaccountedGB GB, $Z use $used GB"
    $warnings += "RAM disk was auto-reinitialized to release stuck driver memory ($releaseReason)"
}

if ($null -ne $availableMemoryGB) {
    $memoryDetail = "host available $availableMemoryGB GB, commit headroom $commitHeadroomGB GB"
    if ($availableMemoryGB -lt $minimumAvailableMemoryGB) {
        $warnings += "host available memory $availableMemoryGB GB is below $minimumAvailableMemoryGB GB"
    }
    if ($commitHeadroomGB -lt $minimumCommitHeadroomGB) {
        $warnings += "commit headroom $commitHeadroomGB GB is below $minimumCommitHeadroomGB GB"
    }
}
if ($null -ne $unaccountedGB) {
    $memoryDetail = "$memoryDetail, unaccounted $unaccountedGB GB"
    if (-not $releaseReason -and $unaccountedGB -ge $stuckWarnGB) {
        $warnings += "unaccounted host memory $unaccountedGB GB exceeds $stuckWarnGB GB (healthy baseline about -4 GB; possible stuck RAM-disk allocation)"
    }
}

$diskDetail = if ($null -ne $used) { "$Z present, $used GB used, $free GB free" } else { "$Z present, $free GB free" }
if ($warnings.Count -gt 0) {
    Set-Health 'WARN' (($warnings -join '; ') + "; $diskDetail; $memoryDetail")
} else {
    Set-Health 'OK' "$diskDetail; $memoryDetail"
}
