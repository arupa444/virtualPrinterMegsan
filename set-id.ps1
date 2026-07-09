<#
    Set Print ID
    ============
    A tiny helper the person running it (a NORMAL user - no admin needed) uses to
    set a registration number / UUID that will be attached to their next print
    job(s). It writes ids\<user>.id under %ProgramData%\VirtualCloudPrinter, which
    the uploader (running as SYSTEM) reads and sends to your URL as its own field.

    Launched by set-id.bat. Runs in the user's own session so the dialog shows.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Base   = Join-Path $env:ProgramData 'VirtualCloudPrinter'
$IdsDir = Join-Path $Base 'ids'
$safe   = ($env:USERNAME -replace '[^A-Za-z0-9._-]', '_')
$File   = Join-Path $IdsDir ($safe + '.id')

if (-not (Test-Path $IdsDir)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Virtual Cloud Printer is not installed yet (no ids folder).`nRun install.bat first.",
        "Set Print ID", 'OK', 'Warning') | Out-Null
    return
}

# Load any current value.
$curId = ''; $curOnce = $true
if (Test-Path $File) {
    try {
        $obj = Get-Content -Raw $File | ConvertFrom-Json
        $curId = [string]$obj.id
        if ($null -ne $obj.once) { $curOnce = [bool]$obj.once }
    } catch { $curId = (Get-Content -Raw $File).Trim() }
}

# --- build the form ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Set Print ID'
$form.Size = New-Object System.Drawing.Size(460, 250)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false; $form.MinimizeBox = $false

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text = "Registration number / UUID to attach to your next print(s):"
$lbl.Location = New-Object System.Drawing.Point(15, 15)
$lbl.Size = New-Object System.Drawing.Size(420, 20)
$form.Controls.Add($lbl)

$txt = New-Object System.Windows.Forms.TextBox
$txt.Location = New-Object System.Drawing.Point(15, 40)
$txt.Size = New-Object System.Drawing.Size(300, 25)
$txt.Text = $curId
$form.Controls.Add($txt)

$btnGen = New-Object System.Windows.Forms.Button
$btnGen.Text = 'New UUID'
$btnGen.Location = New-Object System.Drawing.Point(325, 39)
$btnGen.Size = New-Object System.Drawing.Size(105, 26)
$btnGen.Add_Click({ $txt.Text = [guid]::NewGuid().ToString() })
$form.Controls.Add($btnGen)

$chk = New-Object System.Windows.Forms.CheckBox
$chk.Text = 'Apply to the next print only (otherwise keep until I change it)'
$chk.Location = New-Object System.Drawing.Point(15, 78)
$chk.Size = New-Object System.Drawing.Size(420, 22)
$chk.Checked = $curOnce
$form.Controls.Add($chk)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(15, 108)
$status.Size = New-Object System.Drawing.Size(420, 20)
$status.ForeColor = [System.Drawing.Color]::DimGray
if ($curId) { $status.Text = "Current: $curId" } else { $status.Text = "No ID currently set." }
$form.Controls.Add($status)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save'
$btnSave.Location = New-Object System.Drawing.Point(120, 150)
$btnSave.Size = New-Object System.Drawing.Size(90, 30)
$btnSave.Add_Click({
    $val = $txt.Text.Trim()
    if (-not $val) {
        [System.Windows.Forms.MessageBox]::Show("Enter an ID or click Clear.", "Set Print ID", 'OK', 'Information') | Out-Null
        return
    }
    $json = (@{ id = $val; once = [bool]$chk.Checked } | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText($File, $json, (New-Object System.Text.UTF8Encoding($false)))
    $mode = if ($chk.Checked) { "next print only" } else { "until you change it" }
    [System.Windows.Forms.MessageBox]::Show("Saved: $val`n($mode)`n`nNow print your document.", "Set Print ID", 'OK', 'Information') | Out-Null
    $form.Close()
})
$form.Controls.Add($btnSave)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear'
$btnClear.Location = New-Object System.Drawing.Point(220, 150)
$btnClear.Size = New-Object System.Drawing.Size(90, 30)
$btnClear.Add_Click({
    if (Test-Path $File) { Remove-Item $File -Force -ErrorAction SilentlyContinue }
    [System.Windows.Forms.MessageBox]::Show("Cleared. No ID will be attached.", "Set Print ID", 'OK', 'Information') | Out-Null
    $form.Close()
})
$form.Controls.Add($btnClear)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(320, 150)
$btnCancel.Size = New-Object System.Drawing.Size(90, 30)
$btnCancel.Add_Click({ $form.Close() })
$form.Controls.Add($btnCancel)

$form.AcceptButton = $btnSave
$form.Topmost = $true
[void]$form.ShowDialog()
