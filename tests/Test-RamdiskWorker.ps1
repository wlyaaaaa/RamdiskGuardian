#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'ramdisk-guardian.psm1') -Force
$testRoot=Join-Path $env:TEMP ('ramdisk-worker-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$worker=[IO.File]::ReadAllText((Join-Path $repo 'zguardian.ps1'))
$nativeLine='$rxprd=''C:\Program Files\Primo Ramdisk\rxprd.exe'''
$notification='& "$env:WINDIR\System32\msg.exe" * ''/TIME:60'' "RamDisk($Z) $health - $detail"|Out-Null'
if(-not $worker.Contains($nativeLine) -or -not $worker.Contains($notification)){throw 'Worker instrumentation point changed.'}
$runner=@'
param([string]$CaseRoot)
$ErrorActionPreference='Stop'
$f=Get-Content -LiteralPath (Join-Path $CaseRoot 'fixture.json') -Raw | ConvertFrom-Json
if(Get-PSDrive Q -ErrorAction SilentlyContinue){throw 'Fixture drive Q is already in use.'}
# A process-local PowerShell drive maps only this disposable ordinary directory.
New-PSDrive -Name Q -PSProvider FileSystem -Root (Join-Path $CaseRoot 'disk')|Out-Null
$script:reads=0
function Get-Volume {
    $script:reads++
    if($f.TransientIdentity -and $script:reads -lt 3){return [pscustomobject]@{FileSystemLabel='';UniqueId='fixture-volume'}}
    [pscustomobject]@{FileSystemLabel='RAMDISK';UniqueId='fixture-volume';Size=12GB;SizeRemaining=11GB}
}
function Get-CimInstance {
    param($ClassName)
    if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{TotalVisibleMemorySize=64GB/1KB;LastBootUpTime=[datetime]'2026-01-01T00:00:00Z'}}
    [pscustomobject]@{AvailableMBytes=$f.Available*1024;CommitLimit=96GB;CommittedBytes=48GB}
}
function Get-Counter {
    $values=@{'available bytes'=$f.Available*1GB;'modified page list bytes'=1GB;'cache bytes'=2GB;'pool paged bytes'=1GB;'pool nonpaged bytes'=1GB;'working set'=(64-$f.Available-5-$f.Raw)*1GB}
    [pscustomobject]@{CounterSamples=@(foreach($key in $values.Keys){[pscustomobject]@{Path=('\fixture\'+$key);CookedValue=$values[$key];Status=0}})}
}
& (Join-Path $CaseRoot 'zguardian.ps1') -WaitSeconds 0
exit $LASTEXITCODE
'@
$fakePrimo=@'
param($Operation,$Index,[switch]$s)
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'primo-calls.txt') -Value "$Operation $Index"
if($Operation -eq 'ls'){'#0 12288 SCSI Yes Good Q:';exit 0}
if($Operation -eq 'init'){
    # Real initialization drops the hidden marker. Make the disposable marker
    # writable again so the worker can recreate it without touching any real disk.
    [IO.File]::SetAttributes((Join-Path $PSScriptRoot 'disk\.ramdisk_ready'),[IO.FileAttributes]::Normal)
}
if($Operation -in @('init','save')){exit 0}
exit 3
'@
$cases=@(
    @{Name='legacy state and unrelated low memory';Available=4;Raw=-16;Warm=$false;Trend=$false;Paused=$false;TransientIdentity=$true;Expected='no-pressure';Rebuilt=$false},
    @{Name='one relative spike waits';Available=16;Raw=-8;Warm=$true;Trend=$false;Paused=$false;TransientIdentity=$false;Expected='confirming-memory-trend';Rebuilt=$false},
    @{Name='persistent relative loss reaches guarded recovery';Available=16;Raw=-8;Warm=$true;Trend=$true;Paused=$false;TransientIdentity=$false;Expected='relative-unaccounted-memory';Rebuilt=$true},
    @{Name='pause holds a confirmed relative loss';Available=16;Raw=-8;Warm=$true;Trend=$true;Paused=$true;TransientIdentity=$false;Expected='recovery-paused';Rebuilt=$false}
)
try{
    $index=0
    foreach($case in $cases){
        $index++;$caseRoot=Join-Path $testRoot ([string]$index)
        [void][IO.Directory]::CreateDirectory((Join-Path $caseRoot 'disk'))
        [void][IO.Directory]::CreateDirectory((Join-Path $caseRoot 'logs'))
        Copy-Item -LiteralPath (Join-Path $repo 'ramdisk-guardian.psm1') -Destination $caseRoot
        $guide=Get-ChildItem -LiteralPath $repo -Filter 'Z_*.md' -File
        Copy-Item -LiteralPath $guide.FullName -Destination $caseRoot
        Write-RamdiskTextAtomically -Path (Join-Path $caseRoot 'ramdrive.txt') -Text 'Q'
        Write-RamdiskTextAtomically -Path (Join-Path $caseRoot 'runner.ps1') -Text $runner
        Write-RamdiskTextAtomically -Path (Join-Path $caseRoot 'fake-primo.ps1') -Text $fakePrimo
        $fakePath=(Join-Path $caseRoot 'fake-primo.ps1').Replace("'","''")
        $instrumented=$worker.Replace($nativeLine,('$rxprd='''+$fakePath+'''')).Replace('Global\RamdiskGuardian-v2',('RamdiskGuardian-Test-'+[guid]::NewGuid().ToString('N'))).Replace($notification,'throw ''A notification would have been emitted''')
        Write-RamdiskTextAtomically -Path (Join-Path $caseRoot 'zguardian.ps1') -Text $instrumented
        Write-RamdiskJson -Path (Join-Path $caseRoot 'fixture.json') -Value $case
        $state=New-RamdiskRecoveryState
        if($case.Warm){
            $boot=([datetime]'2026-01-01T00:00:00Z').ToUniversalTime().ToString('o')
            $baseline=$null;$now=[datetimeoffset]::UtcNow
            foreach($minutes in @(60,45,30,15)){
                $a=Get-RamdiskMemoryAssessment -State $baseline -Identity "$boot|fixture-volume|12" -AvailableGB 24 -UsedGB 1 -UnaccountedGB -16 -NowUtc $now.AddMinutes(-$minutes)
                $baseline=$a.State
            }
            if($case.Trend){$baseline.TrendSinceUtc=$now.AddMinutes(-15).ToString('o')}
            $state.MemoryBaseline=$baseline
        }
        Write-RamdiskJson -Path (Join-Path $caseRoot 'logs\recovery-state.json') -Value $state
        Write-RamdiskJson -Path (Join-Path $caseRoot 'logs\recovery-control.json') -Value @{Paused=$case.Paused}
        & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $caseRoot 'runner.ps1') -CaseRoot $caseRoot
        if($LASTEXITCODE){$detail=Get-Content -LiteralPath (Join-Path $caseRoot 'logs\health.json') -Raw -ErrorAction SilentlyContinue;throw "Worker failed: $($case.Name); $detail"}
        $health=Read-RamdiskJson -Path (Join-Path $caseRoot 'logs\health.json')
        $after=Read-RamdiskJson -Path (Join-Path $caseRoot 'logs\recovery-state.json')
        $calls=@(Get-Content -LiteralPath (Join-Path $caseRoot 'primo-calls.txt') | ForEach-Object {$_.Trim()})
        $expected=if($case.Rebuilt){'ls|ls|init 0|save 0'}else{'ls'}
        if(($calls -join '|') -ne $expected -or $health.Health -eq 'ERROR' -or $health.Recovery.Decision -ne $case.Expected){throw "Unexpected worker decision/calls for $($case.Name): $($calls -join '|'); $($health|ConvertTo-Json -Depth 8 -Compress)"}
        if(-not $after.MemoryBaseline -or $null -eq $health.Metrics.MemoryTrendReady){throw 'Baseline/metrics wiring is missing.'}
        if($case.Rebuilt -and ($after.LastOutcome -ne 'no-benefit' -or -not $after.SuppressUntilUtc -or $after.MemoryBaseline.Frozen)){throw 'Post-rebuild baseline/cooldown was not refreshed.'}
        if(Test-Path -LiteralPath (Join-Path $caseRoot 'logs\alerts.log')){throw 'A fixture emitted an ERROR notification.'}
        "PASS: $($case.Name)"
    }
    'PASS: 4 complete worker scenarios; isolated filesystem, fake counters and fake Primo only.'
}finally{
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
