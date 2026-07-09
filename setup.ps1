<#
    Virtual Cloud Printer - setup / manager
    =======================================
    Creates Windows virtual printers that convert every print job to a PDF and
    POST it (multipart/form-data: docname + file) to a per-printer HTTPS URL.

    It wires together:
      * mfilemon (or clawmon) print-port monitor   -> captures the job
      * Microsoft PS Class Driver                  -> emits PostScript
      * Ghostscript                                -> PostScript -> PDF
      * uv-managed Python + upload.py              -> converts & uploads

    Usage (normally launched by the .bat wrappers, which handle elevation):
      powershell -ExecutionPolicy Bypass -File setup.ps1 -Action install
      powershell -ExecutionPolicy Bypass -File setup.ps1 -Action add     -PrinterName "Invoices" -Url "https://.../invoices"
      powershell -ExecutionPolicy Bypass -File setup.ps1 -Action uninstall
      powershell -ExecutionPolicy Bypass -File setup.ps1 -Action status
#>

[CmdletBinding()]
param(
    [ValidateSet('install', 'add', 'uninstall', 'status')]
    [string]$Action = 'install',
    [string]$PrinterName = '',
    [string]$Url = '',
    [switch]$RemoveTools    # uninstall: also remove the shared port monitor
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
$Base          = Join-Path $env:ProgramData 'VirtualCloudPrinter'
$SpoolDir      = Join-Path $Base 'spool'
$FailedDir     = Join-Path $Base 'failed'
$VenvDir       = Join-Path $Base 'venv'
$PythonDir     = Join-Path $Base 'python'
$ConfigPath    = Join-Path $Base 'config.json'
$UploadScript  = Join-Path $Base 'upload.py'
$PythonwPath   = Join-Path $VenvDir 'Scripts\pythonw.exe'

$PortName      = 'VirtualCloudPrinter:'
$DriverName    = 'Microsoft PS Class Driver'
$MonitorsKey   = 'SYSTEM\CurrentControlSet\Control\Print\Monitors'
$ClawmonName   = 'clawmon printer port monitor'
$MfilemonName  = 'Multi File Port Monitor'
$MfilemonUrl   = 'https://sourceforge.net/projects/mfilemon/files/1.5.2/mfilemon-setup.exe/download'

$ScriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$VendorDir     = Join-Path $ScriptDir 'vendor'

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "    $m" -ForegroundColor Gray }
function Write-Warn2{ param($m) Write-Host "    [!] $m" -ForegroundColor Yellow }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator. Right-click install.bat -> Run as administrator.'
    }
}

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($m, $u | Where-Object { $_ }) -join ';'
}

function Test-Monitor { param($name) Test-Path "Registry::HKEY_LOCAL_MACHINE\$MonitorsKey\$name" }

function Resolve-Exe {
    # Return a full path to an executable if reachable via PATH or the given candidates.
    param([string]$Name, [string[]]$Candidates = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in $Candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# --------------------------------------------------------------------------- #
# Dependency installers
# --------------------------------------------------------------------------- #
function Get-Uv {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.local\bin\uv.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\uv.exe')
    )
    Refresh-Path
    $uv = Resolve-Exe 'uv' $candidates
    if ($uv) { return $uv }

    Write-Info 'uv not found - installing...'
    # winget is a native exe: a failed install returns non-zero but does NOT throw,
    # so never assume success - always re-check and fall through if still missing.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            winget install --id astral-sh.uv -e --silent `
                --accept-source-agreements --accept-package-agreements | Out-Null
        } catch { Write-Warn2 "winget install of uv failed: $($_.Exception.Message)" }
        Refresh-Path
        $uv = Resolve-Exe 'uv' $candidates
        if ($uv) { return $uv }
    }

    Write-Info 'Falling back to the standalone uv installer (astral.sh)...'
    powershell -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex" | Out-Null
    Refresh-Path
    $uv = Resolve-Exe 'uv' $candidates
    if (-not $uv) { throw 'uv could not be installed. Install it manually from https://docs.astral.sh/uv/ and re-run.' }
    return $uv
}

