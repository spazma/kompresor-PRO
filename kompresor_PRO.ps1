# Kompresor PRO (PowerShell + ffmpeg) - zmiany: auto-save folders, archive folder UI, ensure-folder prompt

Remove-Variable pad,labelW,textW,btnW,leftX,btnRightX,txtInputX,btnBrowseInX,txtOutputX,btnBrowseOutX -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- Helpers ----------
function Get-ScriptBaseDirectory {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    try { return (Get-Location).Path } catch { return $env:USERPROFILE }
}

# Resolve ffmpeg/ffprobe (script folder preferred)
$scriptDir = Get-ScriptBaseDirectory
$candidateFfmpeg  = if ($scriptDir) { Join-Path $scriptDir 'ffmpeg.exe' } else { 'ffmpeg.exe' }
$candidateFfprobe = if ($scriptDir) { Join-Path $scriptDir 'ffprobe.exe' } else { 'ffprobe.exe' }
$ffmpegExe  = if (Test-Path $candidateFfmpeg)  { $candidateFfmpeg } else { 'ffmpeg' }
$ffprobeExe = if (Test-Path $candidateFfprobe) { $candidateFfprobe } else { 'ffprobe' }

$global:gpuOk = $false
$global:AvailableEncoders = @{}

# settings file path (in script dir)
$baseDirGlobal = Get-ScriptBaseDirectory
$settingsFileGlobal = Join-Path $baseDirGlobal 'kompresor_settings.json'

function Log {
    param([string]$Text)
    if ($rtLog) {
        $ts = (Get-Date).ToString('HH:mm:ss')
        $rtLog.AppendText("[$ts] $Text`r`n")
        $rtLog.SelectionStart = $rtLog.TextLength
        $rtLog.ScrollToCaret()
    } else {
        Write-Host $Text
    }
}

function Save-Settings {
    param()
    try {
        $data = @{
            DefaultInput = $txtInput.Text
            DefaultOutput = $txtOutput.Text
            DefaultArchive = $txtArchive.Text
        }
        $json = $data | ConvertTo-Json -Depth 4
        $json | Set-Content -Path $settingsFileGlobal -Encoding UTF8
    } catch {
        Log "Nie udało się zapisać settings: $($_.Exception.Message)"
    }
}

function Ensure-FolderExists {
    param(
        [string]$Path,
        [bool]$PromptIfMissing = $true
    )
    if ($null -eq $Path -or $Path -eq '') { return $false }
    if (Test-Path $Path) { return $true }
    if (-not $PromptIfMissing) {
        try { New-Item -ItemType Directory -Path $Path -Force | Out-Null; return (Test-Path $Path) } catch { return $false }
    }

    $msg = "Katalog `"$Path`" nie istnieje. Utworzyć go?"
    $res = [System.Windows.Forms.MessageBox]::Show($msg,"Brak katalogu",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            if (Test-Path $Path) { Log ("Utworzono katalog: {0}" -f $Path); return $true } else { [System.Windows.Forms.MessageBox]::Show("Nie udało się utworzyć katalogu: $Path","Błąd",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error); return $false }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Błąd tworzenia katalogu: $($_.Exception.Message)","Błąd",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
            return $false
        }
    } else {
        return $false
    }
}

function Get-UniqueFilePath {
    param([string]$Path)

    if (-not $Path) { return $Path }
    $dir  = Split-Path $Path -Parent
    $name = Split-Path $Path -Leaf
    $base = [IO.Path]::GetFileNameWithoutExtension($name)
    $ext  = [IO.Path]::GetExtension($name)

    $candidate = Join-Path $dir $name
    $i = 0
    while (Test-Path $candidate) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        if ($i -eq 0) {
            $newName = "{0}_{1}{2}" -f $base, $ts, $ext
        } else {
            $newName = "{0}_{1}-{2}{3}" -f $base, $ts, $i, $ext
        }
        $candidate = Join-Path $dir $newName
        $i++
    }
    return $candidate
}

function Choose-Folder {
    param([Alias('T')][System.Windows.Forms.TextBox]$Target)
    if ($null -eq $Target) { Log "Choose-Folder: brak kontrolki TextBox (parametr był null)."; return }
    $f = New-Object System.Windows.Forms.FolderBrowserDialog
    $f.ShowNewFolderButton = $true
    if ($Target.Text -and (Test-Path $Target.Text)) { $f.SelectedPath = $Target.Text }
    if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $Target.Text = $f.SelectedPath
        try { 
            if ($Target -eq $txtInput) { Load-Files } 
        } catch { Log "Choose-Folder: $($_.Exception.Message)" }
        Save-Settings
    }
}

function Format-SizeMB { param([long]$Bytes) return [math]::Round($Bytes / 1MB, 2) }

function Sanitize-FileName {
    param([string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $san = $Name
    foreach ($c in $invalid) { $san = $san -replace [regex]::Escape($c), '_' }
    $san = $san -replace '\s+$', ''
    if ($san.Length -gt 128) { $san = $san.Substring(0, 128) }
    return $san
}

function Compute-BitrateKbps {
    param([int]$MaxMB, [int]$DurationSec)
    $maxBytes = [int]($MaxMB * 1048576)
    $kbps = [math]::Floor((($maxBytes * 8) / 1024) / $DurationSec)
    $kbps = [math]::Floor($kbps * 0.95)
    if ($kbps -lt 200) { $kbps = 200 }
    return $kbps
}

function Detect-GPU {
    try {
        $args = @('-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=black:s=32x32:d=0.5','-c:v','hevc_nvenc','-t','0.5','-f','null','NUL')
        $p = Start-Process -FilePath $ffmpegExe -ArgumentList $args -NoNewWindow -WindowStyle Hidden -PassThru -ErrorAction Stop
        while (-not $p.HasExited) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.Application]::DoEvents() }
        return ($p.ExitCode -eq 0)
    } catch { return $false }
}

function Get-DurationSeconds {
    param([string]$FilePath)
    try {
        $out = & $ffprobeExe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 -i "`"$FilePath`"" 2>$null
        if ($out -and $out -match '^\s*([0-9]+(\.[0-9]+)?)') {
            return [math]::Max(1, [math]::Floor([double]$Matches[1]))
        }
    } catch {}
    return 1
}

function Detect-CodecAvailability {
    $encoders = @{
        "hevc_nvenc" = $false
        "libx265"    = $false
        "libx264"    = $false
        "libsvtav1"  = $false
        "libaom-av1" = $false
    }
    try {
        $list = & $ffmpegExe -hide_banner -encoders 2>$null
        if ($list) {
            foreach ($line in $list) {
                if ($line -match 'hevc_nvenc') { $encoders["hevc_nvenc"] = $true }
                if ($line -match 'libx265')    { $encoders["libx265"] = $true }
                if ($line -match 'libx264')    { $encoders["libx264"] = $true }
                if ($line -match 'libsvtav1')  { $encoders["libsvtav1"] = $true }
                if ($line -match 'libaom-av1') { $encoders["libaom-av1"] = $true }
            }
        }
    } catch {}
    return $encoders
}

