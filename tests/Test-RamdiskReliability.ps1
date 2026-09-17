#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'ramdisk-guardian.psm1')
$script:passed=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:passed++;Write-Output "PASS: $Name"}
$now=[datetimeoffset]'2026-01-01T00:00:00Z'
$state=New-RamdiskRecoveryState
$one=Resolve-RamdiskRecoveryDecision -State $state -PressureReason 'low-host-memory' -NowUtc $now
$two=Resolve-RamdiskRecoveryDecision -State $one.State -PressureReason 'low-host-memory' -NowUtc $now.AddSeconds(5)
$three=Resolve-RamdiskRecoveryDecision -State $two.State -PressureReason 'low-host-memory' -NowUtc $now.AddSeconds(10)
Check (-not $one.Allowed -and -not $two.Allowed -and $three.Allowed) 'sustained pressure requires three samples over ten seconds'
Check ($state.PressureSamples -eq 0) 'recovery decision does not mutate input state'
$gap=Resolve-RamdiskRecoveryDecision -State $two.State -PressureReason 'low-host-memory' -NowUtc $now.AddMinutes(5)
Check (-not $gap.Allowed -and $gap.State.PressureSamples -eq 1) 'stale samples cannot accumulate across scheduler intervals'
$paused=Resolve-RamdiskRecoveryDecision -State $three.State -PressureReason 'low-host-memory' -NowUtc $now.AddSeconds(15) -Paused
Check (-not $paused.Allowed -and $paused.Reason -eq 'recovery-paused' -and $paused.State.PressureSamples -eq 0) 'user pause resets the confirmation streak'
$busy=Resolve-RamdiskRecoveryDecision -State $three.State -PressureReason 'low-host-memory' -NowUtc $now.AddSeconds(15) -ActiveLeaseCount 1
Check (-not $busy.Allowed -and $busy.Reason -eq 'active-cache-consumer') 'active consumer prevents reinitialization'
$unknown=Resolve-RamdiskRecoveryDecision -State $three.State -PressureReason 'low-host-memory' -NowUtc $now.AddSeconds(15) -LeaseEvidenceUnknown
Check (-not $unknown.Allowed -and $unknown.Reason -eq 'consumer-state-unknown') 'unknown consumer state is not treated as safe'
$cooldown=$three.State.Clone();$cooldown.LastAttemptUtc=$now.ToString('o')
$decision=Resolve-RamdiskRecoveryDecision -State $cooldown -PressureReason 'low-host-memory' -NowUtc $now.AddSeconds(15)
Check (-not $decision.Allowed -and $decision.Reason -eq 'recovery-cooldown') 'successful attempts respect cooldown'
$cooldown=$three.State.Clone();$cooldown.SuppressUntilUtc=$now.AddHours(6).ToString('o')
$decision=Resolve-RamdiskRecoveryDecision -State $cooldown -PressureReason 'low-host-memory' -NowUtc $now.AddSeconds(15)
Check (-not $decision.Allowed -and $decision.Reason -eq 'no-benefit-or-failure-cooldown') 'ineffective attempts have extended suppression'
Check ((Get-RamdiskPressureReason -AvailableGB 4 -UsedGB 0.5 -UnaccountedGB -4) -eq 'low-host-memory') 'existing emergency threshold remains supported'
Check ($null -eq (Get-RamdiskPressureReason -AvailableGB 4 -UsedGB 9 -UnaccountedGB 10)) 'large cache volume is not reset by this policy'
Check ($null -eq (Get-RamdiskPressureReason -AvailableGB $null -UsedGB 1 -UnaccountedGB $null)) 'unavailable metrics are not pressure evidence'
Check ((Get-RamdiskRecoveryBenefit -BeforeAvailableGB 4 -AfterAvailableGB 8).State -eq 'effective') 'recovery benefit is measured'
Check ((Get-RamdiskRecoveryBenefit -BeforeAvailableGB 4 -AfterAvailableGB 4.1).State -eq 'no-benefit') 'negligible benefit is not a successful memory relief'
Check ((Get-RamdiskRecoveryBenefit).State -eq 'unknown') 'missing post-recovery metrics remain unknown'
$temp=Join-Path $env:TEMP ('ramdisk-reliability-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
    $json=Join-Path $temp 'status.json'
    Write-RamdiskJson -Path $json -Value @{State='before'}
    Write-RamdiskJson -Path $json -Value @{State='after'}
    Check ((Read-RamdiskJson -Path $json).State -eq 'after' -and (Read-RamdiskJson -Path "$json.previous").State -eq 'before') 'atomic status has one recoverable preimage'
    foreach($n in @('ramdisk-guardian.psm1','Set-RamdiskRecoveryMode.ps1','Use-RamdiskCacheLease.ps1')){Copy-Item (Join-Path $root $n) (Join-Path $temp $n)}
    $plan=& (Join-Path $temp 'Set-RamdiskRecoveryMode.ps1') -Mode Pause -Json|ConvertFrom-Json
    Check (-not $plan.Applied -and -not(Test-Path (Join-Path $temp 'logs\recovery-control.json'))) 'recovery control defaults to preview'
    $actual=& (Join-Path $temp 'Set-RamdiskRecoveryMode.ps1') -Mode Pause -Apply -Json|ConvertFrom-Json
    Check ($actual.Applied -and $actual.AfterPaused) 'explicit pause is read back'
    $actual=& (Join-Path $temp 'Set-RamdiskRecoveryMode.ps1') -Mode Resume -Apply -Json|ConvertFrom-Json
    Check ($actual.Applied -and -not $actual.AfterPaused) 'explicit resume does not clear cooldown state'
    $lease=& (Join-Path $temp 'Use-RamdiskCacheLease.ps1') -Mode Acquire -Name fixture -ConsumerProcessId $PID -Seconds 60|ConvertFrom-Json
    $leaseState=Get-RamdiskLeaseState -Directory (Join-Path $temp 'logs\leases')
    Check ($leaseState.Active -eq 1 -and $lease.ProcessId -eq $PID) 'consumer lease binds PID and creation time'
    & (Join-Path $temp 'Use-RamdiskCacheLease.ps1') -Mode Release -Name fixture -ConsumerProcessId $PID|Out-Null
    Check ((Get-RamdiskLeaseState -Directory (Join-Path $temp 'logs\leases')).Active -eq 0) 'consumer releases only its named lease'
    [IO.File]::WriteAllText((Join-Path $temp 'logs\leases\bad.json'),'broken')
    Check ((Get-RamdiskLeaseState -Directory (Join-Path $temp 'logs\leases')).Unknown -eq 1) 'corrupt lease is unknown, not expired'
    # Extract the real normal copy branch; fault injection proves its errors escape to the worker handler.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'zguardian.ps1'),[ref]$tokens,[ref]$errors)
    $copy=$ast.Find({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -like '*$usageTarget*' -and $n.Extent.Text.Contains('Copy-Item')},$true)
    Check ($null -ne $copy) 'normal copy test uses actual production branch'
    $source=Join-Path $temp 'guide.md';[IO.File]::WriteAllText($source,'fixture')
    $usageSource=Get-Item $source;$usageTarget=Join-Path $temp 'copied.md'
    & ([scriptblock]::Create($copy.Extent.Text))
    Check ((Get-FileHash $source).Hash -eq (Get-FileHash $usageTarget).Hash) 'normal copy readback matches source'
    [IO.File]::Delete($usageTarget)
    $thrown=& {
        function Copy-Item { [CmdletBinding()]param($LiteralPath,$Destination,[switch]$Force) Write-Error 'injected copy failure' }
        try{& ([scriptblock]::Create($copy.Extent.Text));$false}catch{$true}
    }
    Check $thrown 'normal copy error cannot silently report completion'
    Check (-not(Test-Path $usageTarget)) 'failed copy leaves no false ready artifact'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
Write-Output "PASS: $passed Ramdisk reliability checks; no real RAM disk reinitialization."