#requires -Version 7.0
[CmdletBinding()]
param([string[]]$LogPath,[string]$ResultPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'ramdisk-guardian.psm1') -Force
if($LogPath){
    $rows=@(foreach($path in $LogPath){
        foreach($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $path).Path)){
            if($line -match '([\d.]+) GB used, ([\d.]+) GB free; host available ([\d.]+) GB, commit headroom ([\d.]+) GB, unaccounted (-?[\d.]+) GB'){
                [pscustomobject]@{SourceLocalTime=$line.Substring(0,19);Kind='sample';UsedGB=$Matches[1];AvailableGB=$Matches[3];UnaccountedGB=$Matches[5]}
            }elseif($line -match 'EMERGENCY release:'){
                $used=if($line -match 'with Z: use ([\d.]+) GB'){$Matches[1]}else{throw 'Unknown release log format.'}
                $available=if($line -match 'host available ([\d.]+) GB'){$Matches[1]}else{''}
                $raw=if($line -match 'unaccounted host memory (-?[\d.]+) GB'){$Matches[1]}else{''}
                [pscustomobject]@{SourceLocalTime=$line.Substring(0,19);Kind='release';UsedGB=$used;AvailableGB=$available;UnaccountedGB=$raw}
            }
        }
    })
}else{$rows=@(Import-Csv -LiteralPath (Join-Path $PSScriptRoot 'fixtures/memory-history.csv'))}
function Number($value){if([string]::IsNullOrWhiteSpace([string]$value)){return $null};[double]::Parse($value,[Globalization.CultureInfo]::InvariantCulture)}
$baseline=$null;$previous=$null;$pending=$null;$eventResults=@();$sampleCandidates=@();$sampleCount=0;$boundaryChecks=0
foreach($row in $rows){
    # Old logs contain local wall time without an offset. Use it only as a
    # relative replay clock; do not claim these values are original UTC times.
    $clock=[datetimeoffset]::ParseExact(($row.SourceLocalTime -replace ' ','T')+'Z','yyyy-MM-ddTHH:mm:ssK',[Globalization.CultureInfo]::InvariantCulture)
    $used=Number $row.UsedGB;$available=Number $row.AvailableGB;$raw=Number $row.UnaccountedGB
    if($row.Kind -eq 'release'){
        $reason=Get-RamdiskPressureReason -AvailableGB $available -UsedGB $used -UnaccountedGB $raw
        $strong=$null -ne $raw -and $raw -ge 8
        if($strong -and $reason -ne 'unaccounted-memory'){throw "Missed strong historical signal: $($row.SourceLocalTime)"}
        if(-not $strong -and $reason){throw "Low memory alone became recovery evidence: $($row.SourceLocalTime)"}
        $event=[ordered]@{SourceLocalTime=$row.SourceLocalTime;Class=if($strong){'strong-residual'}else{'low-memory-only'};UsedGB=$used;AvailableGB=$available;UnaccountedGB=$raw;CandidateReason=$reason;Missing=if($strong){'available-memory-at-trigger'}else{'residual-at-trigger'};BoundarySensitivity=@()}
        if(-not $strong -and $previous){
            # Sensitivity scenarios, explicitly NOT reconstructed measurements:
            # combine the logged trigger availability with each adjacent raw
            # residual, leaving the real missing value null above.
            $a=Get-RamdiskMemoryAssessment -State $baseline -Identity 'historical-log-stream' -AvailableGB $available -UsedGB $used -UnaccountedGB $previous.Raw -NowUtc $clock
            $r=Get-RamdiskPressureReason -AvailableGB $available -UsedGB $used -UnaccountedGB $previous.Raw -CorrelatedGrowthGB $a.CorrelatedGrowthGB
            if($r){throw "Previous-residual sensitivity would reinitialize: $($row.SourceLocalTime)"}
            $event.BoundarySensitivity+=@{ResidualSource='previous-complete-sample';RawGB=$previous.Raw;CorrelatedGrowthGB=$a.CorrelatedGrowthGB;Candidate=$false}
            $boundaryChecks++
        }
        $pending=@{Event=$event;Baseline=$baseline;Clock=$clock}
        $eventResults+=$event
        # The historical disk really was reset. Do not continue its old baseline
        # through the observed intervention or pretend a counterfactual history.
        $baseline=$null
        continue
    }
    if($pending -and $pending.Event.Class -eq 'low-memory-only'){
        $e=$pending.Event
        $a=Get-RamdiskMemoryAssessment -State $pending.Baseline -Identity 'historical-log-stream' -AvailableGB $e.AvailableGB -UsedGB $e.UsedGB -UnaccountedGB $raw -NowUtc $pending.Clock
        $r=Get-RamdiskPressureReason -AvailableGB $e.AvailableGB -UsedGB $e.UsedGB -UnaccountedGB $raw -CorrelatedGrowthGB $a.CorrelatedGrowthGB
        if($r){throw "Following-residual sensitivity would reinitialize: $($e.SourceLocalTime)"}
        $e.BoundarySensitivity+=@{ResidualSource='following-complete-sample';RawGB=$raw;CorrelatedGrowthGB=$a.CorrelatedGrowthGB;Candidate=$false}
        $boundaryChecks++
    }
    $pending=$null
    $a=Get-RamdiskMemoryAssessment -State $baseline -Identity 'historical-log-stream' -AvailableGB $available -UsedGB $used -UnaccountedGB $raw -NowUtc $clock
    $baseline=$a.State
    $r=Get-RamdiskPressureReason -AvailableGB $available -UsedGB $used -UnaccountedGB $raw -CorrelatedGrowthGB $a.CorrelatedGrowthGB
    if($r){$sampleCandidates+=@{SourceLocalTime=$row.SourceLocalTime;Reason=$r;CorrelatedGrowthGB=$a.CorrelatedGrowthGB;TrendReady=$a.TrendReady}}
    $previous=@{Raw=$raw};$sampleCount++
}
$strongCount=@($eventResults|Where-Object Class -eq 'strong-residual').Count
$lowCount=@($eventResults|Where-Object Class -eq 'low-memory-only').Count
if($eventResults.Count -ne 38 -or $strongCount -ne 3 -or $lowCount -ne 35 -or $boundaryChecks -ne 70){throw 'The audit event set is incomplete.'}
$qualified=@($sampleCandidates|Where-Object {$_.Reason -eq 'unaccounted-memory' -or $_.TrendReady})
$result=[ordered]@{Schema='ramdisk.history-replay.v1';CompleteMetricSamples=$sampleCount;HistoricalRebuilds=$eventResults.Count;StrongSignalsRetained=$strongCount;LowMemoryOnlyRejected=$lowCount;AdjacentResidualSensitivityChecks=$boundaryChecks;AdditionalSampleCandidates=$sampleCandidates;AdditionalQualifiedCandidates=$qualified.Count;Events=$eventResults;Limitations=@('All 38 trigger records are partial; missing values remain null.','Adjacent residual combinations are sensitivity scenarios, not measured trigger-time telemetry.','No original ten-second confirmation samples exist; replay checks candidacy, not actual recovery authorization.','The residual cannot uniquely attribute memory to the Primo driver.','Historical local clock is used for relative intervals only; no boot identifier was logged.')}
if($ResultPath){Write-RamdiskJson -Path $ResultPath -Value $result}
"PASS: $sampleCount complete metric samples; 38 partial release records; 3 strong signals retained; 35 low-memory-only signals rejected; 70 adjacent-residual sensitivity checks."
"INFO: $($sampleCandidates.Count) additional historical sample candidates, $($qualified.Count) with qualified evidence; no disk or driver operation."
