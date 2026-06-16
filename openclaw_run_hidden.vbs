' ============================================================
'  OpenClaw Gateway - Silent Hidden Launcher
'  Called by the "OpenClaw Gateway" scheduled task at boot.
'  Runs gateway.cmd with ZERO window visibility (windowStyle=0).
' ============================================================
Dim shell
Set shell = CreateObject("WScript.Shell")
shell.Run """C:\Users\10979\.openclaw\gateway.cmd""", 0, False
Set shell = Nothing
