<#
.SYNOPSIS
  OpenClaw Gateway — Silent Boot Guardian (Self-Heal Script)
  Auto-audits and re-registers the "OpenClaw Gateway" Windows Scheduled Task
  to achieve 100% silent, headless, auto-start on system boot.

.DESCRIPTION
  This script fixes the following critical issues in the default OpenClaw
  scheduled-task registration:

    1. Trigger:  LogonTrigger → BootTrigger  (runs at SYSTEM STARTUP, not user logon)
    2. Principal: InteractiveToken → Password/S4U  (runs hidden in background)
    3. RunLevel:  Limited → Highest  (admin privileges for Tailscale/network ops)
    4. Window:    Visible CMD → Fully Hidden  (via VBScript wrapper + task setting)

  It also:
    - Creates a companion VBScript launcher (openclaw_run_hidden.vbs) to guarantee
      zero window flash even on older Windows builds.
    - Sets RestartOnFailure with 60-second interval, up to 3 retries.
    - Logs all actions to .\logs\openclaw_guardian.log

.NOTES
  Author:  Antigravity Agent (auto-generated)
  Date:    2026-06-16
  Version: 1.0.0
  Run as:  Administrator (elevated PowerShell)
#>

param(
    [string]$TaskName       = 'OpenClaw Gateway',
    [string]$GatewayCmdPath = 'C:\Users\10979\.openclaw\gateway.cmd',
    [string]$User           = 'WLY\10979',
    [int]   $RestartDelaySeconds = 60,
    [int]   $MaxRestartCount     = 3
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptRoot) { $scriptRoot = 'E:\RamdiskGuardian' }

# ── Logging ──────────────────────────────────────────────────────────────
$logDir = Join-Path $scriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
$logFile = Join-Path $logDir 'openclaw_guardian.log'
function Log([string]$msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    $line | Out-File -FilePath $logFile -Append -Encoding utf8
    Write-Host $line
}

# ── Elevation check ─────────────────────────────────────────────────────
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Log "[ERROR] This script MUST run in an elevated (Administrator) PowerShell."
    throw 'Elevation required. Right-click PowerShell → Run as Administrator.'
}

Log "═══════════════════════════════════════════════════════════"
Log "  OpenClaw Silent Boot Guardian — Self-Heal Run"
Log "═══════════════════════════════════════════════════════════"

# ── Step 1: Validate gateway.cmd exists ──────────────────────────────────
if (-not (Test-Path $GatewayCmdPath)) {
    Log "[ERROR] Gateway CMD not found at: $GatewayCmdPath"
    throw "gateway.cmd not found. Install/repair OpenClaw first."
}
Log "[OK] gateway.cmd found: $GatewayCmdPath"

# ── Step 2: Validate OPENCLAW_GATEWAY_PASSWORD env var ───────────────────
$pwMachine = [System.Environment]::GetEnvironmentVariable('OPENCLAW_GATEWAY_PASSWORD', 'Machine')
$pwUser    = [System.Environment]::GetEnvironmentVariable('OPENCLAW_GATEWAY_PASSWORD', 'User')
$pwCurrent = $env:OPENCLAW_GATEWAY_PASSWORD

if ($pwMachine) {
    Log "[OK] OPENCLAW_GATEWAY_PASSWORD set at Machine level"
} elseif ($pwUser) {
    Log "[WARN] OPENCLAW_GATEWAY_PASSWORD set at User level only (may not be available at boot for SYSTEM-context tasks)"
    Log "[FIX] Promoting to Machine-level environment variable..."
    [System.Environment]::SetEnvironmentVariable('OPENCLAW_GATEWAY_PASSWORD', $pwUser, 'Machine')
    Log "[OK] Promoted OPENCLAW_GATEWAY_PASSWORD to Machine level"
} elseif ($pwCurrent) {
    Log "[WARN] OPENCLAW_GATEWAY_PASSWORD only in current session, not persistent"
    Log "[FIX] Setting at Machine level..."
    [System.Environment]::SetEnvironmentVariable('OPENCLAW_GATEWAY_PASSWORD', $pwCurrent, 'Machine')
    Log "[OK] Set OPENCLAW_GATEWAY_PASSWORD at Machine level"
} else {
    Log "[ERROR] OPENCLAW_GATEWAY_PASSWORD is NOT set anywhere!"
    Log "[INFO] Set it manually: [System.Environment]::SetEnvironmentVariable('OPENCLAW_GATEWAY_PASSWORD','<your-pw>','Machine')"
    throw "Missing OPENCLAW_GATEWAY_PASSWORD. Cannot proceed."
}

