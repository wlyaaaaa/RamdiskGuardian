#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][ValidateSet('Pause','Resume','Status')][string]$Mode,[switch]$Apply,[switch]$Json)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ramdisk-guardian.psm1') -Force
$path=Join-Path $PSScriptRoot 'logs\recovery-control.json'
$before=Read-RamdiskJson -Path $path -Default @{Paused=$false}
$result=[ordered]@{Mode=$Mode;Applied=$false;BeforePaused=$before.Paused;AfterPaused=$before.Paused;Effect='Only automatic RAM disk reinitialization is paused; directory upkeep and health checks remain enabled.'}
if($Mode -ne 'Status'){
    $result.AfterPaused=($Mode -eq 'Pause')
    if($Apply -and $PSCmdlet.ShouldProcess('RamdiskGuardian auto recovery',$Mode)){
        Write-RamdiskJson -Path $path -Value @{Schema='ramdisk.recovery-control.v1';Paused=$result.AfterPaused;UpdatedUtc=[datetime]::UtcNow.ToString('o')}
        $actual=Read-RamdiskJson -Path $path
        if($actual.Paused -ne $result.AfterPaused){throw 'Recovery control readback mismatch.'}
        $result.Applied=$true
    }
}
if($Json){[pscustomobject]$result|ConvertTo-Json}else{[pscustomobject]$result}