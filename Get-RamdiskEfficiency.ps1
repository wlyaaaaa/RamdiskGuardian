#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')][string]$DriveLetter='Z',
    [string]$PrimoPath='C:\Program Files\Primo Ramdisk\rxprd.exe',
    [switch]$IncludePrimo,
    [switch]$Json
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(-not $PSBoundParameters.ContainsKey('DriveLetter')){
    $override=Join-Path $PSScriptRoot 'ramdrive.txt'
    if([IO.File]::Exists($override)){
        $DriveLetter=[IO.File]::ReadAllText($override).Trim()
        if($DriveLetter -notmatch '^[A-Za-z]$'){throw 'Invalid configured drive override.'}
    }
}
$DriveLetter=$DriveLetter.ToUpperInvariant()

function ConvertFrom-PrimoDiskView {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][int]$Index)
    $sections=@{};$current=$null
    foreach($line in ($Text -split '[\r\n]+')){
        if($line -match '^Disk #(\d+) (Settings|Status)$'){
            if([int]$Matches[1] -ne $Index){throw 'Unexpected Primo disk identity.'}
            $current=$Matches[2]
            if($sections.ContainsKey($current)){throw 'Duplicate Primo section.'}
            $sections[$current]=@{};continue
        }
        if($current -and $line -match '^([^:]+):\s*(.*)$'){
            $key=$Matches[1].Trim();$value=$Matches[2].Trim()
            if($sections[$current].ContainsKey($key)){throw 'Duplicate Primo field.'}
            $sections[$current][$key]=$value
        }
    }
    foreach($section in @('Settings','Status')){
        if(-not $sections.ContainsKey($section)){throw 'Incomplete Primo settings/status evidence.'}
        foreach($key in @('Memory Features','Disk Size','Enable Image File','Image File Name','Delay Load','Image Format')){
            if(-not $sections[$section].ContainsKey($key)){throw "Missing Primo field: $section/$key"}
        }
        if($sections[$section]['Enable Image File'] -notin @('Yes','No') -or $sections[$section]['Delay Load'] -notin @('Yes','No')){throw 'Unsupported Primo output language or flags.'}
    }
    return $sections
}
function Resolve-PrimoCacheIndex {
    param([Parameter(Mandatory)][string]$Text,[Parameter(Mandatory)][string]$Letter)
    $found=@()
    foreach($line in ($Text -split '[\r\n]+')){
        if($line -match '^#(\d+)\s+\d+\s+\S+\s+\S+\s+(\S+)\s+(.+)$'){
            $index=[int]$Matches[1];$state=$Matches[2];$volumes=@([regex]::Matches($Matches[3],'(?i)[A-Z]:')|ForEach-Object{$_.Value})
            if($volumes -contains ($Letter.ToUpperInvariant()+':')){
                if($state -ne 'Good' -or $volumes.Count -ne 1){throw 'Unhealthy or multi-volume Primo target.'}
                $found+= $index
            }
        }
    }
    if($found.Count -ne 1){throw 'Expected one healthy Primo disk for the selected drive.'}
    return $found[0]
}
function Invoke-PrimoEfficiencyRead {
    param([ValidateSet('ls','view')][string]$Operation,[int]$Index)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$PrimoPath
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    [void]$start.ArgumentList.Add($Operation)
    if($Operation -eq 'view'){[void]$start.ArgumentList.Add([string]$Index)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        [void]$process.Start();$output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(8000)){$process.Kill($true);$process.WaitForExit();throw 'Read-only Primo query timed out.'}
        $text=$output.GetAwaiter().GetResult();$null=$errors.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw ('Read-only Primo query failed with exit '+$process.ExitCode)}
        return $text
    }finally{$process.Dispose()}
}
function Get-RamdiskImageAllocation {
    param([Parameter(Mandatory)][string]$Path)
    if(-not ('RamdiskEfficiencyFileAllocation' -as [type])){
        Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class RamdiskEfficiencyFileAllocation {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern uint GetCompressedFileSizeW(string name,out uint high);
 public static ulong Read(string name){uint high;uint low=GetCompressedFileSizeW(name,out high);if(low==0xffffffff&&Marshal.GetLastWin32Error()!=0)throw new System.ComponentModel.Win32Exception();return ((ulong)high<<32)|low;}
}
'@
    }
    $before=Get-Item -LiteralPath $Path
    $allocated=[RamdiskEfficiencyFileAllocation]::Read($Path)
    $after=Get-Item -LiteralPath $Path
    if($before.Length -ne $after.Length -or $before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc){throw 'Image changed during observation.'}
    return [pscustomobject]@{LogicalBytes=$after.Length;AllocatedBytes=$allocated;LastSavedUtc=$after.LastWriteTimeUtc.ToString('o')}
}
$result=[ordered]@{
    Schema='ramdisk.efficiency.v1';ObservedUtc=[datetime]::UtcNow.ToString('o');WriteMode='zero_write'
    Scope='resource-accounting-not-a-speed-benchmark';Status='observed';Reasons=@()
    Volume=$null;Memory=$null;Primo=@{State='not-requested'};Image=$null
    SpeedupPercent=$null;WorkloadBenchmark='not-performed'
}
$reasons=[Collections.Generic.List[string]]::new()
try{
    $volume=Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
    if($volume.FileSystemLabel -ine 'RAMDISK' -or $volume.FileSystem -ine 'NTFS'){throw 'Unexpected RAM disk identity.'}
    $result.Volume=@{CapacityBytes=$volume.Size;UsedBytes=$volume.Size-$volume.SizeRemaining;FreeBytes=$volume.SizeRemaining;Health=[string]$volume.HealthStatus}
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $result.Memory=@{PhysicalBytes=$os.TotalVisibleMemorySize*1KB;AvailableBytes=$os.FreePhysicalMemory*1KB;DriverAllocatedBytes=$null;DriverAllocationEvidence='not-exposed-by-installed-Primo-CLI; disk capacity and file usage are not allocation measurements'}
}catch{$reasons.Add('volume-or-memory-observation-unavailable')}
if($IncludePrimo){
    try{
        $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Primo read-only CLI requires administrator.'}
        $index=Resolve-PrimoCacheIndex -Text (Invoke-PrimoEfficiencyRead -Operation ls) -Letter $DriveLetter
        $view=ConvertFrom-PrimoDiskView -Text (Invoke-PrimoEfficiencyRead -Operation view -Index $index) -Index $index
        $settings=$view.Settings;$running=$view.Status
        $result.Primo=@{State='observed';Index=$index;ConfiguredMemoryFeatures=$settings['Memory Features'];RunningMemoryFeatures=$running['Memory Features'];ConfiguredImageFormat=$settings['Image Format'];RunningImageFormat=$running['Image Format'];ConfiguredDelayLoad=($settings['Delay Load'] -eq 'Yes');RunningDelayLoad=($running['Delay Load'] -eq 'Yes');ConfigurationMatchesRuntime=($settings['Memory Features'] -ceq $running['Memory Features'])}
        if(-not $result.Primo.ConfigurationMatchesRuntime){$reasons.Add('configured-runtime-memory-features-differ; cause-not-proved')}
        if($running['Enable Image File'] -eq 'Yes'){
            $result.Image=Get-RamdiskImageAllocation -Path $running['Image File Name']
            if($result.Image.LogicalBytes -ge 1GB -and -not $result.Primo.RunningDelayLoad){$reasons.Add('large-eager-loaded-image-review-needed')}
        }
    }catch{$result.Primo=@{State='unknown';Reason=$_.Exception.Message};$reasons.Add('primo-efficiency-evidence-unavailable')}
}
$result.Reasons=@($reasons)
if($reasons.Count){$result.Status='attention'}
if($null -eq $result.Volume){$result.Status='unknown'}
if($Json){[pscustomobject]$result|ConvertTo-Json -Depth 7}else{[pscustomobject]$result}