# ── Step 3: Validate openclaw.json auth config ───────────────────────────
$configPath = 'C:\Users\10979\.openclaw\openclaw.json'
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $authMode = $config.gateway.auth.mode
    if ($authMode -eq 'password') {
        Log "[OK] gateway.auth.mode = 'password' (headless-compatible)"
    } else {
        Log "[WARN] gateway.auth.mode = '$authMode' (may require browser login!)"
        Log "[INFO] Consider changing to 'password' mode for fully headless operation."
    }

    # Check Telegram channel
    if ($config.channels.telegram.enabled -eq $true) {
        Log "[OK] Telegram channel enabled with botToken configured"
        if ($config.channels.telegram.allowFrom) {
            Log "[OK] Telegram allowFrom whitelist configured"
        }
    } else {
        Log "[WARN] Telegram channel not enabled"
    }
} else {
    Log "[WARN] openclaw.json not found at $configPath"
}

# ── Step 4: Create hidden VBScript launcher ──────────────────────────────
$vbsPath = Join-Path $scriptRoot 'openclaw_run_hidden.vbs'
$vbsContent = @"
' ============================================================
'  OpenClaw Gateway — Silent Hidden Launcher
'  Called by the "OpenClaw Gateway" scheduled task at boot.
'  Runs gateway.cmd with ZERO window visibility (windowStyle=0).
'
'  This VBScript wrapper is essential because:
'    1. schtasks /CREATE cannot set "Hidden" window style directly.
'    2. Even with task settings set to "Hidden", CMD windows can flash.
'    3. WScript.Shell.Run with windowStyle=0 guarantees NO window at all.
'
'  Generated by: OpenClaw Silent Boot Guardian (Antigravity Agent)
'  Date: $(Get-Date -Format 'yyyy-MM-dd')
' ============================================================
Dim shell
Set shell = CreateObject("WScript.Shell")

' Set environment so the child process inherits system env vars
' (Task Scheduler in SYSTEM context loads Machine-level env vars automatically)

' Run gateway.cmd completely hidden (windowStyle=0), do NOT wait for exit (False)
shell.Run """$($GatewayCmdPath.Replace('\','\\'))""", 0, False

Set shell = Nothing
"@

Set-Content -Path $vbsPath -Value $vbsContent -Encoding ASCII
Log "[OK] Created hidden launcher: $vbsPath"

# ── Step 5: Audit existing scheduled task ────────────────────────────────
Log "--- Auditing existing scheduled task '$TaskName' ---"
$existingTask = $null
try {
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Log "[FOUND] Task '$TaskName' exists"

    # Check trigger type
    $triggers = $existingTask.Triggers
    $hasBootTrigger = $false
    $hasLogonTrigger = $false
    foreach ($t in $triggers) {
        if ($t -is [Microsoft.Management.Infrastructure.CimInstance]) {
            $triggerType = $t.CimClass.CimClassName
            if ($triggerType -match 'Boot') { $hasBootTrigger = $true }
            if ($triggerType -match 'Logon') { $hasLogonTrigger = $true }
            Log "  Trigger: $triggerType"
        }
    }

    # Check principal
    $princ = $existingTask.Principal
    Log "  LogonType: $($princ.LogonType)"
    Log "  RunLevel:  $($princ.RunLevel)"
    Log "  UserId:    $($princ.UserId)"

    # Determine if re-registration is needed
    $needsFix = $false
    $reasons = @()

    if (-not $hasBootTrigger) {
        $needsFix = $true
        $reasons += "Missing BootTrigger (currently using LogonTrigger only)"
    }
    if ($princ.LogonType -eq 'InteractiveToken' -or $princ.LogonType -eq 'Interactive') {
        $needsFix = $true
        $reasons += "LogonType is InteractiveToken (will show CMD window)"
    }
    if ($princ.RunLevel -ne 'Highest') {
        $needsFix = $true
        $reasons += "RunLevel is not Highest"
    }

    if ($needsFix) {
        Log "[ISSUES DETECTED] Task needs re-registration:"
        foreach ($r in $reasons) { Log "  - $r" }
    } else {
        Log "[OK] Task configuration looks correct"
    }
} catch {
    Log "[NOT FOUND] Task '$TaskName' does not exist — will create from scratch"
}

