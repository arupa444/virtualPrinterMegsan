@echo off
REM Start the receiver simulator (Windows). Uses uv to provision the venv.
setlocal
cd /d "%~dp0"

where uv >nul 2>&1
if %errorlevel% neq 0 (
    echo uv not found. Install it: https://docs.astral.sh/uv/getting-started/installation/
    pause
    exit /b 1
)

uv venv .venv
call .venv\Scripts\activate.bat
uv pip install -r requirements.txt
echo.
python app.py
pause
