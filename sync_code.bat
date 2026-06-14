@echo off
rem =====================================================================
rem  Entry called by run_hidden.vbs (Task: RAMDisk_Code_Backup).
rem  Delegates everything to the guardian PowerShell script.
rem =====================================================================
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "E:\RamdiskGuardian\zguardian.ps1"
exit /b 0
