' ============================================================
'  Hidden launcher - called by Task "RAMDisk_Code_Backup".
'  Runs the guardian without a CMD window / focus stealing.
'  Portable: derives its own folder, so it works from any path.
' ============================================================
Dim fso, here
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("Wscript.Shell").Run "cmd /c """ & here & "\sync_code.bat""", 0, False
