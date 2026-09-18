#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-RamdiskEfficiency.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Efficiency entrypoint has syntax errors.'}
foreach($name in @('ConvertFrom-PrimoDiskView','Resolve-PrimoCacheIndex','Get-RamdiskImageAllocation')){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'Production function missing or duplicated.'}
 . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$script:checks=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw "FAIL: $Message"};$script:checks++;Write-Host "PASS: $Message"}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
$listing="Index Size(MB) Type Image Status Volumes`r`n#3 12288 SCSI Yes Good Z: `r`n"
Check ((Resolve-PrimoCacheIndex -Text $listing -Letter z) -eq 3) 'drive mapping resolves actual index instead of assuming disk zero'
Reject {Resolve-PrimoCacheIndex -Text ($listing+"#4 12288 SCSI Yes Good Z:`n") -Letter Z} 'ambiguous mappings fail closed'
Reject {Resolve-PrimoCacheIndex -Text '#3 12288 SCSI Yes Good Z: Y:' -Letter Z} 'multi-volume target is rejected'
Reject {Resolve-PrimoCacheIndex -Text '#3 12288 SCSI Yes Error Z:' -Letter Z} 'unhealthy target is rejected'
Reject {Resolve-PrimoCacheIndex -Text $listing -Letter X} 'missing selected drive is not a successful empty result'
$view=@'
Disk #3 Settings
Disk Size: 12288 MB
Memory Features: DMM Compact
Enable Image File: Yes
Image File Name: E:\Fixture\Z.vdf
Delay Load: No
Image Format: Compact Image
Disk #3 Status
Disk Size: 12288 MB
Memory Features: DMM
Enable Image File: Yes
Image File Name: E:\Fixture\Z.vdf
Delay Load: No
Image Format: Compact Image
'@
$parsed=ConvertFrom-PrimoDiskView -Text $view -Index 3
Check ($parsed.Settings['Memory Features'] -ceq 'DMM Compact' -and $parsed.Status['Memory Features'] -ceq 'DMM') 'saved Compact and current DMM are kept as distinct observations'
Check ($parsed.Status['Image File Name'] -ceq 'E:\Fixture\Z.vdf') 'path colon survives key-value parsing'
Reject {ConvertFrom-PrimoDiskView -Text $view -Index 0} 'unexpected disk identity is rejected'
Reject {ConvertFrom-PrimoDiskView -Text ($view.Replace('Disk #3 Status','not a status section')) -Index 3} 'missing runtime section is not inferred from saved configuration'
Reject {ConvertFrom-PrimoDiskView -Text ($view+"`nMemory Features: DMM") -Index 3} 'duplicate runtime fields are not silently overwritten'
Reject {ConvertFrom-PrimoDiskView -Text ($view.Replace('Delay Load: No','Delay Load: Unknown')) -Index 3} 'unrecognized flags are not converted into false'
$source=[IO.File]::ReadAllText($path)
Check ($source -match 'DriverAllocatedBytes=\$null' -and $source -match 'SpeedupPercent=\$null') 'driver memory and acceleration remain unmeasured, not equal to disk capacity'
Check ($source -match "ValidateSet\('ls','view'\)") 'native command entry only admits readonly ls and view'
$fixture=Join-Path $env:TEMP ('ramdisk-allocation-'+[guid]::NewGuid().ToString('N')+'.bin')
try{
 [IO.File]::WriteAllBytes($fixture,[byte[]]::new(12345))
 $before=Get-Item $fixture;$hash=(Get-FileHash $fixture).Hash
 $allocation=Get-RamdiskImageAllocation -Path $fixture
 Check ($allocation.LogicalBytes -eq 12345 -and $allocation.AllocatedBytes -gt 0) 'actual allocation and logical length are read independently'
 Check ((Get-FileHash $fixture).Hash -ceq $hash -and (Get-Item $fixture).LastWriteTimeUtc -eq $before.LastWriteTimeUtc) 'allocation inspection does not mutate file bytes or last-write time'
}finally{if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Force}}
Write-Host "PASS: $script:checks efficiency checks; no real image read or disk mutation."
