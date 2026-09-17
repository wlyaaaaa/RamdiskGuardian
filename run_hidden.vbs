' Hidden launcher. Returns the actual PowerShell 7 result to Task Scheduler.
Option Explicit
Dim fso, here, shell, engine, exitCode
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
engine = "C:\Program Files\PowerShell\7\pwsh.exe"
If WScript.Arguments.Count > 0 Then engine = WScript.Arguments(0)
If Not fso.FileExists(engine) Then WScript.Quit 127
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("""" & engine & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & here & "\zguardian.ps1""", 0, True)
WScript.Quit exitCode