function Run-FFmpeg-Capture {
    param([string[]]$ArgArray)
    if (-not $ArgArray -or $ArgArray.Count -eq 0) {
        Log "FFmpeg: brak argumentów."
        return @{ ExitCode = 1; Output = "" }
    }

    try {
        $output = & $ffmpegExe @ArgArray 2>&1
        $exit = $LASTEXITCODE

        if ($exit -ne 0 -and $output) {
            $lines = @($output -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
            $tail = $lines | Select-Object -Last 8
            foreach ($l in $tail) { Log "FFmpeg: $l" }
        }

        return @{ ExitCode = $exit; Output = $output }
    } catch {
        Log "FFmpeg: błąd wykonania."
        return @{ ExitCode = 1; Output = $_.Exception.Message }
    }
}

function Resolve-CodecSelection {
    param([string]$SelectedCodec,[hashtable]$Available)
    switch ($SelectedCodec) {
        "HEVC NVENC" { if ($Available["hevc_nvenc"]) { return "HEVC NVENC" } elseif ($Available["libx265"]) { return "HEVC libx265" } else { return "H.264 libx264" } }
        "HEVC libx265" { if ($Available["libx265"]) { return "HEVC libx265" } elseif ($Available["hevc_nvenc"]) { return "HEVC NVENC" } else { return "H.264 libx264" } }
        "AV1 SVT" { if ($Available["libsvtav1"]) { return "AV1 SVT" } elseif ($Available["libaom-av1"]) { return "AV1 libaom" } elseif ($Available["hevc_nvenc"]) { return "HEVC NVENC" } elseif ($Available["libx265"]) { return "HEVC libx265" } else { return "H.264 libx264" } }
        "AV1 libaom" { if ($Available["libaom-av1"]) { return "AV1 libaom" } elseif ($Available["libsvtav1"]) { return "AV1 SVT" } elseif ($Available["hevc_nvenc"]) { return "HEVC NVENC" } elseif ($Available["libx265"]) { return "HEVC libx265" } else { return "H.264 libx264" } }
        "H.264 libx264" { if ($Available["libx264"]) { return "H.264 libx264" } elseif ($Available["libx265"]) { return "HEVC libx265" } else { return "HEVC NVENC" } }
        default { return "HEVC NVENC" }
    }
}

function Set-CodecSelectionByValue { param([string]$val) for ($i=0;$i -lt $cbCodec.Items.Count;$i++) { if ($cbCodec.Items[$i] -eq $val) { $cbCodec.SelectedIndex = $i; return } } }

# Build combobox based on availability
function Build-CodecList {
    [void]$cbCodec.Items.Clear()
    if ($global:AvailableEncoders['hevc_nvenc'] -and $global:gpuOk) { [void]$cbCodec.Items.Add("HEVC NVENC") }
    if ($global:AvailableEncoders['libx265']) { [void]$cbCodec.Items.Add("HEVC libx265") }
    if ($global:AvailableEncoders['libsvtav1']) { [void]$cbCodec.Items.Add("AV1 SVT") }
    if ($global:AvailableEncoders['libaom-av1']) { [void]$cbCodec.Items.Add("AV1 libaom") }
    if ($global:AvailableEncoders['libx264']) { [void]$cbCodec.Items.Add("H.264 libx264") }
    if ($cbCodec.Items.Count -eq 0) { [void]$cbCodec.Items.Add("H.264 libx264 (brak detekcji)") }
}

function Get-AudioArgs {
    param([string]$CodecChoice,[int]$AudioBitrate)
    switch ($CodecChoice) {
        "aac" { return @('-c:a','aac','-b:a', ("${AudioBitrate}k")) }
        "opus" { return @('-c:a','libopus','-b:a', ("${AudioBitrate}k")) }
        "copy" { return @('-c:a','copy') }
        default { return @('-c:a','aac','-b:a', ("${AudioBitrate}k")) }
    }
}

# encoder detection to GUI log
function Report-EncoderStatus {
    param([hashtable]$enc, [bool]$gpuOk)

    $names = @{
        "hevc_nvenc" = "HEVC NVENC"
        "libx265"    = "libx265 (x265)"
        "libx264"    = "libx264 (x264)"
        "libsvtav1"  = "libsvtav1 (SVT-AV1)"
        "libaom-av1" = "libaom-av1 (AOM-AV1)"
    }

    Log "---- Sprawdzanie enkoderów ----"
    foreach ($k in $names.Keys) {
        $present = if ($enc[$k]) { "✓" } else { "✗" }
        if ($k -eq 'hevc_nvenc') {
            $gpuMark = if ($enc[$k] -and $gpuOk) { "✓" } elseif ($enc[$k]) { "✗" } else { "-" }
            Log ("{0,-22} : Encoder: {1}    GPU test: {2}" -f $names[$k], $present, $gpuMark)
        } else {
            Log ("{0,-22} : Encoder: {1}" -f $names[$k], $present)
        }
    }

    $availableList = @()
    if ($enc['hevc_nvenc'] -and $gpuOk) { $availableList += 'HEVC NVENC' }
    if ($enc['libx265']) { $availableList += 'HEVC libx265' }
    if ($enc['libsvtav1']) { $availableList += 'AV1 SVT' }
    if ($enc['libaom-av1']) { $availableList += 'AV1 libaom' }
    if ($enc['libx264']) { $availableList += 'H.264 libx264' }
    if ($availableList.Count -eq 0) { $availableList = @('brak wykrytych enkoderów') }
    Log ("Dostępne enkodery: {0}" -f ($availableList -join ', '))
    Log "-------------------------------"
}

# ---------- UI colors ----------
$clrFormBg = [System.Drawing.Color]::FromArgb(18,18,18)
$clrControlBg = [System.Drawing.Color]::FromArgb(28,28,30)
$clrPanelBg = [System.Drawing.Color]::FromArgb(22,22,24)
$clrText = [System.Drawing.Color]::FromArgb(238,238,238)
$clrMutedText = [System.Drawing.Color]::FromArgb(160,160,160)
$clrAccent = [System.Drawing.Color]::FromArgb(44,110,255)
$clrSuccess = [System.Drawing.Color]::FromArgb(86,180,90)
$clrWarn = [System.Drawing.Color]::FromArgb(220,140,40)
$clrRowAlt = [System.Drawing.Color]::FromArgb(26,26,28)

# ---------- Form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Kompresor PRO (PowerShell + ffmpeg)"
$form.Size = [System.Drawing.Size]::new(1180, 860)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.BackColor = $clrFormBg
$form.ForeColor = $clrText
$form.MinimumSize = [System.Drawing.Size]::new(900, 640)

[int]$pad = 12
[int]$labelW = 140
[int]$textW = 700
[int]$btnW = 96

# ---------- Top controls ----------
$lblIn = New-Object System.Windows.Forms.Label
$lblIn.Text = "Folder źródłowy:"
$lblIn.Location = [System.Drawing.Point]::new($pad,14)
$lblIn.Size = [System.Drawing.Size]::new($labelW,24)
$lblIn.ForeColor = $clrText
[void]$form.Controls.Add($lblIn)

$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Location = [System.Drawing.Point]::new($pad + $labelW,12)
$txtInput.Size = [System.Drawing.Size]::new($textW,26)
$txtInput.BackColor = $clrControlBg
$txtInput.ForeColor = $clrText
$txtInput.BorderStyle = "FixedSingle"
[void]$form.Controls.Add($txtInput)

$btnBrowseIn = New-Object System.Windows.Forms.Button
$btnBrowseIn.Text = "Wybierz..."
$btnBrowseIn.Size = [System.Drawing.Size]::new($btnW,26)
$btnBrowseIn.BackColor = [System.Drawing.Color]::FromArgb(50,50,54)
$btnBrowseIn.ForeColor = $clrText
$btnBrowseIn.FlatStyle = "Flat"
$btnBrowseIn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(204,204,204)
$btnBrowseIn.FlatAppearance.BorderSize = 1
[void]$form.Controls.Add($btnBrowseIn)

$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text = "Folder wyjściowy:"
$lblOut.Location = [System.Drawing.Point]::new($pad,50)
$lblOut.Size = [System.Drawing.Size]::new($labelW,24)
$lblOut.ForeColor = $clrText
[void]$form.Controls.Add($lblOut)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location = [System.Drawing.Point]::new($pad + $labelW,48)
$txtOutput.Size = [System.Drawing.Size]::new($textW,26)
$txtOutput.BackColor = $clrControlBg
$txtOutput.ForeColor = $clrText
$txtOutput.BorderStyle = "FixedSingle"
[void]$form.Controls.Add($txtOutput)

$btnBrowseOut = New-Object System.Windows.Forms.Button
$btnBrowseOut.Text = "Wybierz..."
$btnBrowseOut.Size = [System.Drawing.Size]::new($btnW,26)
$btnBrowseOut.BackColor = [System.Drawing.Color]::FromArgb(50,50,54)
$btnBrowseOut.ForeColor = $clrText
$btnBrowseOut.FlatStyle = "Flat"
$btnBrowseOut.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(204,204,204)
$btnBrowseOut.FlatAppearance.BorderSize = 1
[void]$form.Controls.Add($btnBrowseOut)

# Archive folder label + controls (new)
$lblArchive = New-Object System.Windows.Forms.Label
$lblArchive.Text = "Folder archiwum:"
$lblArchive.Location = [System.Drawing.Point]::new($pad,86)
$lblArchive.Size = [System.Drawing.Size]::new($labelW,24)
$lblArchive.ForeColor = $clrText
[void]$form.Controls.Add($lblArchive)

$txtArchive = New-Object System.Windows.Forms.TextBox
$txtArchive.Location = [System.Drawing.Point]::new($pad + $labelW,84)
$txtArchive.Size = [System.Drawing.Size]::new($textW,26)
$txtArchive.BackColor = $clrControlBg
$txtArchive.ForeColor = $clrText
$txtArchive.BorderStyle = "FixedSingle"
[void]$form.Controls.Add($txtArchive)

$btnBrowseArchive = New-Object System.Windows.Forms.Button
$btnBrowseArchive.Text = "Wybierz..."
$btnBrowseArchive.Size = [System.Drawing.Size]::new($btnW,26)
$btnBrowseArchive.BackColor = [System.Drawing.Color]::FromArgb(50,50,54)
$btnBrowseArchive.ForeColor = $clrText
$btnBrowseArchive.FlatStyle = "Flat"
$btnBrowseArchive.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(204,204,204)
$btnBrowseArchive.FlatAppearance.BorderSize = 1
[void]$form.Controls.Add($btnBrowseArchive)

# Load and size
$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Wczytaj pliki"
$btnLoad.Size = [System.Drawing.Size]::new($btnW,36)
$btnLoad.BackColor = $clrAccent
$btnLoad.ForeColor = [System.Drawing.Color]::White
$btnLoad.FlatStyle = "Flat"
$btnLoad.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(204,204,204)
$btnLoad.FlatAppearance.BorderSize = 1
[void]$form.Controls.Add($btnLoad)

$lblSize = New-Object System.Windows.Forms.Label
$lblSize.Text = "Max rozmiar (MB):"
$lblSize.Location = [System.Drawing.Point]::new($pad,124)
$lblSize.Size = [System.Drawing.Size]::new($labelW,24)
$lblSize.ForeColor = $clrText
[void]$form.Controls.Add($lblSize)

$nudSize = New-Object System.Windows.Forms.NumericUpDown
$nudSize.Location = [System.Drawing.Point]::new($pad + $labelW,122)
$nudSize.Size = [System.Drawing.Size]::new(120,26)
$nudSize.Minimum = 1
$nudSize.Maximum = 50000
$nudSize.Value = 10
$nudSize.BackColor = $clrControlBg
$nudSize.ForeColor = $clrText
[void]$form.Controls.Add($nudSize)

# Toggle PRO button
$btnTogglePro = New-Object System.Windows.Forms.Button
$btnTogglePro.Text = "PRO ▸"
$btnTogglePro.Size = [System.Drawing.Size]::new(64,26)
$btnTogglePro.BackColor = [System.Drawing.Color]::FromArgb(50,50,54)
$btnTogglePro.ForeColor = $clrText
$btnTogglePro.FlatStyle = "Flat"
$btnTogglePro.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(120,120,120)
$btnTogglePro.FlatAppearance.BorderSize = 1
[void]$form.Controls.Add($btnTogglePro)

# ---------- PRO GroupBox with TableLayoutPanel ----------
$gbPro = New-Object System.Windows.Forms.GroupBox
$gbPro.Text = "PRO"
$gbPro.Size = [System.Drawing.Size]::new(520, 110)
$gbPro.ForeColor = $clrText
$gbPro.BackColor = $clrPanelBg
[void]$form.Controls.Add($gbPro)
$gbPro.Visible = $false

$tbl = New-Object System.Windows.Forms.TableLayoutPanel
$tbl.Dock = "Fill"
$tbl.BackColor = $gbPro.BackColor
$tbl.ColumnCount = 6
$tbl.RowCount = 3
[void]$tbl.ColumnStyles.Clear()
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 70)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 140)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 50)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
[void]$tbl.RowStyles.Clear()
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
$tbl.Visible = $false

