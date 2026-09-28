#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'ramdisk-guardian.psm1') -Force
$script:checks=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:checks++;"PASS: $Name"}
$start=[datetimeoffset]'2026-01-01T00:00:00Z'
function Warm([double]$Raw=-16,[double]$Available=24){
    $state=$null
    foreach($minute in @(0,15,30,45)){
        $a=Get-RamdiskMemoryAssessment -State $state -Identity 'boot|volume|12' -AvailableGB $Available -UsedGB 1 -UnaccountedGB $Raw -NowUtc $start.AddMinutes($minute)
        $state=$a.State
    }
    return $state
}
function Assess($State,[double]$Raw,[double]$Available,[double]$Used=1,[int]$Minutes=60){
    Get-RamdiskMemoryAssessment -State $State -Identity 'boot|volume|12' -AvailableGB $Available -UsedGB $Used -UnaccountedGB $Raw -NowUtc $start.AddMinutes($Minutes)
}
function Reason($Assessment,$Raw,$Available,$Used=1){
    Get-RamdiskPressureReason -AvailableGB $Available -UsedGB $Used -UnaccountedGB $Raw -CorrelatedGrowthGB $Assessment.CorrelatedGrowthGB
}
$warm=Warm
$startup=$null
for($i=0;$i -lt 3;$i++){
    $a=Get-RamdiskMemoryAssessment -State $startup -Identity 'startup' -AvailableGB (32-4*$i) -UsedGB 0.5 -UnaccountedGB (-10+4*$i) -NowUtc $start.AddMinutes(15*$i)
    $startup=$a.State
    if($i -lt 2){Check ($null -eq $a.CorrelatedGrowthGB) 'a provisional startup anchor cannot authorize relative recovery'}
}
Check ($a.Status -eq 'ready' -and $a.CorrelatedGrowthGB -eq 8) 'a leak during calibration is frozen rather than learned into the startup baseline'
$before=$warm|ConvertTo-Json -Depth 8 -Compress
$a=Assess $warm -8 16
Check ($a.CorrelatedGrowthGB -eq 8 -and (Reason $a -8 16) -eq 'relative-unaccounted-memory') 'an 8 GiB loss is detected even while the residual remains negative'
Check (($warm|ConvertTo-Json -Depth 8 -Compress) -ceq $before) 'assessment does not mutate the supplied baseline'
$a=Assess $warm -20 3
Check ($null -eq (Reason $a -20 3)) 'ordinary process growth and low available memory do not move the driver'
$a=Assess $warm -4 36
Check ($a.CorrelatedGrowthGB -eq 0 -and $null -eq (Reason $a -4 36)) 'closing shared-working-set processes is not mistaken for leaked memory'
$a=Assess $warm -10 18 7
Check ($a.CorrelatedGrowthGB -eq 0 -and $null -eq (Reason $a -10 18 7)) 'six GiB of useful cache growth is removed from both signals'
$low=Warm -16 9
$a=Assess $low -11 4
Check ((Reason $a -11 4) -eq 'low-memory-with-unaccounted-growth') 'the low-memory fallback still detects a corroborated 5 GiB loss'
Check ($null -eq (Get-RamdiskPressureReason -AvailableGB 3 -UsedGB 0.1 -UnaccountedGB -8 -CorrelatedGrowthGB 0)) 'tiny cache and unrelated low memory never suffice'
Check ((Get-RamdiskPressureReason -AvailableGB $null -UsedGB 4 -UnaccountedGB 8.2) -eq 'unaccounted-memory') 'the historical strong residual remains detectable without a learned baseline'
foreach($bad in @($null,[double]::NaN,[double]::PositiveInfinity)){
    $a=Get-RamdiskMemoryAssessment -State $warm -Identity 'boot|volume|12' -AvailableGB 4 -UsedGB 1 -UnaccountedGB $bad -NowUtc $start.AddHours(1)
    Check ($a.Status -eq 'unavailable' -and $null -eq (Reason $a $bad 4)) 'missing or invalid counters cannot become recovery evidence'
}
$failedRead=Get-RamdiskMemoryAssessment -State $warm -Identity '|volume|12' -AvailableGB 4 -UsedGB 1 -UnaccountedGB $null -NowUtc $start.AddHours(1)
Check (($failedRead.State|ConvertTo-Json -Depth 8 -Compress) -ceq $before) 'one failed counter read preserves the prior identity and calibration'
$recoveredRead=Assess $failedRead.State -8 16 1 75
Check ($recoveredRead.Status -eq 'ready' -and $recoveredRead.CorrelatedGrowthGB -eq 8) 'detection resumes immediately after a transient counter failure'
Check ($null -eq (Get-RamdiskPressureReason -AvailableGB 3 -UsedGB 9 -UnaccountedGB 12 -CorrelatedGrowthGB 12)) 'the cache soft limit still blocks destructive recovery'
foreach($identity in @('new-boot|volume|12','boot|new-volume|12','boot|volume|32')){
    $a=Get-RamdiskMemoryAssessment -State $warm -Identity $identity -AvailableGB 16 -UsedGB 1 -UnaccountedGB -8 -NowUtc $start.AddHours(1)
    Check ($a.Status -eq 'warming-up' -and $null -eq $a.CorrelatedGrowthGB) 'boot, volume and capacity changes discard an incomparable baseline'
}
foreach($time in @($start.AddHours(4),$start.AddMinutes(10))){
    $a=Get-RamdiskMemoryAssessment -State $warm -Identity 'boot|volume|12' -AvailableGB 16 -UsedGB 1 -UnaccountedGB -8 -NowUtc $time
    Check ($a.Status -eq 'warming-up') 'a long observation gap or backward clock restarts calibration'
}
$slow=Warm -16 32
$firstDetection=$null
for($hour=1;$hour -le 120;$hour++){
    $loss=$hour/10
    $a=Get-RamdiskMemoryAssessment -State $slow -Identity 'boot|volume|12' -AvailableGB (32-$loss) -UsedGB 1 -UnaccountedGB (-16+$loss) -NowUtc $start.AddHours(1+$hour)
    $slow=$a.State
    if($null -eq $firstDetection -and (Reason $a (-16+$loss) (32-$loss))){$firstDetection=$hour}
}
Check ($null -ne $firstDetection -and $firstDetection -le 82 -and $a.CorrelatedGrowthGB -ge 11.9 -and $slow.Frozen) 'a 0.1 GiB per hour leak is not learned away after five days'
$held=Assess $warm -7 15
for($hour=2;$hour -le 30;$hour++){
    $held=Get-RamdiskMemoryAssessment -State $held.State -Identity 'boot|volume|12' -AvailableGB 15 -UsedGB 1 -UnaccountedGB -7 -NowUtc $start.AddHours($hour)
}
Check ($held.CorrelatedGrowthGB -eq 9 -and $held.State.Samples.Count -eq 0) 'a frozen anomaly survives the 24h rolling window'
$resumed=Get-RamdiskMemoryAssessment -State $held.State -Identity 'boot|volume|12' -AvailableGB 24 -UsedGB 1 -UnaccountedGB -16 -NowUtc $start.AddHours(31)
Check ($null -eq $resumed.State.Frozen -and $resumed.State.Samples.Count -eq 1) 'baseline learning resumes when the observed growth disappears'
$bounded=Warm
for($minute=60;$minute -lt 3000;$minute+=5){$a=Assess $bounded -16 24 1 $minute;$bounded=$a.State}
Check ($bounded.Samples.Count -le 288) 'state is bounded even with a frequent scheduler'
$legacy=New-RamdiskRecoveryState
$legacy.LastAttemptUtc=$start.ToString('o');$legacy.SuppressUntilUtc=$start.AddHours(6).ToString('o');$legacy.MemoryBaseline=$warm
$decision=Resolve-RamdiskRecoveryDecision -State $legacy -PressureReason 'relative-unaccounted-memory' -NowUtc $start.AddHours(1)
Check ($decision.Reason -eq 'no-benefit-or-failure-cooldown' -and $decision.State.MemoryBaseline) 'v1 recovery state keeps its cooldown while gaining baseline data'
$streak=New-RamdiskRecoveryState
for($i=0;$i -lt 3;$i++){
    $growth=if($i%2){8.1}else{7.9}
    $reason=Get-RamdiskPressureReason -AvailableGB 4 -UsedGB 0.5 -UnaccountedGB -1 -CorrelatedGrowthGB $growth
    $decision=Resolve-RamdiskRecoveryDecision -State $streak -PressureReason $reason -RelativeEvidenceReady -NowUtc $start.AddSeconds(5*$i)
    $streak=$decision.State
}
Check ($decision.Allowed -and $streak.PressureSamples -eq 3) 'crossing related pressure thresholds does not break sustained confirmation'
$spike=Assess $warm -8 16
$d=Resolve-RamdiskRecoveryDecision -State (New-RamdiskRecoveryState) -PressureReason 'relative-unaccounted-memory' -RelativeEvidenceReady:$spike.TrendReady -NowUtc $start.AddHours(1)
Check (-not $spike.TrendReady -and -not $d.Allowed -and $d.Reason -eq 'confirming-memory-trend') 'one relative spike only waits for a later observation'
$clear=Assess $spike.State -16 24 1 75
Check (-not $clear.TrendReady -and $null -eq $clear.State.TrendSinceUtc) 'a recovered scheduler spike resets the trend'
$persistent=Assess $spike.State -8 16 1 75
Check ($persistent.TrendReady) 'persistent correlated loss reaches the short confirmation gate on the next run'
$gap=Assess $spike.State -8 16 1 90
Check (-not $gap.TrendReady) 'stale trend observations cannot be joined across a missing scheduler run'
$state=New-RamdiskRecoveryState
foreach($seconds in @(0,5,10)){
    $d=Resolve-RamdiskRecoveryDecision -State $state -PressureReason 'relative-unaccounted-memory' -RelativeEvidenceReady:$persistent.TrendReady -NowUtc $start.AddMinutes(75).AddSeconds($seconds)
    $state=$d.State
}
Check ($d.Allowed) 'a persistent relative signal still requires and passes three fresh samples over ten seconds'