function Find-GsExe {
    # Return the newest Ghostscript console exe, choosing by NUMERIC version
    # (so gs10.x beats gs9.x, which a plain string sort gets wrong).
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        $gsDir = Join-Path $root 'gs'
        if (-not (Test-Path $gsDir)) { continue }
        $found = Get-ChildItem -Path $gsDir -Recurse -Filter 'gswin*c.exe' -ErrorAction SilentlyContinue |
            Sort-Object { try { [version](($_.Directory.Parent.Name) -replace '[^0-9.]', '') } catch { [version]'0.0' } } -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Get-Ghostscript {
    $gs = Find-GsExe
    if ($gs) { return $gs }

    Write-Info 'Ghostscript not found - installing...'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            winget install --id ArtifexSoftware.GhostScript -e --silent `
                --accept-source-agreements --accept-package-agreements | Out-Null
        } catch { Write-Warn2 "winget install of Ghostscript failed: $($_.Exception.Message)" }
        $gs = Find-GsExe
        if ($gs) { return $gs }
    }

    # Fallback: download the official Ghostscript installer from GitHub.
    Write-Info 'Downloading Ghostscript installer from GitHub...'
    try {
        $rel = Invoke-RestMethod -UseBasicParsing `
            -Uri 'https://api.github.com/repos/ArtifexSoftware/ghostpdl-downloads/releases/latest' `
            -Headers @{ 'User-Agent' = 'VirtualCloudPrinter' }
        $asset = $rel.assets | Where-Object { $_.name -match 'gs\d+w64\.exe$' } | Select-Object -First 1
        if ($asset) {
            $tmp = Join-Path $env:TEMP $asset.name
            Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $tmp
            Write-Info "Running $($asset.name) /S ..."
            Start-Process -FilePath $tmp -ArgumentList '/S' -Wait
        }
    } catch { Write-Warn2 "Ghostscript download failed: $($_.Exception.Message)" }

    $gs = Find-GsExe
    if (-not $gs) { throw 'Ghostscript could not be installed. Install it from https://ghostscript.com/releases/ and re-run.' }
    return $gs
}

function Ensure-Monitor {
    if (Test-Monitor $ClawmonName)  { Write-Ok "Port monitor present: $ClawmonName";  return $ClawmonName }
    if (Test-Monitor $MfilemonName) { Write-Ok "Port monitor present: $MfilemonName"; return $MfilemonName }

    # Prefer clawmon binaries if the user dropped them in .\vendor\.
    $clawDll   = Join-Path $VendorDir 'clawmon.dll'
    $clawUiDll = Join-Path $VendorDir 'clawmonui.dll'
    $regmon    = Join-Path $VendorDir 'regmon.exe'
    if ((Test-Path $clawDll) -and (Test-Path $clawUiDll) -and (Test-Path $regmon)) {
        Write-Info 'Installing clawmon from .\vendor\ ...'
        Stop-Service -Name Spooler -Force
        Copy-Item $clawDll   (Join-Path $env:WINDIR 'system32\clawmon.dll')   -Force
        Copy-Item $clawUiDll (Join-Path $env:WINDIR 'system32\clawmonui.dll') -Force
        Start-Service -Name Spooler
        & $regmon -r | Out-Null
        if (Test-Monitor $ClawmonName) { Write-Ok "Installed $ClawmonName"; return $ClawmonName }
        Write-Warn2 'clawmon registration did not take; falling back to mfilemon.'
    }

    # Otherwise download and silently install mfilemon (identical interface).
    Write-Info 'Downloading mfilemon-setup.exe ...'
    $setup = Join-Path $env:TEMP 'mfilemon-setup.exe'
    Invoke-WebRequest -UseBasicParsing -Uri $MfilemonUrl -OutFile $setup
    Write-Info 'Installing mfilemon silently (/S) ...'
    Start-Process -FilePath $setup -ArgumentList '/S' -Wait
    Start-Sleep -Seconds 2
    if (Test-Monitor $MfilemonName) { Write-Ok "Installed $MfilemonName"; return $MfilemonName }
    throw "Could not install a print-port monitor. Install mfilemon manually ($MfilemonUrl) or drop clawmon binaries into $VendorDir, then re-run."
}

# --------------------------------------------------------------------------- #
# Port (registry) + printer + config
# --------------------------------------------------------------------------- #
function Set-Port {
    param([string]$Monitor)

    # -P keeps the script's own directory off sys.path[0] so a planted sibling
    # module can never be imported ahead of the stdlib (defense in depth with the
    # $Base ACL). It is an interpreter flag, so upload.py's argv is unchanged.
    $userCommand = ('"{0}" -P "{1}" "%f" "%j" "%r" "%t"' -f $PythonwPath, $UploadScript)

    Write-Info "Creating port '$PortName' under monitor '$Monitor' (spooler will restart)..."
    Stop-Service -Name Spooler -Force

    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    $monKey = $hklm.OpenSubKey("$MonitorsKey\$Monitor", $true)
    if (-not $monKey) { Start-Service -Name Spooler; throw "Monitor key not found for '$Monitor'." }
    try {
        $p = $monKey.CreateSubKey($PortName)
        try {
            $S = [Microsoft.Win32.RegistryValueKind]::String
            $D = [Microsoft.Win32.RegistryValueKind]::DWord
            $p.SetValue('OutputPath',      $SpoolDir,                       $S)
            $p.SetValue('FilePattern',     '%Y-%m-%d_%H-%n-%s_%i.ps',       $S)
            $p.SetValue('Overwrite',       0,                                $D)
            $p.SetValue('UserCommand',     $userCommand,                     $S)
            $p.SetValue('ExecPath',        $Base,                            $S)
            $p.SetValue('WaitTermination', 0,                                $D)
            $p.SetValue('WaitTimeout',     0,                                $D)
            $p.SetValue('PipeData',        0,                                $D)
            $p.SetValue('HideProcess',     1,                                $D)
            $p.SetValue('User',            '',                               $S)
            $p.SetValue('Domain',          '',                               $S)
            $p.SetValue('Password',        '',                               $S)
        } finally { $p.Close() }
    } finally { $monKey.Close() }

    Start-Service -Name Spooler
    Start-Sleep -Seconds 2
    Write-Ok "Port '$PortName' configured."
}

function Remove-Port {
    param([string]$Monitor)
    Stop-Service -Name Spooler -Force
    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    $monKey = $hklm.OpenSubKey("$MonitorsKey\$Monitor", $true)
    if ($monKey) {
        try { $monKey.DeleteSubKeyTree($PortName, $false) } catch {}
        $monKey.Close()
    }
    Start-Service -Name Spooler
}

function Get-ActiveMonitor {
    if (Test-Monitor $ClawmonName)  { return $ClawmonName }
    if (Test-Monitor $MfilemonName) { return $MfilemonName }
    return $null
}

function Update-Config {
    param([string]$Name, [string]$TargetUrl, [string]$GsPath)

    if (Test-Path $ConfigPath) {
        $cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
    } else {
        $cfg = Get-Content -Raw -Path (Join-Path $ScriptDir 'config.template.json') | ConvertFrom-Json
    }

    if ($GsPath) { $cfg.ghostscript_path = $GsPath }

    if (-not $cfg.printers) {
        $cfg | Add-Member -NotePropertyName printers -NotePropertyValue (New-Object PSObject) -Force
    }

    if ($Name) {
        $entry = [PSCustomObject]@{
            url           = $TargetUrl
            docname_field = 'docname'
            file_field    = 'file'
            extra_fields  = (New-Object PSObject)
            headers       = (New-Object PSObject)
            verify_tls    = $true
        }
        # Overwrite / add this printer's entry.
        if ($cfg.printers.PSObject.Properties[$Name]) {
            $cfg.printers.$Name = $entry
        } else {
            $cfg.printers | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
        }
        # Drop the placeholder sample if it is still present and unused.
        if ($Name -ne 'Virtual Cloud Printer' -and $cfg.printers.PSObject.Properties['Virtual Cloud Printer']) {
            $sample = $cfg.printers.'Virtual Cloud Printer'
            if ($sample.url -eq 'https://example.com/print-upload') {
                $cfg.printers.PSObject.Properties.Remove('Virtual Cloud Printer')
            }
        }
    }

    # Write UTF-8 WITHOUT a BOM. Windows PowerShell 5.1's `Set-Content -Encoding
    # UTF8` prepends a BOM, which makes Python's json.load in upload.py fail, so
    # use .NET to control the encoding explicitly.
    [System.IO.File]::WriteAllText(
        $ConfigPath,
        ($cfg | ConvertTo-Json -Depth 12),
        (New-Object System.Text.UTF8Encoding($false))
    )
    Write-Ok "config.json updated ($ConfigPath)."
}

function Add-VirtualPrinter {
    param([string]$Name, [string]$TargetUrl)

    if (-not (Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue)) {
        Write-Info "Adding printer driver '$DriverName'..."
        Add-PrinterDriver -Name $DriverName
    }

    $existing = Get-Printer -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Info "Printer '$Name' already exists - pointing it at our port."
        Set-Printer -Name $Name -PortName $PortName -ErrorAction SilentlyContinue
    } else {
        Write-Info "Creating printer '$Name'..."
        Add-Printer -Name $Name -DriverName $DriverName -PortName $PortName
    }
    Write-Ok "Printer '$Name' -> $TargetUrl"
}