# controls
$lblCodec = New-Object System.Windows.Forms.Label; $lblCodec.Text = "Enkoder:"; $lblCodec.ForeColor = $clrText; $lblCodec.TextAlign = "MiddleLeft"
$cbCodec = New-Object System.Windows.Forms.ComboBox; $cbCodec.DropDownStyle = 'DropDownList'
$lblMode = New-Object System.Windows.Forms.Label; $lblMode.Text = "Tryb:"; $lblMode.ForeColor = $clrText; $lblMode.TextAlign = "MiddleLeft"
$cbMode = New-Object System.Windows.Forms.ComboBox; $cbMode.DropDownStyle = 'DropDownList'; [void]$cbMode.Items.AddRange(@("Target size (bitrate)","Quality (CRF)")); $cbMode.SelectedIndex = 0
$lblPreset = New-Object System.Windows.Forms.Label; $lblPreset.Text = "Preset:"; $lblPreset.ForeColor = $clrText; $lblPreset.TextAlign = "MiddleLeft"
$cbPreset = New-Object System.Windows.Forms.ComboBox; $cbPreset.DropDownStyle = 'DropDownList'; [void]$cbPreset.Items.AddRange(@("Fast","Balanced","Quality")); $cbPreset.SelectedIndex = 1
$lblAudio = New-Object System.Windows.Forms.Label; $lblAudio.Text = "Audio:"; $lblAudio.ForeColor = $clrText; $lblAudio.TextAlign = "MiddleLeft"
$cbAudio = New-Object System.Windows.Forms.ComboBox; $cbAudio.DropDownStyle = 'DropDownList'; [void]$cbAudio.Items.AddRange(@("aac","opus","copy")); $cbAudio.SelectedIndex = 0
$nudABitrate = New-Object System.Windows.Forms.NumericUpDown; $nudABitrate.Minimum = 16; $nudABitrate.Maximum = 512; $nudABitrate.Value = 64
$lblABit = New-Object System.Windows.Forms.Label; $lblABit.Text = "kbps"; $lblABit.ForeColor = $clrMutedText; $lblABit.TextAlign = "MiddleLeft"

$chkDelete = New-Object System.Windows.Forms.CheckBox
$chkDelete.Text = "Usuń oryginał po sukcesie"
$chkDelete.ForeColor = $clrMutedText
$chkDelete.AutoSize = $true
$chkDelete.Visible = $true
[void]$form.Controls.Add($chkDelete)

[void]$tbl.Controls.Add($lblCodec, 0, 0)
[void]$tbl.Controls.Add($cbCodec, 1, 0)
[void]$tbl.Controls.Add($lblMode, 2, 0)
[void]$tbl.Controls.Add($cbMode, 3, 0)
[void]$tbl.Controls.Add($lblPreset, 0, 1)
[void]$tbl.Controls.Add($cbPreset, 1, 1)
[void]$tbl.Controls.Add($lblAudio, 2, 1)
[void]$tbl.Controls.Add($cbAudio, 3, 1)
[void]$tbl.Controls.Add($nudABitrate, 4, 1)
[void]$tbl.Controls.Add($lblABit, 5, 1)
[void]$gbPro.Controls.Add($tbl)

# ---------- Encoder group ----------
$gbEnc = New-Object System.Windows.Forms.GroupBox; $gbEnc.Text = "Tryb enkodera"; $gbEnc.Size = [System.Drawing.Size]::new(380,44); $gbEnc.ForeColor = $clrText; $gbEnc.BackColor = $clrPanelBg
[void]$form.Controls.Add($gbEnc)
$radAuto = New-Object System.Windows.Forms.RadioButton; $radAuto.Text="Auto"; $radAuto.Location=[System.Drawing.Point]::new(12,14); $radAuto.ForeColor=$clrText; $radAuto.Checked=$true; [void]$gbEnc.Controls.Add($radAuto)
$radForceGPU = New-Object System.Windows.Forms.RadioButton; $radForceGPU.Text="GPU NVENC"; $radForceGPU.Location=[System.Drawing.Point]::new(100,14); $radForceGPU.ForeColor=$clrText; [void]$gbEnc.Controls.Add($radForceGPU)
$radForceCPU = New-Object System.Windows.Forms.RadioButton; $radForceCPU.Text="CPU"; $radForceCPU.Location=[System.Drawing.Point]::new(220,14); $radForceCPU.ForeColor=$clrText; [void]$gbEnc.Controls.Add($radForceCPU)

# ---------- DataGridView ----------
$list = New-Object System.Windows.Forms.DataGridView
$list.BackgroundColor = $clrPanelBg; $list.ForeColor = $clrText; $list.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$list.CellBorderStyle = [System.Windows.Forms.DataGridViewCellBorderStyle]::None
$list.RowHeadersVisible = $false; $list.AllowUserToAddRows = $false; $list.AllowUserToDeleteRows = $false
$list.ReadOnly = $false; $list.MultiSelect = $true; $list.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$list.AllowUserToResizeRows = $false; $list.AllowUserToResizeColumns = $false
$list.ColumnHeadersHeight = 32; $list.EnableHeadersVisualStyles = $false
$list.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(22,22,24)
$list.DefaultCellStyle.ForeColor = $clrText
$list.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(48,80,160)
$list.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$list.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI",9)
$list.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6,2,6,2)
$list.AlternatingRowsDefaultCellStyle.BackColor = $clrRowAlt
$list.RowTemplate.Height = 30
$list.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30,30,34)
$list.ColumnHeadersDefaultCellStyle.ForeColor = $clrText
$list.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$list.ColumnHeadersBorderStyle = [System.Windows.Forms.DataGridViewHeaderBorderStyle]::Single

