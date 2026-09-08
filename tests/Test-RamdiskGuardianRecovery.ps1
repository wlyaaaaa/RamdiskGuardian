param(
    [string]$GuardianPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zguardian.ps1'),
    [string]$CaseName = ''
)

$ErrorActionPreference = 'Stop'
$temporaryBase = [IO.Path]::GetFullPath($env:TEMP)
$testRoot = Join-Path $temporaryBase ('ramdisk-recovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$engine = (Get-Process -Id $PID).Path
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($GuardianPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Guardian source does not parse.' }
$functions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Invoke-PrimoCommand', 'Resolve-PrimoDiskIndex')
}, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
$recovery = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Clauses.Count -eq 1 -and $node.Clauses[0].Item1.Extent.Text -eq '$releaseReason'
}, $true))
if ($recovery.Count -ne 1) { throw 'Expected one production recovery branch.' }

$fakePrimo = @'
param([string]$Operation, [string]$Index, [switch]$s)
$fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixture.json') -Raw | ConvertFrom-Json
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'calls.txt') -Value "$Operation $Index"
if ($Operation -eq 'ls') {
    $fixture.Listing | Write-Output
    exit $fixture.ListExit
}
if ($Operation -eq 'init') { exit $fixture.InitExit }
if ($Operation -eq 'save') { exit $fixture.SaveExit }
exit 2
'@
$runner = @'
param([string]$CaseRoot)
$ErrorActionPreference = 'SilentlyContinue'
$fixture = Get-Content -LiteralPath (Join-Path $CaseRoot 'fixture.json') -Raw | ConvertFrom-Json
$rxprd = Join-Path $CaseRoot 'primo.cmd'
if ($fixture.MissingExecutable) { $rxprd = Join-Path $CaseRoot 'missing-primo.exe' }
$ramLetter = $fixture.Drive
$Z = "${ramLetter}:"
$releaseReason = 'isolated threshold fixture'
$cacheSoftLimitGB = 8
$used = 1
$free = 11
$total = 12
$warnings = @()
$availableMemoryGB = 4
$commitHeadroomGB = 8
$unaccountedGB = 0
$dirs = @((Join-Path $CaseRoot 'disk\Caches'), (Join-Path $CaseRoot 'disk\Scratch'))
$usageSource = Get-Item -LiteralPath (Join-Path $CaseRoot 'guide.md')
$usageTarget = Join-Path $CaseRoot 'disk\guide.md'
if ($fixture.CopyFailure) { $usageTarget = Join-Path $CaseRoot 'missing-parent\guide.md' }
$marker = Join-Path $CaseRoot 'disk\.ramdisk_ready'
function Log($message) { Add-Content -LiteralPath (Join-Path $CaseRoot 'log.txt') -Value $message }
function Set-Health($health, $detail) {
    Set-Content -LiteralPath (Join-Path $CaseRoot 'health.txt') -Value "$health $detail"
}
function Start-Sleep {}
function Read-RamDiskSpace { return @(11, 12) }
function Read-UnaccountedGB { return -4 }
function Get-CimInstance {
    [pscustomobject]@{AvailableMBytes=16384; CommitLimit=64GB; CommittedBytes=32GB}
}
. ([scriptblock]::Create((Get-Content -LiteralPath (Join-Path $CaseRoot 'production-functions.ps1') -Raw)))
& ([scriptblock]::Create((Get-Content -LiteralPath (Join-Path $CaseRoot 'production-recovery.ps1') -Raw)))
exit 0
'@

$cases = @(
    @{Name='current Z succeeds'; Drive='Z'; Listing=@('#0 12288 SCSI Yes Good Z:'); ExpectedIndex=0},
    @{Name='custom drive uses its actual disk index'; Drive='R'; Listing=@('#0 12288 SCSI Yes Good Z:', '#2 12288 SCSI Yes Good R:'); ExpectedIndex=2},
    @{Name='init failure never saves or reports done'; Drive='Z'; Listing=@('#0 12288 SCSI Yes Good Z:'); InitExit=3; ExpectedCalls=@('ls', 'init 0')},
    @{Name='save failure reports ERROR rather than done'; Drive='Z'; Listing=@('#0 12288 SCSI Yes Good Z:'); SaveExit=3; ExpectedCalls=@('ls', 'init 0', 'save 0')},
    @{Name='directory or guide restore failure never saves'; Drive='Z'; Listing=@('#0 12288 SCSI Yes Good Z:'); CopyFailure=$true; ExpectedCalls=@('ls', 'init 0')},
    @{Name='missing target never initializes any disk'; Drive='R'; Listing=@('#0 12288 SCSI Yes Good Z:'); ExpectedCalls=@('ls')},
    @{Name='duplicate target never initializes any disk'; Drive='Z'; Listing=@('#0 12288 SCSI Yes Good Z:', '#1 12288 SCSI Yes Good Z:'); ExpectedCalls=@('ls')},
    @{Name='multi-volume disk never initializes another volume'; Drive='Z'; Listing=@('#0 12288 SCSI Yes Good Z: Y:'); ExpectedCalls=@('ls')},
    @{Name='Primo list failure never initializes any disk'; Drive='Z'; Listing=@('#0 12288 SCSI Yes Good Z:'); ListExit=3; ExpectedCalls=@('ls')},
    @{Name='missing Primo executable reports ERROR'; Drive='Z'; Listing=@('#0 12288 SCSI Yes Good Z:'); MissingExecutable=$true; ExpectedCalls=@()}
)

