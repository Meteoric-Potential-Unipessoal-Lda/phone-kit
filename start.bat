@echo off
rem Phone kit - start (Windows). Double-click.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phonekit.ps1" %*
if errorlevel 1 pause
