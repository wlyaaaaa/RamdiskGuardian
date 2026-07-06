' ============================================================
'  Hidden launcher - called by Task "RAMDisk_Code_Backup".
'  Runs the guardian without a CMD window / focus stealing.
'  Portable: derives its own folder, so it works from any path.
' ============================================================
Dim fso, here, shell, exitCode
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\zguardian.ps1""", 0, True)
WScript.Quit exitCode