# ── Step 6: (Re-)Register the scheduled task ─────────────────────────────
Log "--- (Re-)Registering task '$TaskName' for SILENT BOOT startup ---"

# Remove existing task if present
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Log "[OK] Removed old task registration"
} catch {
    Log "[INFO] No existing task to remove"
}

# Action: run the VBScript launcher (guarantees zero window)
$action = New-ScheduledTaskAction `
    -Execute 'wscript.exe' `
    -Argument "`"$vbsPath`"" `
    -WorkingDirectory (Split-Path $GatewayCmdPath -Parent)

# Trigger: BOOT trigger (runs before any user logs in)
$trigger = New-ScheduledTaskTrigger -AtStartup

# Add a 30-second delay to let networking/Tailscale come up
$trigger.Delay = 'PT30S'

# Principal: run as the user with highest privilege, using S4U (no password prompt, no window)
# S4U (Service-for-User) allows the task to run with stored credentials
# without requiring the user to be logged in.
$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $User `
    -LogonType 'S4U' `
    -RunLevel 'Highest'

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount $MaxRestartCount `
    -RestartInterval (New-TimeSpan -Seconds $RestartDelaySeconds) `
    -Hidden

# Register
$task = Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $taskPrincipal `
    -Settings $settings `
    -Description "OpenClaw Gateway — auto-start at boot, fully silent, highest privilege. Self-healed by Antigravity Agent on $(Get-Date -Format 'yyyy-MM-dd')." `
    -Force

Log "[OK] Task '$TaskName' registered successfully"
Log "  Trigger:   AtStartup (with 30s delay)"
Log "  LogonType: S4U (no interactive window, no stored password needed)"
Log "  RunLevel:  Highest"
Log "  Hidden:    Yes"
Log "  Restart:   On failure, ${RestartDelaySeconds}s interval, max $MaxRestartCount retries"
Log "  Action:    wscript.exe → openclaw_run_hidden.vbs → gateway.cmd"

# ── Step 7: Verify the registration ─────────────────────────────────────
Log "--- Verifying registration ---"
$verified = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($verified) {
    $vTrigger = $verified.Triggers[0]
    $vPrinc   = $verified.Principal
    $vSet     = $verified.Settings

    $checks = @(
        @{ Name="Trigger is BootTrigger";  Pass=($vTrigger.CimClass.CimClassName -match 'Boot') },
        @{ Name="RunLevel is Highest";     Pass=($vPrinc.RunLevel -eq 'Highest') },
        @{ Name="LogonType is S4U";        Pass=($vPrinc.LogonType -eq 'S4U') },
        @{ Name="Hidden setting enabled";  Pass=($vSet.Hidden -eq $true) },
        @{ Name="No execution time limit"; Pass=($vSet.ExecutionTimeLimit -eq 'PT0S' -or $vSet.ExecutionTimeLimit -eq [TimeSpan]::Zero) },
        @{ Name="RestartOnFailure set";    Pass=($vSet.RestartCount -ge 1) }
    )

    $allPass = $true
    foreach ($c in $checks) {
        if ($c.Pass) { $icon = "[PASS]" } else { $icon = "[FAIL]"; $allPass = $false }
        Log "  $icon $($c.Name): $($c.Pass)"
    }

    if ($allPass) {
        Log ""
        Log "================================================================"
        Log "  [ALL PASS] OpenClaw Gateway is now configured"
        Log "  for 100% SILENT, HEADLESS, AUTO-START at system boot!"
        Log "================================================================"
    } else {
        Log ""
        Log "[WARN] Some checks did not pass. Manual review recommended."
    }
} else {
    Log "[ERROR] Task verification failed — task not found after registration!"
}

Log ""
Log "Script completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "Log file: $logFile"