function Read-PrinterAndUrl {
    if (-not $PrinterName) {
        $script:PrinterName = Read-Host 'Printer name (as it will appear in the print dialog)'
    }
    if (-not $Url) {
        $script:Url = Read-Host 'Target HTTPS URL for this printer'
    }
    if (-not $PrinterName) { throw 'A printer name is required.' }
    if (-not $Url)         { throw 'A URL is required.' }
    if ($Url -notmatch '^(?i)https?://') {
        Write-Warn2 "URL '$Url' does not start with http:// or https:// - continuing anyway."
    }
}

# --------------------------------------------------------------------------- #
# Actions
# --------------------------------------------------------------------------- #
function Do-Install {
    Assert-Admin
    Write-Host 'Virtual Cloud Printer - installer' -ForegroundColor White
    Read-PrinterAndUrl

    Write-Step 'Preparing folders'
    foreach ($d in @($Base, $SpoolDir, $FailedDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

    # SECURITY: lock $Base down to SYSTEM + Administrators only.
    # upload.py runs as SYSTEM from here; the default C:\ProgramData ACL lets any
    # user create files in child folders, so without this a standard user could
    # plant a sibling module (ssl.py/json.py/...) that Python imports ahead of the
    # stdlib and runs as SYSTEM (local privilege escalation). It also stops other
    # users reading config.json (which may hold auth headers) and log.txt.
    & icacls "$Base" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null

    Copy-Item (Join-Path $ScriptDir 'upload.py') $UploadScript -Force
    if (-not (Test-Path $ConfigPath)) {
        Copy-Item (Join-Path $ScriptDir 'config.template.json') $ConfigPath -Force
    }
    Write-Ok "Installed to $Base"

    Write-Step 'Ensuring uv + Python virtual environment'
    $uv = Get-Uv
    Write-Ok "uv: $uv"
    $env:UV_PYTHON_INSTALL_DIR = $PythonDir
    & $uv venv --python 3.12 $VenvDir
    if (-not (Test-Path $PythonwPath)) {
        $pyExe = Join-Path $VenvDir 'Scripts\python.exe'
        if (Test-Path $pyExe) {
            $script:PythonwPath = $pyExe
            Write-Warn2 'pythonw.exe not found in venv; using python.exe instead.'
        } else {
            throw "Virtual environment python not found in $VenvDir\Scripts"
        }
    }
    Write-Ok "venv: $VenvDir ($PythonwPath)"

    Write-Step 'Ensuring Ghostscript'
    $gs = Get-Ghostscript
    Write-Ok "Ghostscript: $gs"

    Write-Step 'Ensuring print-port monitor'
    $monitor = Ensure-Monitor

    Write-Step 'Creating the redirection port'
    Set-Port -Monitor $monitor

    Write-Step 'Writing configuration'
    Update-Config -Name $PrinterName -TargetUrl $Url -GsPath $gs

    Write-Step 'Creating the printer'
    Add-VirtualPrinter -Name $PrinterName -TargetUrl $Url

    Write-Host "`nDONE." -ForegroundColor Green
    Write-Host "Printer '$PrinterName' is ready and will POST PDFs to:`n    $Url" -ForegroundColor Green
    Write-Host "Add more printers later with add-printer.bat. Logs: $Base\log.txt" -ForegroundColor Gray
}

function Do-Add {
    Assert-Admin
    if (-not (Test-Path $UploadScript)) {
        throw 'Virtual Cloud Printer is not installed yet. Run install.bat first.'
    }
    $monitor = Get-ActiveMonitor
    if (-not $monitor) { throw 'Port monitor missing. Run install.bat first.' }
    Read-PrinterAndUrl

    # Make sure the shared port still exists (it is reused by every printer).
    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    $exists = $hklm.OpenSubKey("$MonitorsKey\$monitor\$PortName")
    if ($exists) { $exists.Close() } else { Set-Port -Monitor $monitor }

    $gs = ''
    if (Test-Path $ConfigPath) {
        try { $gs = (Get-Content -Raw $ConfigPath | ConvertFrom-Json).ghostscript_path } catch {}
    }
    Update-Config -Name $PrinterName -TargetUrl $Url -GsPath $gs
    Add-VirtualPrinter -Name $PrinterName -TargetUrl $Url
    Write-Host "`nAdded printer '$PrinterName' -> $Url" -ForegroundColor Green
}

function Do-Uninstall {
    Assert-Admin
    Write-Step 'Removing virtual printers'
    Get-Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.PortName -eq $PortName } |
        ForEach-Object {
            Write-Info "Removing printer '$($_.Name)'"
            Remove-Printer -Name $_.Name -ErrorAction SilentlyContinue
        }

    Write-Step 'Removing the redirection port'
    $monitor = Get-ActiveMonitor
    if ($monitor) { Remove-Port -Monitor $monitor }

    Write-Step 'Removing files'
    if (Test-Path $Base) { Remove-Item -Recurse -Force $Base -ErrorAction SilentlyContinue }

    if ($RemoveTools -and $monitor -eq $MfilemonName) {
        Write-Warn2 'Leaving the mfilemon monitor installed (uninstall it from Add/Remove Programs if desired).'
    }
    Write-Host "`nUninstalled. (Ghostscript, uv and the port monitor were left installed for reuse.)" -ForegroundColor Green
}

function Do-Status {
    Write-Host 'Virtual Cloud Printer - status' -ForegroundColor White
    $monitor = Get-ActiveMonitor
    Write-Host "Port monitor : $(if($monitor){$monitor}else{'NOT INSTALLED'})"
    Write-Host "Install dir  : $Base $(if(Test-Path $Base){'(present)'}else{'(missing)'})"
    Write-Host "Config       : $ConfigPath"
    Write-Host "`nPrinters on our port:" -ForegroundColor Cyan
    Get-Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.PortName -eq $PortName } |
        ForEach-Object { Write-Host ("  - {0}" -f $_.Name) }
    if (Test-Path $ConfigPath) {
        Write-Host "`nConfigured URLs:" -ForegroundColor Cyan
        $cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
        $cfg.printers.PSObject.Properties | ForEach-Object {
            Write-Host ("  - {0,-30} {1}" -f $_.Name, $_.Value.url)
        }
    }
    $log = Join-Path $Base 'log.txt'
    if (Test-Path $log) {
        Write-Host "`nLast log lines:" -ForegroundColor Cyan
        Get-Content $log -Tail 12 | ForEach-Object { Write-Host "  $_" }
    }
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
try {
    switch ($Action) {
        'install'   { Do-Install }
        'add'       { Do-Add }
        'uninstall' { Do-Uninstall }
        'status'    { Do-Status }
    }
    exit 0
} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
