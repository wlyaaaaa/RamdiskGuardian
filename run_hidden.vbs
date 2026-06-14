' ============================================================
'  Hidden launcher - called by Task "RAMDisk_Code_Backup".
'  Runs the Z: guardian without flashing a CMD window or
'  stealing foreground focus (WindowStyle=0, no wait).
' ============================================================
CreateObject("Wscript.Shell").Run "cmd /c ""E:\RamdiskGuardian\sync_code.bat""", 0, False
