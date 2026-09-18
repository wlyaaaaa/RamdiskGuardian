#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path $env:TEMP ('ramdisk-health-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'logs'))
$script:checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:checks++;Write-Host "PASS: $Message"}
function Get-Volume {[CmdletBinding()]param($DriveLetter) [pscustomobject]@{FileSystemLabel='RAMDISK';FileSystem=$global:RamdiskHealthTest_fs;HealthStatus='Healthy';Size=12GB;SizeRemaining=11GB}}
function Get-ScheduledTask {[CmdletBinding()]param($TaskName) [pscustomobject]@{TaskName=$TaskName;State=$global:RamdiskHealthTest_taskState;Settings=@{Enabled=$true};Triggers=$global:RamdiskHealthTest_triggers}}
function Get-ScheduledTaskInfo {[CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject) process{[pscustomobject]@{LastRunTime=(Get-Date).AddSeconds(-10);NextRunTime=(Get-Date).AddMinutes(15);LastTaskResult=$global:RamdiskHealthTest_taskResult}}}
function Test-Path {[CmdletBinding()]param([Parameter(Position=0)][string]$Path,[string]$LiteralPath) $p=if($LiteralPath){$LiteralPath}else{$Path};if($p -like 'Z:\*'){return $true};Microsoft.PowerShell.Management\Test-Path -LiteralPath $p}
function Get-FileHash {[CmdletBinding()]param([Parameter(Position=0)][string]$Path,[string]$LiteralPath,[string]$Algorithm='SHA256') $p=if($LiteralPath){$LiteralPath}else{$Path};if($p -like 'Z:\*'){return [pscustomobject]@{Hash=$global:RamdiskHealthTest_guideHash}};Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $p -Algorithm $Algorithm}
function Reset-Fixture {
 $global:RamdiskHealthTest_fs='NTFS';$global:RamdiskHealthTest_taskState='Ready';$global:RamdiskHealthTest_taskResult=0
 $global:RamdiskHealthTest_triggers=@([pscustomobject]@{Enabled=$true;Repetition=@{Interval='PT15M'}})
 $observation=@{Schema='ramdisk.health-observation.v1';Health='OK';ObservedUtc=[datetime]::UtcNow.ToString('o');WorkerSha256=(Get-FileHash (Join-Path $fixture 'zguardian.ps1')).Hash;ModuleSha256=(Get-FileHash (Join-Path $fixture 'ramdisk-guardian.psm1')).Hash;Metrics=@{}}
 [IO.File]::WriteAllText((Join-Path $fixture 'logs\health.json'),($observation|ConvertTo-Json -Depth 5))
 $state=@{Schema='ramdisk.recovery-state.v1';LastOutcome='none';LastAttemptUtc=$null;SuppressUntilUtc=$null}
 [IO.File]::WriteAllText((Join-Path $fixture 'logs\recovery-state.json'),($state|ConvertTo-Json))
 [IO.File]::Delete((Join-Path $fixture 'logs\recovery-control.json'))
}
function Read-Health {& (Join-Path $repo 'Get-RamdiskHealth.ps1') -Root $fixture -Json|ConvertFrom-Json}
try {
 foreach($f in @('zguardian.ps1','ramdisk-guardian.psm1')){[IO.File]::Copy((Join-Path $repo $f),(Join-Path $fixture $f))}
 $guide=@(Get-ChildItem $repo -Filter 'Z_*.md' -File)[0]
 [IO.File]::Copy($guide.FullName,(Join-Path $fixture $guide.Name))
 $global:RamdiskHealthTest_guideHash=(Get-FileHash (Join-Path $fixture $guide.Name)).Hash
 Reset-Fixture;$r=Read-Health;if($r.Status -ne 'healthy'){$r|ConvertTo-Json -Depth 8|Write-Host};Check ($r.Status -eq 'healthy') 'healthy fixture is observed without accessing a real volume or task'
 $global:RamdiskHealthTest_taskResult=1;$r=Read-Health;Check ($r.Status -ne 'healthy' -and $r.Reasons -contains 'guardian-last-run-failed') 'failed scheduled run cannot be hidden by an older OK observation'
 Reset-Fixture;$global:RamdiskHealthTest_taskResult=267009;$global:RamdiskHealthTest_taskState='Running';$r=Read-Health;Check ($r.Reasons -notcontains 'guardian-last-run-failed') 'running Task Scheduler status is not an error result'
 Reset-Fixture;$global:RamdiskHealthTest_triggers=@();$r=Read-Health;Check ($r.Reasons -contains 'guardian-periodic-trigger-missing') 'missing recurring trigger is not silently replaced by a presumed interval'
 Reset-Fixture;$global:RamdiskHealthTest_fs='ReFS';$r=Read-Health;Check ($r.Reasons -contains 'volume-filesystem-mismatch') 'wrong filesystem is reported'
 Reset-Fixture;[IO.File]::WriteAllText((Join-Path $fixture 'logs\recovery-control.json'),'{"Schema":"ramdisk.recovery-control.v1","Paused":true}');$r=Read-Health;Check ($r.Reasons -contains 'automatic-recovery-paused') 'intentional recovery pause remains visible'
 Reset-Fixture;[IO.File]::WriteAllText((Join-Path $fixture 'logs\recovery-state.json'),'{"Schema":"ramdisk.recovery-state.v1","LastOutcome":"failed","LastAttemptUtc":"2026-01-01T00:00:00Z","SuppressUntilUtc":null}');$r=Read-Health;Check ($r.Reasons -contains 'last-recovery-failed') 'recovery failure remains visible after pressure passes'
 Reset-Fixture;[IO.File]::WriteAllText((Join-Path $fixture 'logs\recovery-control.json'),'{"Paused":"false"}');$r=Read-Health;Check ($r.Reasons -contains 'recovery-state-unavailable') 'malformed pause data is Unknown rather than a healthy boolean'
 Reset-Fixture;[IO.File]::WriteAllText((Join-Path $fixture 'logs\recovery-state.json'),'{}');$r=Read-Health;Check ($r.Reasons -contains 'recovery-state-unavailable') 'invalid recovery state is not accepted as healthy'
 Write-Host "PASS: $script:checks production health cases; no real task or RAM disk operation."
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
