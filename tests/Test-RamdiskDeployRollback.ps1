#requires -Version 7.0
$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path $PSScriptRoot -Parent) 'deploy.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Restore-RamdiskDeployment'},$true)
if(-not $fn -or $errors.Count){throw 'Missing valid shared deployment rollback.'}
. ([scriptblock]::Create($fn.Extent.Text))
$backup=Join-Path $env:TEMP ('deploy-rollback-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($backup)
try{
 [IO.File]::WriteAllText((Join-Path $backup 'task.xml'),'<Task>fixture-preimage</Task>')
 $taskChanged=$true;$powerChanged=$false;$overrideChanged=$false;$chromeMoves=@();$taskName='fixture-only'
 $journal=@{TaskExisted=$true};$script:registered=$false;$script:removed=$false
 function Register-ScheduledTask {param($TaskName,$Xml,[switch]$Force) if($TaskName -ne 'fixture-only' -or $Xml -notmatch 'fixture-preimage'){throw 'wrong task rollback'};$script:registered=$true}
 function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm) if($TaskName -ne 'fixture-only'){throw 'wrong task removal'};$script:removed=$true}
 try{Restore-RamdiskDeployment -failure 'injected initialization failure'}catch{if($_.Exception.Message -notmatch 'injected initialization failure'){throw}}
 if(-not $script:registered){throw 'Existing task was not restored after initialization failure.'}
 $journal.TaskExisted=$false
 try{Restore-RamdiskDeployment -failure 'injected registration failure'}catch{if($_.Exception.Message -notmatch 'injected registration failure'){throw}}
 if(-not $script:removed){throw 'New task was not removed on rollback.'}
 $calls=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Restore-RamdiskDeployment'},$true))
 if($calls.Count -ne 2){throw 'Installation and post-install initialization must share rollback.'}
 'PASS: existing-task restore, new-task removal and both failure entrypoints use the production rollback; no real task changed.'
}finally{Remove-Item -LiteralPath $backup -Recurse -Force}