# Exercise the actual acquisition functions without reading Windows or Primo.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'zguardian.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Worker does not parse.'}
$functions=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Read-UnaccountedGB','Read-RamdiskVolume')},$true)
foreach($fn in $functions){. ([scriptblock]::Create($fn.Extent.Text))}
$script:counters=@(
    [pscustomobject]@{Path='\Memory\Available Bytes';CookedValue=24GB;Status=0},
    [pscustomobject]@{Path='\Memory\Modified Page List Bytes';CookedValue=1GB;Status=0},
    [pscustomobject]@{Path='\Memory\Cache Bytes';CookedValue=2GB;Status=0},
    [pscustomobject]@{Path='\Memory\Pool Paged Bytes';CookedValue=1GB;Status=0},
    [pscustomobject]@{Path='\Memory\Pool Nonpaged Bytes';CookedValue=1GB;Status=0},
    [pscustomobject]@{Path='\Process(_Total)\Working Set';CookedValue=51GB;Status=0}
)
function Get-Counter {[pscustomobject]@{CounterSamples=$script:counters}}
function Get-CimInstance {[pscustomobject]@{TotalVisibleMemorySize=64GB/1KB;LastBootUpTime=$start.UtcDateTime}}
Check ((Read-UnaccountedGB) -eq -16 -and $script:residualAvailableGB -eq 24 -and $script:hostBootUtc) 'raw residual and corroborating available memory use one complete sample'
$script:counters=$script:counters[0..4]
Check ($null -eq (Read-UnaccountedGB) -and $null -eq $script:residualAvailableGB) 'a missing working-set counter is not silently replaced by zero'
$script:counters[0].Status=1
Check ($null -eq (Read-UnaccountedGB)) 'a failed counter status invalidates the residual'
$ramLetter='FIXTURE';$script:reads=0;$script:delays=0
function Start-Sleep {param($Milliseconds) if($Milliseconds -ne 500){throw 'Unexpected delay'};$script:delays++}
function Get-Volume {
    $script:reads++
    if($script:reads -eq 1){throw 'Transient storage query failure'}
    if($script:reads -eq 2){return [pscustomobject]@{FileSystemLabel='';UniqueId='fixture'}}
    [pscustomobject]@{FileSystemLabel='RAMDISK';UniqueId='fixture'}
}
Check ((Read-RamdiskVolume).UniqueId -eq 'fixture' -and $script:reads -eq 3 -and $script:delays -eq 2) 'exception and blank-label reads retry before reporting an error'
$script:reads=0;$script:delays=0
function Get-Volume {$script:reads++;throw 'Persistent query failure'}
$failed=$false;try{Read-RamdiskVolume|Out-Null}catch{$failed=$_.Exception.Message -match 'after three reads'}
Check ($failed -and $script:reads -eq 3 -and $script:delays -eq 2) 'persistent identity failure is bounded and remains an error'
$script:reads=0;$script:delays=0
function Get-Volume {$script:reads++;[pscustomobject]@{FileSystemLabel='DATA';UniqueId='other'}}
Check ((Read-RamdiskVolume).FileSystemLabel -eq 'DATA' -and $script:reads -eq 1 -and $script:delays -eq 0) 'a positively wrong volume is not retried into an acceptable identity'
"PASS: $script:checks memory-policy checks; synthetic memory only, no real disk operation."