if ($CaseName) {
    $cases = @($cases | Where-Object { $_.Name -eq $CaseName })
    if ($cases.Count -ne 1) { throw 'Unknown isolated scenario.' }
}

try {
    $number = 0
    foreach ($case in $cases) {
        $number++
        $caseRoot = Join-Path $testRoot ([string]$number)
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $fixture = @{Drive=$case.Drive; Listing=$case.Listing; ListExit=0; InitExit=0; SaveExit=0; CopyFailure=$false; MissingExecutable=$false}
        foreach ($key in @('ListExit', 'InitExit', 'SaveExit', 'CopyFailure', 'MissingExecutable')) {
            if ($case.ContainsKey($key)) { $fixture[$key] = $case[$key] }
        }
        $fixture | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $caseRoot 'fixture.json') -Encoding utf8
        Set-Content -LiteralPath (Join-Path $caseRoot 'primo-implementation.ps1') -Value $fakePrimo -Encoding utf8
        $nativeStub = '@echo off' + "`r`n" + '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0primo-implementation.ps1" %*' + "`r`n" + 'exit /b %errorlevel%'
        Set-Content -LiteralPath (Join-Path $caseRoot 'primo.cmd') -Value $nativeStub -Encoding ascii
        Set-Content -LiteralPath (Join-Path $caseRoot 'runner.ps1') -Value $runner -Encoding utf8
        Set-Content -LiteralPath (Join-Path $caseRoot 'production-functions.ps1') -Value $functions -Encoding utf8
        Set-Content -LiteralPath (Join-Path $caseRoot 'production-recovery.ps1') -Value $recovery[0].Extent.Text -Encoding utf8
        Set-Content -LiteralPath (Join-Path $caseRoot 'guide.md') -Value 'cache-only test fixture' -Encoding utf8
        & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $caseRoot 'runner.ps1') -CaseRoot $caseRoot
        $exitCode = $LASTEXITCODE
        $calls = @(if (Test-Path -LiteralPath (Join-Path $caseRoot 'calls.txt')) { Get-Content -LiteralPath (Join-Path $caseRoot 'calls.txt') | ForEach-Object { $_.Trim() } })
        $log = if (Test-Path -LiteralPath (Join-Path $caseRoot 'log.txt')) { Get-Content -LiteralPath (Join-Path $caseRoot 'log.txt') -Raw } else { '' }
        $health = if (Test-Path -LiteralPath (Join-Path $caseRoot 'health.txt')) { Get-Content -LiteralPath (Join-Path $caseRoot 'health.txt') -Raw } else { '' }
        if ($case.ContainsKey('ExpectedIndex')) {
            $expected = @('ls', "init $($case.ExpectedIndex)", "save $($case.ExpectedIndex)")
            if ($exitCode -ne 0 -or $health -match '^ERROR' -or $log -notmatch 'EMERGENCY release done') {
                throw "$($case.Name): successful recovery was not reported (exit=$exitCode, health=$health)."
            }
            foreach ($relative in @('disk\Caches', 'disk\Scratch', 'disk\guide.md', 'disk\.ramdisk_ready')) {
                if (-not (Test-Path -LiteralPath (Join-Path $caseRoot $relative))) { throw "$($case.Name): missing restored $relative" }
            }
            if ((Get-FileHash (Join-Path $caseRoot 'guide.md')).Hash -ne (Get-FileHash (Join-Path $caseRoot 'disk\guide.md')).Hash) {
                throw "$($case.Name): restored guide differs."
            }
        } else {
            $expected = $case.ExpectedCalls
            if ($exitCode -eq 0 -or $health -notmatch '^ERROR' -or $log -match 'EMERGENCY release done') {
                throw "$($case.Name): failure was falsely reported as completed (exit=$exitCode, health=$health)."
            }
        }
        if (($calls -join '|') -ne ($expected -join '|')) { throw "$($case.Name): wrong command sequence: $($calls -join ', ')" }
        Write-Host "PASS: $($case.Name)"
    }
    Write-Host "PASS: $number isolated production-recovery scenarios; no real RAM disk or Primo mutation."
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $parentPrefix = $temporaryBase.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside test temp base.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
