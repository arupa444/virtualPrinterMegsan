@echo off
REM ===================================================================
REM  Virtual Cloud Printer - add another printer
REM  Double-click to create an additional virtual printer that points
REM  at its own URL. You will be asked for the printer name and URL.
REM  (Requires that install.bat has already been run once.)
REM ===================================================================
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 goto :elevate

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action add
echo.
pause
exit /b

:elevate
echo Requesting Administrator privileges...
set "SELF=%~f0"
powershell -NoProfile -Command "Start-Process -FilePath '%SELF:'=''%' -Verb RunAs"
exit /b
