# =====================================================================
#  OpenClaw Gateway Auto-Update Helper Script
#  Upgrades OpenClaw globally, restarts the Gateway task, and tests connection.
#  Log output: E:\RamdiskGuardian\logs\openclaw_update.log
#  Must run in an elevated (Administrator) PowerShell.
# =====================================================================
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { $root = 'E:\RamdiskGuardian' }
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'openclaw_update.log'

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    $line | Out-File -FilePath $logFile -Append -Encoding utf8
    Write-Host $line
}

Log "═══════════════════════════════════════════════════════════"
Log "  OpenClaw Update Helper — Running"
Log "═══════════════════════════════════════════════════════════"

# Elevation check
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Log "[ERROR] This script MUST run as Administrator to update global npm packages and restart scheduled tasks."
    Write-Warning "Please re-run this script in an elevated PowerShell session (Run as Administrator)."
    exit 1
}

try {
    # 1. Update OpenClaw package
    Log "Running 'npm update -g openclaw'..."
    # Capture npm output
    $npmOutput = & npm update -g openclaw 2>&1
    Log "npm output: $npmOutput"
    Log "[OK] Global openclaw package updated."

    # 2. Restart scheduled task
    $taskName = "OpenClaw Gateway"
    Log "Locating scheduled task '$taskName'..."
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Log "Stopping '$taskName'..."
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3

        Log "Starting '$taskName'..."
        Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Log "[OK] Scheduled task '$taskName' restarted."
    } else {
        Log "[WARN] Scheduled task '$taskName' not found. Skip restarting."
    }

    # 3. Connection and health check
    $port = 18789
    Log "Testing TCP connection to port $port..."
    $connection = Test-NetConnection -ComputerName "127.0.0.1" -Port $port -WarningAction SilentlyContinue
    if ($connection.TcpTestSucceeded -eq $true) {
        Log "[OK] Health check passed! OpenClaw Gateway is up and listening on port $port."
    } else {
        Log "[ERROR] Health check FAILED! Port $port is unresponsive after update."
        Log "Check gateway logs at C:\Users\10979\.openclaw\gateway.log for errors."
    }
} catch {
    Log "[ERROR] Update failed: $_"
}

Log "Update run completed. Log saved to $logFile"