# Columns
$colCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $colCheck.Name="Selected"; $colCheck.HeaderText=""; $colCheck.Width=36; $colCheck.TrueValue=$true; $colCheck.FalseValue=$false; $colCheck.ReadOnly=$false
$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colName.Name="FileName"; $colName.HeaderText="Plik"; $colName.AutoSizeMode=[System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill; $colName.ReadOnly=$true; $colName.HeaderCell.Style.Alignment=[System.Windows.Forms.DataGridViewContentAlignment]::MiddleLeft
$colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colSize.Name="SizeMB"; $colSize.HeaderText="Rozmiar (MB)"; $colSize.Width=120; $colSize.MinimumWidth=90; $colSize.ReadOnly=$true; $colSize.DefaultCellStyle.Alignment=[System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight; $colSize.SortMode=[System.Windows.Forms.DataGridViewColumnSortMode]::Automatic; $colSize.HeaderCell.Style.Padding = New-Object System.Windows.Forms.Padding(8,4,4,4)
$colDate = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colDate.Name="Modified"; $colDate.HeaderText="Data modyfikacji"; $colDate.Width=160; $colDate.ReadOnly=$true; $colDate.DefaultCellStyle.Alignment=[System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter; $colDate.SortMode=[System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
$colTime = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colTime.Name="Duration"; $colTime.HeaderText="Czas (s)"; $colTime.Width=90; $colTime.ReadOnly=$true; $colTime.DefaultCellStyle.Alignment=[System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter; $colTime.SortMode=[System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
$colStat = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colStat.Name="Status"; $colStat.HeaderText="Status"; $colStat.Width=180; $colStat.ReadOnly=$true; $colStat.SortMode=[System.Windows.Forms.DataGridViewColumnSortMode]::Automatic

[void]$list.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colCheck,$colName,$colSize,$colDate,$colTime,$colStat))
$list.ColumnHeadersDefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleCenter
$list.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4,4,4,4)
$list.ColumnHeadersDefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::False

$colName.HeaderCell.Style.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleLeft
$colName.HeaderCell.Style.Padding = New-Object System.Windows.Forms.Padding(6,6,6,6)
$colSize.HeaderCell.Style.Padding   = New-Object System.Windows.Forms.Padding(6,6,6,6)
$colDate.HeaderCell.Style.Padding   = New-Object System.Windows.Forms.Padding(6,6,6,6)
$colTime.HeaderCell.Style.Padding   = New-Object System.Windows.Forms.Padding(6,6,6,6)
$colStat.HeaderCell.Style.Padding   = New-Object System.Windows.Forms.Padding(6,6,6,6)

[void]$form.Controls.Add($list)

# Tooltip
$tool = New-Object System.Windows.Forms.ToolTip; $tool.AutomaticDelay = 200
$list.add_CellMouseEnter({
    param($s,$e)
    if ($e.RowIndex -ge 0 -and $e.ColumnIndex -ge 0) {
        $r = $list.Rows[$e.RowIndex]; $c = $list.Columns[$e.ColumnIndex]
        if ($c.Name -eq "FileName") { $tool.SetToolTip($list, $r.Tag) } else { $tool.SetToolTip($list, $null) }
    }
})

# Buttons
$btnCompress = New-Object System.Windows.Forms.Button; $btnCompress.Text="Kompresuj zaznaczone"; $btnCompress.Size=[System.Drawing.Size]::new(220,36); $btnCompress.BackColor=$clrAccent; $btnCompress.ForeColor=[System.Drawing.Color]::White; $btnCompress.FlatStyle="Flat"; $btnCompress.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(204,204,204); $btnCompress.FlatAppearance.BorderSize=1; [void]$form.Controls.Add($btnCompress)
$btnArchive = New-Object System.Windows.Forms.Button; $btnArchive.Text="Przenieś do archiwum"; $btnArchive.Size=[System.Drawing.Size]::new(190,36); $btnArchive.BackColor=[System.Drawing.Color]::FromArgb(70,70,76); $btnArchive.ForeColor=$clrText; $btnArchive.FlatStyle="Flat"; $btnArchive.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(204,204,204); $btnArchive.FlatAppearance.BorderSize=1; [void]$form.Controls.Add($btnArchive)
$btnDelete = New-Object System.Windows.Forms.Button; $btnDelete.Text="Usuń zaznaczone"; $btnDelete.Size=[System.Drawing.Size]::new(170,36); $btnDelete.BackColor=[System.Drawing.Color]::FromArgb(160,50,50); $btnDelete.ForeColor=[System.Drawing.Color]::White; $btnDelete.FlatStyle="Flat"; $btnDelete.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(204,204,204); $btnDelete.FlatAppearance.BorderSize=1; [void]$form.Controls.Add($btnDelete)
$btnOpenOut = New-Object System.Windows.Forms.Button; $btnOpenOut.Text="Otwórz folder wynikowy"; $btnOpenOut.Size=[System.Drawing.Size]::new(170,36); $btnOpenOut.BackColor=[System.Drawing.Color]::FromArgb(80,120,80); $btnOpenOut.ForeColor=[System.Drawing.Color]::White; $btnOpenOut.FlatStyle="Flat"; $btnOpenOut.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(204,204,204); $btnOpenOut.FlatAppearance.BorderSize=1; [void]$form.Controls.Add($btnOpenOut)

# Log
$rtLog = New-Object System.Windows.Forms.RichTextBox; $rtLog.BackColor = [System.Drawing.Color]::FromArgb(0,0,0); $rtLog.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220); $rtLog.ReadOnly = $true; $rtLog.BorderStyle = "FixedSingle"; $rtLog.ScrollBars = "Vertical"; [void]$form.Controls.Add($rtLog)

# Footer left/right - link
$lblFooterLeft = New-Object System.Windows.Forms.LinkLabel
$lblFooterLeft.Text = "Kompresor PRO  |  POWER FORCE edition  |  made by padre_spazma 2026"
$lblFooterLeft.AutoSize = $true
$lblFooterLeft.LinkColor = $clrMutedText
$lblFooterLeft.ActiveLinkColor = $clrAccent
$lblFooterLeft.VisitedLinkColor = $clrMutedText
$lblFooterLeft.Font = New-Object System.Drawing.Font($form.Font.FontFamily,9,[System.Drawing.FontStyle]::Italic)
$lblFooterLeft.ForeColor = $clrMutedText
[void]$lblFooterLeft.Links.Clear()
$start = $lblFooterLeft.Text.IndexOf("made by")
if ($start -ge 0) { $len = $lblFooterLeft.Text.Length - $start; [void]$lblFooterLeft.Links.Add($start,$len,"https://spazma.github.io/") }
$lblFooterLeft.add_LinkClicked({ param($s,$e) try { $url=$e.Link.LinkData; if ($url) { Start-Process $url } else { Start-Process "https://spazma.github.io/" }; $e.Link.Visited=$true } catch { Log "Nie udało się otworzyć linku: $($_.Exception.Message)" } })
[void]$form.Controls.Add($lblFooterLeft)

$lblFooterRight = New-Object System.Windows.Forms.Label; $lblFooterRight.Text = "FFMPEG: ? | FFPROBE: ? | ENCODER: sprawdzanie..."; $lblFooterRight.AutoSize = $true; $lblFooterRight.Font = New-Object System.Drawing.Font($form.Font.FontFamily,9,[System.Drawing.FontStyle]::Regular); $lblFooterRight.ForeColor = $clrMutedText; [void]$form.Controls.Add($lblFooterRight)

# ---------- Functions that use controls ----------
function GetSelectedRows {
    $sel = @()
    foreach ($r in $list.Rows) { if ($r.Cells["Selected"].Value -eq $true) { $sel += $r } }
    return $sel
}

function Load-Files {
    $list.Rows.Clear()
    $in = $txtInput.Text
    if ([string]::IsNullOrWhiteSpace($in) -or -not (Test-Path $in)) { Log "Folder źródłowy nie istnieje lub nie został podany: '$in'."; return }
    $patterns = @("*.mp4","*.mov","*.mkv","*.avi")
    $files = foreach ($p in $patterns) { Get-ChildItem -File -Path $in -Filter $p -ErrorAction SilentlyContinue }
    if (-not $files) { Log "Wczytano 0 plików."; return }
    $files = $files | Sort-Object -Property LastWriteTime -Descending
    foreach ($f in $files) {
        $idx = $list.Rows.Add()
        $row = $list.Rows[$idx]
        $row.Cells["Selected"].Value = $false
        $row.Cells["FileName"].Value = $f.Name
        $row.Cells["SizeMB"].Value = [string](Format-SizeMB $f.Length)
        $row.Cells["Modified"].Value = $f.LastWriteTime.ToString('dd.MM.yyyy HH:mm')
        $row.Cells["Duration"].Value = [string](Get-DurationSeconds -FilePath $f.FullName)
        $row.Cells["Status"].Value = "Gotowy"
        $row.Tag = $f.FullName
    }
    Log ("Wczytano {0} plików." -f $list.Rows.Count)
}

# ---------- Layout ----------
function LayoutControls {
    [int]$cx = [int]$form.ClientSize.Width
    [int]$cy = [int]$form.ClientSize.Height

    [int]$rightMargin = 12
    [int]$btnRightX = [int]($cx - $btnW - $rightMargin)

    $btnBrowseIn.Location = [System.Drawing.Point]::new($btnRightX, 12)
    $btnBrowseOut.Location = [System.Drawing.Point]::new($btnRightX, 48)
    $btnBrowseArchive.Location = [System.Drawing.Point]::new($btnRightX, 84)
    $btnLoad.Location = [System.Drawing.Point]::new($btnRightX, 120)

    $btnTogglePro.Location = [System.Drawing.Point]::new(($pad + $labelW + $nudSize.Width + 16), $nudSize.Location.Y)

    $txtInput.Width = [int]($btnBrowseIn.Location.X - ($pad + $labelW) - 8)
    if ($txtInput.Width -lt 120) { $txtInput.Width = 120 }
    $txtOutput.Width = $txtInput.Width
    $txtArchive.Width = $txtInput.Width

    [int]$sizeRight = [int]($pad + $labelW + $txtInput.Width)
    [int]$spaceRight = [int]($btnRightX - $sizeRight - 16)

    [int]$prefProW = 500
    [int]$minProW = 280
    [int]$gap = 12
    [int]$availableFull = [int]($cx - ($pad * 2))
    [int]$topY = [int]($nudSize.Location.Y + $nudSize.Height + 8)

    $chkDelete.Visible = $true
    $chkDelete.AutoSize = $true

    if ($global:proCollapsed) {
        $gbPro.Visible = $false
        $tbl.Visible = $false
        foreach ($ctrl in $tbl.Controls) { $ctrl.Visible = $false }
        $gbEnc.Visible = $true

        $encX = [int]($sizeRight + 12)
        if ($encX + $gbEnc.Width -gt ($btnRightX - 12)) {
            $gbEnc.Location = [System.Drawing.Point]::new([int]($pad + $labelW), $topY)
        } else {
            $gbEnc.Location = [System.Drawing.Point]::new($encX, $topY)
        }

        $chkDelete.Location = [System.Drawing.Point]::new(
            [int]($btnTogglePro.Location.X + $btnTogglePro.Width + 18),
            [int]($nudSize.Location.Y + 3)
        )
    }
    else {
        $gbPro.Visible = $true
        $tbl.Visible = $true
        foreach ($ctrl in $tbl.Controls) { $ctrl.Visible = $true }
        $gbEnc.Visible = $true

        if ($spaceRight -ge ($prefProW + $gap + $gbEnc.Width)) {
            $gbPro.Width = $prefProW
            $gbPro.Location = [System.Drawing.Point]::new([int]($sizeRight + 12), $topY)
            $gbEnc.Location = [System.Drawing.Point]::new([int]($gbPro.Location.X + $gbPro.Width + $gap), $topY)
        }
        elseif ($spaceRight -ge ($minProW + 12)) {
            $gbPro.Width = [int]($spaceRight - $gbEnc.Width - $gap)
            if ($gbPro.Width -gt $prefProW) { $gbPro.Width = $prefProW }
            if ($gbPro.Width -lt $minProW) { $gbPro.Width = $minProW }
            $gbPro.Location = [System.Drawing.Point]::new([int]($sizeRight + 12), $topY)

            $encX = [int]($gbPro.Location.X + $gbPro.Width + $gap)
            if ($encX + $gbEnc.Width -gt ($btnRightX - 12)) {
                $gbEnc.Location = [System.Drawing.Point]::new([int]($pad + $labelW), [int]($gbPro.Location.Y + $gbPro.Height + 8))
            } else {
                $gbEnc.Location = [System.Drawing.Point]::new($encX, $topY)
            }
        }
        else {
            $gbPro.Width = [int]($availableFull - 20)
            if ($gbPro.Width -gt $prefProW) { $gbPro.Width = $prefProW }
            if ($gbPro.Width -lt $minProW) { $gbPro.Width = $minProW }
            $gbPro.Location = [System.Drawing.Point]::new([int]($pad + $labelW), $topY)

            $encX = [int]($gbPro.Location.X + $gbPro.Width + $gap)
            if ($encX + $gbEnc.Width -le ($btnRightX - 12)) {
                $gbEnc.Location = [System.Drawing.Point]::new($encX, $gbPro.Location.Y)
            } else {
                $gbEnc.Location = [System.Drawing.Point]::new([int]($pad + $labelW), [int]($gbPro.Location.Y + $gbPro.Height + 8))
            }
        }

        $chkDelete.Location = [System.Drawing.Point]::new(
            [int]($btnTogglePro.Location.X + $btnTogglePro.Width + 18),
            [int]($nudSize.Location.Y + 3)
        )
    }

    if ($gbPro.Visible) { $gbProBottom = $gbPro.Location.Y + $gbPro.Height } else { $gbProBottom = 0 }
    [int]$gbEncBottom = $gbEnc.Location.Y + $gbEnc.Height
    if ($chkDelete.Visible) { $chkBottom = $chkDelete.Location.Y + $chkDelete.Height } else { $chkBottom = 0 }
    [int]$bottomOfPanels = [int][Math]::Max([Math]::Max($gbProBottom, $gbEncBottom), $chkBottom)

    [int]$listTop = [int]($bottomOfPanels + 12)
    if ($listTop -lt 180) { $listTop = 180 }

    $list.Location = [System.Drawing.Point]::new($pad, $listTop)
    [int]$listHeight = [int]($cy - $listTop - 200)
    if ($listHeight -lt 200) { $listHeight = 200 }
    $list.Size = [System.Drawing.Size]::new([int]($cx - ($pad * 2)), $listHeight)

    [int]$totalW = [int]($btnCompress.Width + $btnArchive.Width + $btnDelete.Width + $btnOpenOut.Width + ($gap * 3))
    [int]$startX = [int](($cx - $totalW) / 2)
    [int]$yButtons = [int]($list.Location.Y + $list.Size.Height + 10)
    $btnCompress.Location = [System.Drawing.Point]::new($startX, $yButtons)
    $btnArchive.Location = [System.Drawing.Point]::new($btnCompress.Location.X + $btnCompress.Width + $gap, $yButtons)
    $btnDelete.Location = [System.Drawing.Point]::new($btnArchive.Location.X + $btnArchive.Width + $gap, $yButtons)
    $btnOpenOut.Location = [System.Drawing.Point]::new($btnDelete.Location.X + $btnDelete.Width + $gap, $yButtons)

    [int]$logY = [int]($yButtons + $btnCompress.Height + 10)
    [int]$logH = [int]($cy - $logY - 36)
    if ($logH -lt 80) { $logH = 80 }
    $rtLog.Location = [System.Drawing.Point]::new($pad, $logY)
    $rtLog.Size = [System.Drawing.Size]::new([int]($cx - ($pad * 2)), $logH)

    $lblFooterLeft.Location = [System.Drawing.Point]::new($pad, $logY + $logH + 6)
    $footerRightX = [int]($cx - $pad)
    $footerWidth = [int]$lblFooterRight.PreferredWidth
    $rX = [int]($footerRightX - $footerWidth)
    if ($rX -le ($lblFooterLeft.Location.X + $lblFooterLeft.PreferredWidth + 20)) {
        $rX = [int]($cx - $pad - $footerWidth)
    }
    $lblFooterRight.Location = [System.Drawing.Point]::new($rX, $logY + $logH + 6)
}

[void]$form.add_Resize({ LayoutControls })

# ---------- Events ----------
$btnBrowseIn.Add_Click({ Choose-Folder -Target $txtInput })
$btnBrowseOut.Add_Click({ Choose-Folder -Target $txtOutput })
$btnBrowseArchive.Add_Click({ Choose-Folder -Target $txtArchive })
$btnLoad.Add_Click({ Load-Files })

# save settings when user edits textboxes (on leave)
$txtInput.add_Leave({ Save-Settings })
$txtOutput.add_Leave({ Save-Settings })
$txtArchive.add_Leave({ Save-Settings })

$btnOpenOut.Add_Click({
    if ($txtOutput.Text -and (Ensure-FolderExists -Path $txtOutput.Text -PromptIfMissing $true)) {
        Start-Process explorer.exe -ArgumentList "`"$($txtOutput.Text)`""
    } else {
        Log "Folder wynikowy nie istnieje."
    }
})

$btnArchive.Add_Click({
    $rows = GetSelectedRows
    if ($rows.Count -eq 0) { Log "Brak zaznaczonych plików do archiwizacji."; return }

    $archiveBase = if ($txtArchive.Text) { $txtArchive.Text } else { Join-Path $txtOutput.Text "archiwum" }
    if (-not (Ensure-FolderExists -Path $archiveBase -PromptIfMissing $true)) { Log "Anulowano operację archiwizacji (brak katalogu archiwum)."; return }

    $dateFolder = Join-Path $archiveBase (Get-Date -Format 'dd-MM-yyyy')
    $origDir = Join-Path $dateFolder "oryginaly"
    $compDir = Join-Path $dateFolder "skompresowane"

    try {
        if (-not (Test-Path $dateFolder))   { New-Item -ItemType Directory -Path $dateFolder -Force | Out-Null }
        if (-not (Test-Path $origDir))      { New-Item -ItemType Directory -Path $origDir -Force | Out-Null }
        if (-not (Test-Path $compDir))      { New-Item -ItemType Directory -Path $compDir -Force | Out-Null }
    } catch {
        Log ("Nie można utworzyć folderu archiwum: {0}" -f $_.Exception.Message)
        return
    }

    $countOrig = 0
    $countComp = 0

    foreach ($r in $rows) {
        $src = $r.Tag
        $fileName = [IO.Path]::GetFileName($src)
        $destCandidate = Join-Path $origDir $fileName
        $destUnique = Get-UniqueFilePath -Path $destCandidate
        try {
            Move-Item -LiteralPath $src -Destination $destUnique -Force
            $r.Cells["Status"].Value = "Przeniesiono do archiwum (oryg.)"
            Log ("Przeniesiono oryginał: {0} -> {1}" -f $fileName, $destUnique)
            $countOrig++
        } catch {
            Log ("Błąd przenoszenia oryginału {0}: {1}" -f $fileName, $_.Exception.Message)
            continue
        }

        # przenieś skompresowane odpowiadające pliki (jeśli istnieją)
        $base = Sanitize-FileName([IO.Path]::GetFileNameWithoutExtension($src))
        if (Test-Path $txtOutput.Text) {
            $matches = Get-ChildItem -Path $txtOutput.Text -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like "$base*_kompress_*.*"
            }
            if ($matches -and $matches.Count -gt 0) {
                foreach ($m in $matches) {
                    $destCcand = Join-Path $compDir $m.Name
                    $destCUnique = Get-UniqueFilePath -Path $destCcand
                    try {
                        Move-Item -LiteralPath $m.FullName -Destination $destCUnique -Force
                        Log ("Przeniesiono skompresowany: {0} -> {1}" -f $m.Name, $destCUnique)
                        $countComp++
                    } catch {
                        Log ("Błąd przenoszenia skompresowanego {0}: {1}" -f $m.Name, $_.Exception.Message)
                    }
                }
            }
        }
    }

    Load-Files

    # podsumowanie
    $total = $countOrig + $countComp
    $summary = "Zarchiwizowano: $total plików.`nOryginały: $countOrig`nSkompresowane: $countComp"
    Log $summary
    [System.Windows.Forms.MessageBox]::Show($summary, "Archiwizacja zakończona", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
})

$btnDelete.Add_Click({
    $rows = GetSelectedRows
    if ($rows.Count -eq 0) { Log "Brak zaznaczonych plików do usunięcia."; return }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Na pewno usunąć zaznaczone pliki?", "Potwierdzenie", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    foreach ($r in $rows) {
        $src = $r.Tag
        try { Remove-Item -LiteralPath $src -Force; $r.Cells["Status"].Value = "Usunięto"; Log ("Usunięto {0}" -f [System.IO.Path]::GetFileName($src)) } catch { Log ("Błąd usuwania {0}: {1}" -f [System.IO.Path]::GetFileName($src), $_.Exception.Message) }
    }
    Load-Files
})

# keep track of prev codec
$cbCodec.add_SelectedIndexChanged({ try { if ($cbCodec.SelectedItem) { $global:PrevCodec = $cbCodec.SelectedItem.ToString() } } catch {} })

# Toggle PRO
$btnTogglePro.Add_Click({
    if ($global:proCollapsed) {
        $global:proCollapsed = $false
        $btnTogglePro.Text = "PRO ▾"
        $gbPro.Visible = $true
        $tbl.Visible = $true
        foreach ($ctrl in $tbl.Controls) { $ctrl.Visible = $true }
    } else {
        $global:proCollapsed = $true
        $btnTogglePro.Text = "PRO ▸"
        $gbPro.Visible = $false
        $tbl.Visible = $false
        foreach ($ctrl in $tbl.Controls) { $ctrl.Visible = $false }
    }
    $chkDelete.Visible = $true
    LayoutControls
    $form.Refresh()
})

# ---------- Compress logic ----------
$presetMap = @{
    "Fast" = @{ nvenc="p1"; x264="fast"; x265="fast"; svt=8; aom=8; crfX264=26; crfX265=32; crfSVT=40; crfAOM=35 }
    "Balanced" = @{ nvenc="p4"; x264="medium"; x265="medium"; svt=6; aom=6; crfX264=23; crfX265=28; crfSVT=34; crfAOM=30 }
    "Quality" = @{ nvenc="p7"; x264="slow"; x265="slow"; svt=4; aom=2; crfX264=20; crfX265=24; crfSVT=30; crfAOM=26 }
}

function Compress-File {
    param(
        [string]$FilePath,
        [string]$OutDir,
        [int]$MaxMB,
        [bool]$UseGPU,
        [System.Windows.Forms.DataGridViewRow]$Row = $null
    )

    function UpdateLogProgress {
        param([string]$msg)
        Log $msg
        try { $form.Refresh() } catch {}
        [System.Windows.Forms.Application]::DoEvents()
    }

    $srcName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    $san = Sanitize-FileName $srcName
    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $codecChoice = if ($cbCodec.SelectedItem) { $cbCodec.SelectedItem.ToString() } else { Resolve-CodecSelection -SelectedCodec "H.264 libx264" -Available $global:AvailableEncoders }
    $outExt = ".mp4"; if ($codecChoice -like "AV1*") { $outExt = ".mkv" }
    $outName = "{0}_kompress_{1}{2}" -f $san, $timestamp, $outExt
    $outPath = Join-Path $OutDir $outName
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $duration = Get-DurationSeconds -FilePath $FilePath
    $bitrate = [int](Compute-BitrateKbps -MaxMB $MaxMB -DurationSec $duration)
    $resolvedCodec = Resolve-CodecSelection -SelectedCodec $codecChoice -Available $global:AvailableEncoders
    $modeChoice = $cbMode.SelectedItem.ToString()
    $presetChoice = $cbPreset.SelectedItem.ToString()
    $audioChoice = $cbAudio.SelectedItem.ToString()
    $audioBitrate = [int]$nudABitrate.Value
    $deleteOrig = $chkDelete.Checked
    $presetCfg = $presetMap[$presetChoice]
    $audioArgs = Get-AudioArgs -CodecChoice $audioChoice -AudioBitrate $audioBitrate

    Log ("Kompresja: {0} | max {1} MB | codec: {2} | tryb: {3}" -f [IO.Path]::GetFileName($FilePath), $MaxMB, $resolvedCodec, $modeChoice)

    if (Test-Path "ffmpeg2pass-0.log") { Remove-Item "ffmpeg2pass-0.log" -ErrorAction SilentlyContinue }
    if (Test-Path "ffmpeg2pass-0.log.mbtree") { Remove-Item "ffmpeg2pass-0.log.mbtree" -ErrorAction SilentlyContinue }

    try {
        if ($modeChoice -eq "Target size (bitrate)") {
            $totalStages = 2

            switch ($resolvedCodec) {
                "HEVC NVENC" {
                    UpdateLogProgress ("Kompresja... pass 1/$totalStages (analiza)")
                    $pass1 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','hevc_nvenc','-rc','vbr','-b:v',("${bitrate}k"),'-maxrate',("${bitrate}k"),'-pass','1','-an','-f','null','NUL')
                    $r1 = Run-FFmpeg-Capture -ArgArray $pass1; if ($r1.ExitCode -ne 0) { Log "Błąd: pass 1 NVENC"; return $null }

                    UpdateLogProgress ("Kompresja... pass 2/$totalStages (kodowanie)")
                    $pass2 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','hevc_nvenc','-rc','vbr','-b:v',("${bitrate}k"),'-maxrate',("${bitrate}k"),'-pass','2') + $audioArgs + @($outPath)
                    $r2 = Run-FFmpeg-Capture -ArgArray $pass2; if ($r2.ExitCode -ne 0) { Log "Błąd: pass 2 NVENC"; return $null }
                }
                "HEVC libx265" {
                    UpdateLogProgress ("Kompresja... pass 1/$totalStages (analiza)")
                    $pass1 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libx265','-preset',$presetCfg.x265,'-b:v',("${bitrate}k"),'-pass','1','-an','-f','null','NUL')
                    $r1 = Run-FFmpeg-Capture -ArgArray $pass1; if ($r1.ExitCode -ne 0) { Log "Błąd: pass 1 libx265"; return $null }

                    UpdateLogProgress ("Kompresja... pass 2/$totalStages (kodowanie)")
                    $pass2 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libx265','-preset',$presetCfg.x265,'-b:v',("${bitrate}k"),'-pass','2') + $audioArgs + @($outPath)
                    $r2 = Run-FFmpeg-Capture -ArgArray $pass2; if ($r2.ExitCode -ne 0) { Log "Błąd: pass 2 libx265"; return $null }
                }
                "AV1 SVT" {
                    UpdateLogProgress ("Kompresja... pass 1/$totalStages (analiza)")
                    $pass1 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libsvtav1','-preset',[string]$presetCfg.svt,'-b:v',("${bitrate}k"),'-pass','1','-an','-f','null','NUL')
                    $r1 = Run-FFmpeg-Capture -ArgArray $pass1; if ($r1.ExitCode -ne 0) { Log "Błąd: pass 1 SVT-AV1"; return $null }

                    UpdateLogProgress ("Kompresja... pass 2/$totalStages (kodowanie)")
                    $pass2 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libsvtav1','-preset',[string]$presetCfg.svt,'-b:v',("${bitrate}k"),'-pass','2') + $audioArgs + @($outPath)
                    $r2 = Run-FFmpeg-Capture -ArgArray $pass2; if ($r2.ExitCode -ne 0) { Log "Błąd: pass 2 SVT-AV1"; return $null }
                }
                "AV1 libaom" {
                    UpdateLogProgress ("Kompresja... pass 1/$totalStages (analiza)")
                    $pass1 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libaom-av1','-cpu-used',[string]$presetCfg.aom,'-b:v',("${bitrate}k"),'-pass','1','-an','-f','null','NUL')
                    $r1 = Run-FFmpeg-Capture -ArgArray $pass1; if ($r1.ExitCode -ne 0) { Log "Błąd: pass 1 libaom AV1"; return $null }

                    UpdateLogProgress ("Kompresja... pass 2/$totalStages (kodowanie)")
                    $pass2 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libaom-av1','-cpu-used',[string]$presetCfg.aom,'-b:v',("${bitrate}k"),'-pass','2') + $audioArgs + @($outPath)
                    $r2 = Run-FFmpeg-Capture -ArgArray $pass2; if ($r2.ExitCode -ne 0) { Log "Błąd: pass 2 libaom AV1"; return $null }
                }
                "H.264 libx264" {
                    UpdateLogProgress ("Kompresja... pass 1/$totalStages (analiza)")
                    $pass1 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libx264','-preset',$presetCfg.x264,'-b:v',("${bitrate}k"),'-maxrate',("${bitrate}k"),'-pass','1','-an','-f','null','NUL')
                    $r1 = Run-FFmpeg-Capture -ArgArray $pass1; if ($r1.ExitCode -ne 0) { Log "Błąd: pass 1 libx264"; return $null }

                    UpdateLogProgress ("Kompresja... pass 2/$totalStages (kodowanie)")
                    $pass2 = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libx264','-preset',$presetCfg.x264,'-b:v',("${bitrate}k"),'-maxrate',("${bitrate}k"),'-pass','2') + $audioArgs + @($outPath)
                    $r2 = Run-FFmpeg-Capture -ArgArray $pass2; if ($r2.ExitCode -ne 0) { Log "Błąd: pass 2 libx264"; return $null }
                }
            }
        } else {
            $totalStages = 1
            UpdateLogProgress ("Kompresja... etap 1/$totalStages (kodowanie)")
            switch ($resolvedCodec) {
                "HEVC NVENC" { $args = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','hevc_nvenc','-preset',$presetCfg.nvenc,'-cq','23') + $audioArgs + @($outPath); $r = Run-FFmpeg-Capture -ArgArray $args; if ($r.ExitCode -ne 0) { Log "Błąd: CRF NVENC"; return $null } }
                "HEVC libx265" { $args = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libx265','-preset',$presetCfg.x265,'-crf',[string]$presetCfg.crfX265) + $audioArgs + @($outPath); $r = Run-FFmpeg-Capture -ArgArray $args; if ($r.ExitCode -ne 0) { Log "Błąd: CRF libx265"; return $null } }
                "AV1 SVT" { $args = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libsvtav1','-preset',[string]$presetCfg.svt,'-crf',[string]$presetCfg.crfSVT) + $audioArgs + @($outPath); $r = Run-FFmpeg-Capture -ArgArray $args; if ($r.ExitCode -ne 0) { Log "Błąd: CRF SVT AV1"; return $null } }
                "AV1 libaom" { $args = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libaom-av1','-cpu-used',[string]$presetCfg.aom,'-crf',[string]$presetCfg.crfAOM) + $audioArgs + @($outPath); $r = Run-FFmpeg-Capture -ArgArray $args; if ($r.ExitCode -ne 0) { Log "Błąd: CRF libaom AV1"; return $null } }
                "H.264 libx264" { $args = @('-hide_banner','-loglevel','error','-stats','-i',$FilePath,'-c:v','libx264','-preset',$presetCfg.x264,'-crf',[string]$presetCfg.crfX264) + $audioArgs + @($outPath); $r = Run-FFmpeg-Capture -ArgArray $args; if ($r.ExitCode -ne 0) { Log "Błąd: CRF libx264"; return $null } }
            }
        }
    } catch {
        Log ("Błąd kompresji: {0}" -f $_.Exception.Message)
        return $null
    }

    if (Test-Path $outPath) {
        $sizeBytes = (Get-Item $outPath).Length
        $sizeMB = Format-SizeMB -Bytes $sizeBytes
        UpdateLogProgress ("OK: {0} ({1} MB)" -f [IO.Path]::GetFileName($outPath), $sizeMB)
        if ($deleteOrig) { try { Remove-Item -LiteralPath $FilePath -Force; Log ("Usunięto oryginał: {0}" -f [System.IO.Path]::GetFileName($FilePath)) } catch { Log ("Nie udało się usunąć oryginału: {0}" -f [System.IO.Path]::GetFileName($FilePath)) } }
        return @{ Path = $outPath; SizeMB = $sizeMB }
    } else {
        UpdateLogProgress "Błąd: plik wyjściowy nie istnieje po kompresji."
        return $null
    }
}

$btnCompress.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtOutput.Text)) { Log "Nie podano katalogu wyjściowego."; return }
    if (-not (Ensure-FolderExists -Path $txtOutput.Text -PromptIfMissing $true)) { Log "Anulowano kompresję (brak katalogu wyjściowego)."; return }
    $rows = GetSelectedRows
    if ($rows.Count -eq 0) { Log "Brak zaznaczonych plików do kompresji."; return }
    $maxMB = [int]$nudSize.Value
    Log "Start kompresji..."
    foreach ($r in $rows) {
        $r.Cells["Status"].Value = "Kompresja..."
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        $result = Compress-File -FilePath $r.Tag -OutDir $txtOutput.Text -MaxMB $maxMB -UseGPU $global:gpuOk
        if ($result -eq $null) { $r.Cells["Status"].Value = "Błąd kompresji"; Log ("Błąd kompresji: {0}" -f [IO.Path]::GetFileName($r.Tag)) } else { if ($result.SizeMB -le $maxMB) { $r.Cells["Status"].Value = "OK - $($result.SizeMB) MB" } else { $r.Cells["Status"].Value = "OK ale za duży $($result.SizeMB) MB" } }
    }
    Log "Kompresja zakończona."
    if (Test-Path "ffmpeg2pass-0.log") { Remove-Item "ffmpeg2pass-0.log" -ErrorAction SilentlyContinue }
    if (Test-Path "ffmpeg2pass-0.log.mbtree") { Remove-Item "ffmpeg2pass-0.log.mbtree" -ErrorAction SilentlyContinue }
})

# ---------- Init on show ----------
$form.Add_Shown({
    # base dir and settings file
    $base = Get-ScriptBaseDirectory
    $settingsFile = Join-Path $base 'kompresor_settings.json'

    # helper: create default folders next to script, fallback to user Videos/Desktop
    function Get-DefaultPaths {
        param($baseDir)

        $tryInput  = Join-Path $baseDir "do_kompresji"
        $tryOutput = Join-Path $baseDir "kompress_10mb"
        $tryArchive = Join-Path $tryOutput "archiwum"

        try {
            if (-not (Test-Path $tryInput))  { New-Item -ItemType Directory -Path $tryInput  -Force | Out-Null }
            if (-not (Test-Path $tryOutput)) { New-Item -ItemType Directory -Path $tryOutput -Force | Out-Null }
            if (-not (Test-Path $tryArchive)) { New-Item -ItemType Directory -Path $tryArchive -Force | Out-Null }
            return @{ input = $tryInput; output = $tryOutput; archive = $tryArchive }
        } catch {
            $userVideos = Join-Path $env:USERPROFILE "Videos"
            if (-not (Test-Path $userVideos)) { $userVideos = Join-Path $env:USERPROFILE "Desktop" }
            $fbBase = Join-Path $userVideos "kompresor"
            $fbInput = Join-Path $fbBase "do_kompresji"
            $fbOutput = Join-Path $fbBase "kompress_10mb"
            $fbArchive = Join-Path $fbOutput "archiwum"
            if (-not (Test-Path $fbInput))  { New-Item -ItemType Directory -Path $fbInput  -Force | Out-Null }
            if (-not (Test-Path $fbOutput)) { New-Item -ItemType Directory -Path $fbOutput -Force | Out-Null }
            if (-not (Test-Path $fbArchive)) { New-Item -ItemType Directory -Path $fbArchive -Force | Out-Null }
            return @{ input = $fbInput; output = $fbOutput; archive = $fbArchive }
        }
    }

    # load or create settings (remember last/default paths)
    if (Test-Path $settingsFile) {
        try {
            $cfg = Get-Content $settingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
            $defInput = $cfg.DefaultInput
            $defOutput = $cfg.DefaultOutput
            $defArchive = $cfg.DefaultArchive
            try {
                if ($defInput -and -not (Test-Path $defInput)) { if (-not (Ensure-FolderExists -Path $defInput -PromptIfMissing $true)) { throw "cfg input missing" } }
                if ($defOutput -and -not (Test-Path $defOutput)) { if (-not (Ensure-FolderExists -Path $defOutput -PromptIfMissing $true)) { throw "cfg output missing" } }
                if ($defArchive -and -not (Test-Path $defArchive)) { # ask to create
                    $res = [System.Windows.Forms.MessageBox]::Show("Katalog archiwum `"$defArchive`" nie istnieje. Utworzyć go?","Brak katalogu",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
                    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) { New-Item -ItemType Directory -Path $defArchive -Force | Out-Null } else { throw "cfg archive missing" }
                }
            } catch {
                $paths = Get-DefaultPaths -baseDir $base
                $defInput = $paths.input; $defOutput = $paths.output; $defArchive = $paths.archive
            }
        } catch {
            $paths = Get-DefaultPaths -baseDir $base
            $defInput = $paths.input; $defOutput = $paths.output; $defArchive = $paths.archive
        }
    } else {
        $paths = Get-DefaultPaths -baseDir $base
        $defInput = $paths.input; $defOutput = $paths.output; $defArchive = $paths.archive
        $save = @{ DefaultInput = $defInput; DefaultOutput = $defOutput; DefaultArchive = $defArchive } | ConvertTo-Json
        try { $save | Set-Content -Path $settingsFile -Encoding UTF8 -Force } catch { }
    }

    # set fields if empty
    if (-not $txtInput.Text)  { $txtInput.Text  = $defInput }
    if (-not $txtOutput.Text) { $txtOutput.Text = $defOutput }
    if (-not $txtArchive.Text) { $txtArchive.Text = $defArchive }

    # detect encoders and GPU
    $global:AvailableEncoders = Detect-CodecAvailability
    $global:gpuOk = $false
    if ($global:AvailableEncoders['hevc_nvenc']) { $global:gpuOk = Detect-GPU }

    # report to GUI log
    Report-EncoderStatus -enc $global:AvailableEncoders -gpuOk $global:gpuOk

    Write-Host "Kompresor PRO | MAX FORCE edition"
    Write-Host "---------------------------------"
    Write-Host "Encoder detection summary:" -ForegroundColor Cyan
    $friendly = @{
        hevc_nvenc = "HEVC NVENC"
        libx265    = "libx265 (HEVC)"
        libx264    = "libx264 (H.264)"
        libsvtav1  = "libsvtav1 (SVT-AV1)"
        "libaom-av1" = "libaom-av1 (AOM-AV1)"
    }
    foreach ($k in @('hevc_nvenc','libx265','libx264','libsvtav1','libaom-av1')) {
        $present = if ($global:AvailableEncoders[$k]) { 'YUP' } else { 'NOPE' }
        Write-Host ("{0,-26} : {1}" -f $friendly[$k], $present)
    }
    if ($global:AvailableEncoders['hevc_nvenc']) {
        $gpuMark = if ($global:gpuOk) { 'YUP (NVENC działa)' } else { 'NOPE (NVENC test nie przeszedł)' }
        Write-Host ("NVENC GPU test: {0}" -f $gpuMark) -ForegroundColor Yellow
    }
    Write-Host ""

    # Build codec list for combo
    Build-CodecList

    # default codec
    if ($global:AvailableEncoders['hevc_nvenc'] -and $global:gpuOk) { $defaultCodec = "HEVC NVENC" }
    elseif ($global:AvailableEncoders['libx265']) { $defaultCodec = "HEVC libx265" }
    elseif ($global:AvailableEncoders['libx264']) { $defaultCodec = "H.264 libx264" }
    else { if ($cbCodec.Items.Count -gt 0) { $defaultCodec = $cbCodec.Items[0] } else { $defaultCodec = "H.264 libx264" } }

    Set-CodecSelectionByValue -val $defaultCodec
    $global:PrevCodec = if ($cbCodec.SelectedItem) { $cbCodec.SelectedItem.ToString() } else { $null }

    # footer status
    $ffmpegOk = $false; if (Test-Path $ffmpegExe) { $ffmpegOk = $true } else { if (Get-Command -Name $ffmpegExe -ErrorAction SilentlyContinue) { $ffmpegOk = $true } }
    $ffprobeOk = $false; if (Test-Path $ffprobeExe) { $ffprobeOk = $true } else { if (Get-Command -Name $ffprobeExe -ErrorAction SilentlyContinue) { $ffprobeOk = $true } }
    $ffmpegStatus = if ($ffmpegOk) { "✓" } else { "✗" }
    $ffprobeStatus = if ($ffprobeOk) { "✓" } else { "✗" }
    $lblFooterRight.Text = "FFMPEG: $ffmpegStatus | FFPROBE: $ffprobeStatus | ENCODER: $defaultCodec"
    if ($defaultCodec -match 'NVENC') { $lblFooterRight.ForeColor = $clrSuccess } else { $lblFooterRight.ForeColor = $clrWarn }

    Log "Inicjalizacja zakończona."

    $global:proCollapsed = $true
    $gbPro.Visible = $false
    $gbEnc.Visible = $true
    $tbl.Visible = $false
    foreach ($ctrl in $tbl.Controls) { $ctrl.Visible = $false }
    $chkDelete.Visible = $true
    $btnTogglePro.Text = "PRO ▸"

    LayoutControls
    Load-Files
})

# ---------- Show form ----------
[void]$form.ShowDialog()