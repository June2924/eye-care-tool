@echo off
set SCRIPT_DIR=%~dp0
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT_DIR%EyeRestWebHost.ps1"
if errorlevel 1 pause
