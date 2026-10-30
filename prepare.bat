@echo off
rem Phone kit - prepare the folder once on the master PC: ADB for Windows and Mac, PowerShell for Mac.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phonekit.ps1" -Prepare
if errorlevel 1 pause
