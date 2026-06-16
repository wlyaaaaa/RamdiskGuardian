# =====================================================================
#  OpenClaw Gateway Heartbeat Watchdog
#  Checks if port 18789 is alive. If not, restarts the OpenClaw Gateway task.
#  Log output: E:\RamdiskGuardian\logs\openclaw_heartbeat.log
# =====================================================================
$ErrorActionPreference = 'SilentlyContinue'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $root) { $root = 'E:\RamdiskGuardian' }
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'openclaw_heartbeat.log'

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    $line | Out-File -FilePath $logFile -Append -Encoding utf8
    Write-Host $line
}

$port = 18789
$taskName = "OpenClaw Gateway"

# Check if port is listening
Log "Testing TCP connection to 127.0.0.1 on port $port..."
$connection = Test-NetConnection -ComputerName "127.0.0.1" -Port $port -WarningAction SilentlyContinue

if ($connection.TcpTestSucceeded -eq $true) {
    Log "[OK] Port $port is active. Gateway is healthy."
} else {
    Log "[WARN] Port $port is unresponsive! Attempting to restart '$taskName' scheduled task..."
    
    # Retrieve scheduled task status
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        # Stopping task if running
        Log "Stopping '$taskName'..."
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        
        # Starting task
        Log "Starting '$taskName'..."
        Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        # Verify if started
        $connectionRetry = Test-NetConnection -ComputerName "127.0.0.1" -Port $port -WarningAction SilentlyContinue
        if ($connectionRetry.TcpTestSucceeded -eq $true) {
            Log "[OK] Gateway successfully restarted and port $port is active."
        } else {
            Log "[ERROR] Gateway task started, but port $port is still unresponsive."
        }
    } else {
        Log "[ERROR] Scheduled task '$taskName' not found! Cannot perform auto-heal."
    }
}
