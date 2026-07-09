@echo off
REM ===================================================================
REM  Virtual Cloud Printer - status
REM  Shows the installed monitor, your printers, their URLs, and the
REM  tail of the log so you can confirm jobs are being uploaded.
REM ===================================================================
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action status
echo.
pause
