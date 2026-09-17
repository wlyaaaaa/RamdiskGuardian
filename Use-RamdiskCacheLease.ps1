#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Acquire','Renew','Release','Status')][string]$Mode,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$')][string]$Name='consumer',
    [int]$ConsumerProcessId=$PID,[ValidateRange(30,86400)][int]$Seconds=3600
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ramdisk-guardian.psm1') -Force
$directory=Join-Path $PSScriptRoot 'logs\leases'
if($Mode -eq 'Status'){Get-RamdiskLeaseState -Directory $directory|ConvertTo-Json;return}
$path=Join-Path $directory ($Name+'.json')
$mutex=[Threading.Mutex]::new($false,'Global\RamdiskGuardian-v2');$taken=$false
try{
    try{$taken=$mutex.WaitOne([timespan]::FromSeconds(30))}catch [Threading.AbandonedMutexException]{$taken=$true}
    if(-not $taken){throw 'Guardian is running; no consumer lease has been granted.'}
    if($Mode -eq 'Release'){
        $old=Read-RamdiskJson -Path $path
        if($old -and [int]$old.ProcessId -ne $ConsumerProcessId){throw 'The named lease belongs to a different process.'}
        if([IO.File]::Exists($path)){[IO.File]::Delete($path)}
        if([IO.File]::Exists("$path.previous")){[IO.File]::Delete("$path.previous")}
        @{Released=$true;Name=$Name}|ConvertTo-Json;return
    }
    $process=Get-Process -Id $ConsumerProcessId -ErrorAction Stop
    $old=Read-RamdiskJson -Path $path
    if($old -and [datetimeoffset]$old.ExpiresUtc -gt [datetimeoffset]::UtcNow -and [int]$old.ProcessId -ne $ConsumerProcessId){throw 'The named lease is still active for another process.'}
    $value=@{Schema='ramdisk.cache-lease.v1';Name=$Name;ProcessId=$ConsumerProcessId;ProcessStartUtc=$process.StartTime.ToUniversalTime().ToString('o');ExpiresUtc=[datetime]::UtcNow.AddSeconds($Seconds).ToString('o')}
    Write-RamdiskJson -Path $path -Value $value
    Read-RamdiskJson -Path $path|ConvertTo-Json
}finally{if($taken){$mutex.ReleaseMutex()};$mutex.Dispose()}