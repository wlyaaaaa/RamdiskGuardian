@echo off
rem =====================================================================
rem  Entry called by run_hidden.vbs (Task: RAMDisk_Code_Backup).
rem  Portable: %~dp0 = this script's own folder, so it works no matter
rem  where the repo lives (E:\, D:\, after a reinstall, etc.).
rem =====================================================================
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0zguardian.ps1"
exit /b 0
