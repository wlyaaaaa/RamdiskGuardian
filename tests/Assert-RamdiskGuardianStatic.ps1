param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-Text {
    param([string]$Name, [bool]$Condition)
    if (-not $Condition) { throw "Assertion failed: $Name" }
    Write-Host "PASS: $Name"
}

$guardian = Join-Path $RepoRoot 'zguardian.ps1'
$deploy = Join-Path $RepoRoot 'deploy.ps1'
$readme = Join-Path $RepoRoot 'README.md'
$agents = Join-Path $RepoRoot 'AGENTS.md'
$launcher = Join-Path $RepoRoot 'run_hidden.vbs'
$usage = Join-Path $RepoRoot 'Z_使用说明.md'

$guardianText = Get-Content -LiteralPath $guardian -Raw -Encoding utf8
$deployText = Get-Content -LiteralPath $deploy -Raw -Encoding utf8
$readmeText = Get-Content -LiteralPath $readme -Raw -Encoding utf8
$agentsText = Get-Content -LiteralPath $agents -Raw -Encoding utf8
$launcherText = Get-Content -LiteralPath $launcher -Raw -Encoding utf8
$usageText = if (Test-Path -LiteralPath $usage) { Get-Content -LiteralPath $usage -Raw -Encoding utf8 } else { '' }

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($guardian, [ref]$tokens, [ref]$errors) | Out-Null
Assert-Text 'zguardian.ps1 parses' ($errors.Count -eq 0)
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($deploy, [ref]$tokens, [ref]$errors) | Out-Null
Assert-Text 'deploy.ps1 parses' ($errors.Count -eq 0)

Assert-Text 'retired legacy backup channels are absent from active guardian behavior' (
    $guardianText -notmatch 'robocopy' -and
    $guardianText -notmatch 'Z_Drive_Backup' -and
    $guardianText -notmatch '\$Z\\(?:projects|docs|others)'
)

Assert-Text 'deployer does not recreate the retired backup destination' (
    $deployText -notmatch 'Z_Drive_Backup' -and
    $deployText -notmatch 'robocopy'
)

Assert-Text 'hidden launcher invokes zguardian directly' (
    $launcherText -match 'zguardian\.ps1' -and
    $launcherText -notmatch 'sync_code\.bat'
)

Assert-Text 'README active file list does not advertise sync_code.bat as entrypoint' (
    $readmeText -notmatch '(?m)^\s*├─ sync_code\.bat\s+入口'
)

Assert-Text 'cache-first personal and work skeleton is created' (
    $guardianText -match '\$Z\\Caches\\Personal' -and
    $guardianText -match '\$Z\\Caches\\Work' -and
    $guardianText -match '\$Z\\Scratch\\Personal' -and
    $guardianText -match '\$Z\\Scratch\\Work'
)

Assert-Text 'canonical usage guide exists and guardian self-heals it to the RAM disk root' (
    (Test-Path -LiteralPath $usage) -and
    $guardianText -match 'Z_\*\.md' -and
    $guardianText -match 'Copy-Item' -and
    $guardianText -match 'Get-FileHash'
)

Assert-Text 'root usage guide reserves Z for cache and scratch only' (
    $usageText -match 'cache-only' -and
    $usageText -match 'V:\\Personal\\Projects' -and
    $usageText -match '不要.*Git.*仓库'
)

Assert-Text 'cache producers own bounded lifecycle cleanup' (
    $usageText -match '缓存生产者' -and
    $usageText -match '成功、失败或接管收口' -and
    $usageText -match '不.*整盘.*定时清空' -and
    $agentsText -match '不自动清理其他程序的未知缓存'
)

Assert-Text 'host memory and cache soft-limit health checks are present' (
    $guardianText -match 'Win32_PerfFormattedData_PerfOS_Memory' -and
    $guardianText -match '\$cacheSoftLimitGB\s*=\s*8' -and
    $guardianText -match '\$minimumAvailableMemoryGB\s*=\s*8' -and
    $guardianText -match '\$minimumCommitHeadroomGB\s*=\s*4'
)

Assert-Text 'guardian validates the configured drive and RAMDISK identity before writing to it' (
    $guardianText.Contains('invalid ramdrive.txt value; expected a single drive letter') -and
    $guardianText.Contains("[string]::Equals(`$ramVolumeLabel, 'RAMDISK', [StringComparison]::OrdinalIgnoreCase)") -and
    $guardianText.IndexOf("[string]::Equals(`$ramVolumeLabel, 'RAMDISK', [StringComparison]::OrdinalIgnoreCase)", [StringComparison]::Ordinal) -lt
        $guardianText.IndexOf('$dirs = @(', [StringComparison]::Ordinal)
)

Assert-Text 'deployer normalizes one-letter drive input and clears a stale custom override when returning to Z' (
    $deployText.Contains("[ValidatePattern('^[A-Za-z]$')]") -and
    $deployText.Contains('$RamDrive = $RamDrive.ToUpperInvariant()') -and
    $deployText.Contains("[string]::Equals([string]`$volume.FileSystemLabel, 'RAMDISK', [StringComparison]::OrdinalIgnoreCase)") -and
    $deployText.Contains('Remove-Item -LiteralPath $ramDriveConfig -Force')
)

Assert-Text 'WARN health is logged without an interactive notification' (
    $guardianText -match 'if \(\$health -eq ''ERROR'' -and \$health -ne \$last\)' -and
    $agentsText -match 'ERROR 变化才弹一次消息，WARN 保持静默'
)

Assert-Text 'project rules reserve Z for caches and defer machine policy to PCConfig' (
    $agentsText -match '只放可重建缓存' -and
    $agentsText -match 'dev_storage_policy\.md'
)
