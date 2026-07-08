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
$readme = Join-Path $RepoRoot 'README.md'

$guardianText = Get-Content -LiteralPath $guardian -Raw -Encoding utf8
$readmeText = Get-Content -LiteralPath $readme -Raw -Encoding utf8

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($guardian, [ref]$tokens, [ref]$errors) | Out-Null
Assert-Text 'zguardian.ps1 parses' ($errors.Count -eq 0)

Assert-Text 'backup destination space check is fail-fast before robocopy' (
    $guardianText -match 'Assert-BackupDestinationSpace' -and
    $guardianText -match 'Aborting before robocopy' -and
    $guardianText -notmatch '\$skipBackup'
)

Assert-Text 'backup destination space failure updates health output' (
    $guardianText -match '(?s)Set-Health\s+''ERROR''.*backup destination'
)

Assert-Text 'README call chain invokes zguardian directly from VBS' (
    $readmeText -match 'run_hidden\.vbs.*zguardian\.ps1' -and
    $readmeText -notmatch 'run_hidden\.vbs.*sync_code\.bat'
)

Assert-Text 'README active file list does not advertise sync_code.bat as entrypoint' (
    $readmeText -notmatch '(?m)^\s*├─ sync_code\.bat\s+入口'
)
