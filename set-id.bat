@echo off
REM ===================================================================
REM  Set Print ID
REM  Double-click BEFORE printing to set a registration number / UUID
REM  that gets attached to your next print job(s). No admin needed.
REM  (Requires that install.bat has already been run once.)
REM ===================================================================
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0set-id.ps1"
