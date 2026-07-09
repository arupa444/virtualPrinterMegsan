@echo off
REM ===================================================================
REM  Virtual Cloud Printer - uninstaller
REM  Removes every virtual printer created by this tool, the shared
REM  redirection port, and the files under %ProgramData%.
REM  (Ghostscript, uv and the port monitor are left installed.)
REM ===================================================================
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 goto :elevate

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action uninstall
echo.
pause
exit /b

:elevate
echo Requesting Administrator privileges...
set "SELF=%~f0"
powershell -NoProfile -Command "Start-Process -FilePath '%SELF:'=''%' -Verb RunAs"
exit /b
