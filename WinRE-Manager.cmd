@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinRE-Manager.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo WinRE-Manager finished with error code %RC%.
pause
exit /b %RC%
