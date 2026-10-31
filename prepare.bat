@echo off
rem Phone kit - prepare the folder once on the master PC: ADB for Windows and Mac, PowerShell for Mac.
cd /d "%~dp0"
rem Windows 7 without updates has PowerShell 2.0 - too old. Windows 8 (PowerShell 3.0) and newer are fine.
where powershell >nul 2>nul
if errorlevel 1 goto nops
powershell -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 3) { exit 3 }"
if errorlevel 3 goto oldps
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0phonekit.ps1" -Prepare
if errorlevel 1 pause
goto :eof
:nops
echo.
echo  Windows PowerShell not found. / PowerShell ne naiden.
echo  Install WMF 5.1: https://aka.ms/wmf51download
echo.
pause
exit /b 1
:oldps
echo.
echo  PowerShell 2.0 is too old (needs 3.0+). / PowerShell 2.0 slishkom staryi (nuzhen 3.0+).
echo  Windows 7 SP1 / 8.1: install WMF 5.1 - https://aka.ms/wmf51download
echo.
pause
exit /b 1
