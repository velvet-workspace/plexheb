#Requires -Version 5.1
<#
Plex Hebrew Subtitles - One Click
Windows PowerShell 5.1+ | Single-file WinForms app

Default: D:\Videos (recursive). Only SRT source files are read.
Outputs: <source-name>.HEB.srt alongside source, UTF-8 BOM, Plex bidi marks.
Never deletes, renames, or writes a source file. Existing HEB outputs may be
updated atomically when their expected content changes. No network access.

Run: right-click > Run with PowerShell
Optional: powershell.exe -NoProfile -STA -File .\PlexHeb-OneClick.ps1 -Path 'D:\Videos'
CLI: powershell.exe -NoProfile -File .\PlexHeb-OneClick.ps1 -NoGui -Path 'D:\Videos'
#>
[CmdletBinding()]
param(
    [string]$Path = 'D:\Videos',
    [switch]$NoGui,
    [switch]$NoAutoStart
)

$ErrorActionPreference = 'Stop'
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Enc1255 = [Text.Encoding]::GetEncoding(1255)
$script:Enc1252 = [Text.Encoding]::GetEncoding(1252)
$script:Utf8Bom = [byte[]]@(0xEF, 0xBB, 0xBF)
$script:MaxSubtitleBytes = 16MB

function Get-BytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-DecodedSubtitle([byte[]]$Bytes) {
    $n = $Bytes.Length
    if ($n -eq 0) { throw 'קובץ ריק' }
    $encoding = $null; $offset = 0; $name = ''

    if ($n -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
        $encoding = New-Object Text.UTF32Encoding($false, $false, $true)
        $offset = 4; $name = 'UTF-32 LE'
    }
    elseif ($n -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
        $encoding = New-Object Text.UTF32Encoding($true, $false, $true)
        $offset = 4; $name = 'UTF-32 BE'
    }
    elseif ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $encoding = $script:Utf8Strict
        $offset = 3; $name = 'UTF-8 BOM'
    }
    elseif ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $encoding = New-Object Text.UnicodeEncoding($false, $false, $true)
        $offset = 2; $name = 'UTF-16 LE'
    }
    elseif ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $encoding = New-Object Text.UnicodeEncoding($true, $false, $true)
        $offset = 2; $name = 'UTF-16 BE'
    }
    else {
        # BOM-less UTF-16 is common in legacy SRT files.
        $sample = [Math]::Min(4096, $n)
        $evenZeros = 0; $oddZeros = 0
        for ($i = 0; $i -lt $sample; $i++) {
            if ($Bytes[$i] -eq 0) {
                if ($i % 2 -eq 0) { $evenZeros++ } else { $oddZeros++ }
            }
        }
        if ($sample -ge 24 -and $oddZeros -gt ($sample * 0.2)) {
            $encoding = New-Object Text.UnicodeEncoding($false, $false, $true)
            $name = 'UTF-16 LE'
        }
        elseif ($sample -ge 24 -and $evenZeros -gt ($sample * 0.2)) {
            $encoding = New-Object Text.UnicodeEncoding($true, $false, $true)
            $name = 'UTF-16 BE'
        }
        else {
            try {
                $text = $script:Utf8Strict.GetString($Bytes)
                return [pscustomobject]@{ Text = $text; Encoding = 'UTF-8' }
            }
            catch {
                $encoding = $script:Enc1255
                $name = 'Windows-1255'
            }
        }
    }
    $strict = $encoding.Clone()
    $strict.DecoderFallback = [Text.DecoderFallback]::ExceptionFallback
    $text = $strict.GetString($Bytes, $offset, $n - $offset)
    return [pscustomobject]@{ Text = $text; Encoding = $name }
}

function Get-HebrewSignal([string]$Text) {
    $body = [regex]::Replace($Text, '(?m)^\s*\d+\s*$', ' ')
    $body = [regex]::Replace($body, '(?m)^[^\r\n]*-->[^\r\n]*$', ' ')
    $body = [regex]::Replace($body, '<[^>]*>|\{[^}]*\}', ' ')
    $hebrew = [regex]::Matches($body, '[\u05D0-\u05EA]').Count
    $letters = [regex]::Matches($body, '\p{L}').Count
    $broken = [regex]::Matches($body, '\uFFFD').Count
    $geresh = [regex]::Matches($body, '\u05F3').Count
    $latinExt = [regex]::Matches($body, '[\u00C0-\u00FF]').Count
    $ratio = if ($letters -gt 0) { $hebrew / [double]$letters } else { 0.0 }
    $bad = ($broken -gt 0) -or ($geresh -ge 10 -and $geresh -gt $hebrew * 0.25) -or `
           ($latinExt -gt 15 -and $letters -gt 0 -and ($latinExt / [double]$letters) -gt 0.22)
    [pscustomobject]@{
        Hebrew = $hebrew
        Ratio = $ratio
        Bad = $bad
        Good = ($hebrew -ge 2 -and $ratio -ge 0.2 -and -not $bad)
    }
}

function Get-ReadyHebrewSubtitle([byte[]]$Bytes) {
    $decoded = Get-DecodedSubtitle $Bytes
    $text = $decoded.Text
    if ($text -notmatch '-->') {
        return [pscustomobject]@{ Kind = 'Problem'; Message = 'מבנה SRT לא מזוהה'; Text = $null }
    }
    $baseSignal = Get-HebrewSignal $text
    if ($baseSignal.Good) {
        return [pscustomobject]@{ Kind = 'Ready'; Message = $decoded.Encoding; Text = $text }
    }

    # Conservative repair: text was decoded using ANSI and saved again as UTF-8.
    # Accept only when reverse decoding produces clearly better, valid Hebrew.
    foreach ($cp in @($script:Enc1255, $script:Enc1252)) {
        try {
            $strict = $cp.Clone()
            $strict.EncoderFallback = [Text.EncoderFallback]::ExceptionFallback
            $recovered = $script:Utf8Strict.GetString($strict.GetBytes($text))
            if ($recovered -notmatch '-->') { continue }
            $signal = Get-HebrewSignal $recovered
            if ($signal.Good -and (($signal.Hebrew -ge ($baseSignal.Hebrew + 5)) -or $baseSignal.Bad)) {
                return [pscustomobject]@{ Kind = 'Ready'; Message = "שוחזר קידוד $($cp.CodePage)"; Text = $recovered }
            }
        }
        catch { }
    }

    if ($baseSignal.Hebrew -eq 0 -and -not $baseSignal.Bad) {
        return [pscustomobject]@{ Kind = 'Other'; Message = 'אין טקסט עברי'; Text = $null }
    }
    return [pscustomobject]@{ Kind = 'Problem'; Message = 'עברית לא תקינה או קידוד לא ניתן לשחזור בטוח'; Text = $null }
}

function Add-PlexBidiMarks([string]$Text) {
    if ($Text -notmatch '[\u05D0-\u05EA]') { return $Text }
    $parts = [regex]::Split($Text, '(\r\n|\n|\r)')
    $embed = [string][char]0x202A
    $rtl = [string][char]0x200F
    $punctuation = [char[]]@('.', ',', '!', '?', ':', ';', '(', ')', '"', "'", '-', ' ')
    for ($i = 0; $i -lt $parts.Length; $i += 2) {
        $line = $parts[$i]
        if ($line -eq '' -or $line.Contains('-->') -or $line -match '^\s*\d+\s*$') { continue }
        if ($line.StartsWith($embed) -or $line.StartsWith($rtl)) { continue }
        $trimmed = $line.TrimStart($punctuation)
        if ($trimmed.Length -eq 0) { continue }
        if ([char]::IsDigit($trimmed[0])) {
            $line = $line.Insert(($line.Length - $trimmed.Length), $rtl)
        }
        # Mirrors the previous script's Plex-compatible bidi convention.
        $parts[$i] = $embed + $line
    }
    return ($parts -join '')
}

function ConvertTo-PlexBytes([string]$Text) {
    $fixed = Add-PlexBidiMarks $Text
    $raw = $script:Utf8Strict.GetBytes($fixed)
    $withBom = New-Object byte[] ($raw.Length + 3)
    [Array]::Copy($script:Utf8Bom, 0, $withBom, 0, 3)
    [Array]::Copy($raw, 0, $withBom, 3, $raw.Length)
    return ,$withBom
}

function Get-PlexOutputPath([string]$SourcePath) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $flag = ''
    if ($stem -match '(?i)\.(forced|sdh)$') {
        $flag = '.' + $Matches[1].ToLowerInvariant()
        $stem = $stem.Substring(0, $stem.Length - $Matches[0].Length)
    }
    if ($stem -match '(?i)\.(he|hebrew)$') {
        $stem = $stem.Substring(0, $stem.Length - $Matches[0].Length)
    }
    $name = $stem + '.HEB' + $flag + '.srt'
    return [IO.Path]::Combine([IO.Path]::GetDirectoryName($SourcePath), $name)
}

function Test-IsPlexOutput([string]$SourcePath) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
    return ($stem -match '(?i)\.heb(\.(forced|sdh))?$')
}

function Save-PlexCopy([string]$SourcePath, [string]$Destination, [byte[]]$Expected) {
    if ([string]::Equals([IO.Path]::GetFullPath($SourcePath), [IO.Path]::GetFullPath($Destination),
            [StringComparison]::OrdinalIgnoreCase)) { throw 'יעד ההמרה זהה לקובץ המקור' }

    $exists = [IO.File]::Exists($Destination)
    if ($exists) {
        $old = [IO.File]::ReadAllBytes($Destination)
        if ((Get-BytesHash $old) -eq (Get-BytesHash $Expected)) { return 'Current' }
    }
    $dir = [IO.Path]::GetDirectoryName($Destination)
    $temp = [IO.Path]::Combine($dir, '.plexheb-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $Expected)
        if ($exists) {
            # Atomic replacement changes the destination directory entry, never the source bytes.
            [IO.File]::Replace($temp, $Destination, $null)
        }
        else {
            [IO.File]::Move($temp, $Destination)
        }
        $verify = [IO.File]::ReadAllBytes($Destination)
        if ((Get-BytesHash $verify) -ne (Get-BytesHash $Expected)) { throw 'אימות כתיבת היעד נכשל' }
        if ($exists) { return 'Updated' }
        return 'Created'
    }
    finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Invoke-SubtitleFile([IO.FileInfo]$File) {
    $sourcePath = $File.FullName
    $destination = Get-PlexOutputPath $sourcePath
    try {
        if ($File.Length -gt $script:MaxSubtitleBytes) { throw 'הקובץ גדול מדי לכתוביות SRT' }
        $source = [IO.File]::ReadAllBytes($sourcePath)
        $sourceHash = Get-BytesHash $source
        $ready = Get-ReadyHebrewSubtitle $source
        if ($ready.Kind -eq 'Other') {
            return [pscustomobject]@{ Kind = 'Other'; Name = $File.Name; Message = $ready.Message; FullPath = $sourcePath }
        }
        if ($ready.Kind -eq 'Problem') {
            return [pscustomobject]@{ Kind = 'Problem'; Name = $File.Name; Message = $ready.Message; FullPath = $sourcePath }
        }
        $expected = ConvertTo-PlexBytes $ready.Text
        $writeStatus = Save-PlexCopy $sourcePath $destination $expected
        # Check source fingerprint to detect concurrent third-party edits, not to modify it.
        if ((Get-BytesHash ([IO.File]::ReadAllBytes($sourcePath))) -ne $sourceHash) {
            throw 'המקור השתנה בזמן העיבוד על ידי תהליך אחר'
        }
        $message = switch ($writeStatus) {
            'Created' { 'נוצר עותק Plex' }
            'Updated' { 'עותק Plex עודכן' }
            'Current' { 'עותק Plex כבר מעודכן' }
        }
        return [pscustomobject]@{ Kind = $writeStatus; Name = $File.Name; Message = $message; FullPath = $sourcePath }
    }
    catch {
        return [pscustomobject]@{ Kind = 'Problem'; Name = $File.Name; Message = $_.Exception.Message; FullPath = $sourcePath }
    }
}

function Get-SourceFiles([string]$Folder) {
    if (-not [IO.Directory]::Exists($Folder)) { throw "התיקייה לא קיימת: $Folder" }
    $all = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Filter '*.srt' -ErrorAction SilentlyContinue)
    # Existing .HEB.srt files are outputs and must never become new sources.
    # For collisions (Movie.srt and Movie.he.srt), prefer the explicitly tagged source.
    $byDestination = New-Object 'System.Collections.Generic.Dictionary[string,System.IO.FileInfo]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $all) {
        if (Test-IsPlexOutput $file.FullName) { continue }
        $dest = Get-PlexOutputPath $file.FullName
        if (-not $byDestination.ContainsKey($dest)) {
            $byDestination.Add($dest, $file)
        }
        elseif ($file.BaseName -match '(?i)\.he(\.(forced|sdh))?$' -and
                $byDestination[$dest].BaseName -notmatch '(?i)\.he(\.(forced|sdh))?$') {
            $byDestination[$dest] = $file
        }
    }
    $sources = @($byDestination.Values | Sort-Object FullName)
    return ,$sources
}

if ($NoGui) {
    $files = Get-SourceFiles $Path
    $counts = @{ Created = 0; Updated = 0; Current = 0; Other = 0; Problem = 0 }
    foreach ($file in $files) {
        $result = Invoke-SubtitleFile $file
        $counts[$result.Kind]++
        if ($result.Kind -eq 'Problem') { Write-Warning "$($result.FullPath): $($result.Message)" }
    }
    Write-Output ("Scanned: {0} | Created: {1} | Updated: {2} | Current: {3} | Non-Hebrew: {4} | Problems: {5}" -f `
        $files.Count, $counts.Created, $counts.Updated, $counts.Current, $counts.Other, $counts.Problem)
    return
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Path', ('"' + $Path + '"'))
    if ($NoAutoStart) { $argList += '-NoAutoStart' }
    $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    Start-Process -FilePath $engine -ArgumentList $argList
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function New-Color([int]$R, [int]$G, [int]$B) { [Drawing.Color]::FromArgb($R, $G, $B) }
$script:Ink = New-Color 30 41 59
$script:Muted = New-Color 100 116 139
$script:Blue = New-Color 39 95 216
$script:Background = New-Color 248 250 253
$script:Soft = New-Color 239 244 251
$script:Lines = New-Color 224 230 239

$form = New-Object Windows.Forms.Form
$form.Text = 'Plex Hebrew | כתוביות בלחיצה'
$form.Size = New-Object Drawing.Size(1030, 672)
$form.MinimumSize = New-Object Drawing.Size(810, 555)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.BackColor = [Drawing.Color]::White
$form.RightToLeft = 'Yes'
$form.RightToLeftLayout = $true

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 6
$layout.Padding = New-Object Windows.Forms.Padding(20, 16, 20, 16)
$layout.BackColor = [Drawing.Color]::White
[void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
foreach ($row in @(68, 67, 102, 45)) {
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $row)))
}
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 52)))
$form.Controls.Add($layout)

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Fill'
$title = New-Object Windows.Forms.Label
$title.Text = 'כתוביות בעברית. מוכנות לפלקס.'
$title.Font = New-Object Drawing.Font('Segoe UI', 19, [Drawing.FontStyle]::Bold)
$title.ForeColor = $script:Ink
$title.Dock = 'Top'
$title.Height = 40
$title.TextAlign = 'MiddleRight'
$subTitle = New-Object Windows.Forms.Label
$subTitle.Text = 'מאתרים, ממירים ויוצרים עותק חדש — בלי לשנות את המקור.'
$subTitle.ForeColor = $script:Muted
$subTitle.Dock = 'Bottom'
$subTitle.Height = 22
$subTitle.TextAlign = 'MiddleRight'
$header.Controls.AddRange(@($title, $subTitle))
$layout.Controls.Add($header, 0, 0)

$toolbar = New-Object Windows.Forms.TableLayoutPanel
$toolbar.Dock = 'Fill'
$toolbar.ColumnCount = 4
$toolbar.RowCount = 2
[void]$toolbar.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 21)))
[void]$toolbar.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
foreach ($c in @(@('Percent', 100), @('Absolute', 90), @('Absolute', 185), @('Absolute', 80))) {
    [void]$toolbar.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle($c[0], $c[1])))
}
$lblFolder = New-Object Windows.Forms.Label
$lblFolder.Text = 'התיקייה שלך'
$lblFolder.ForeColor = $script:Muted
$lblFolder.Dock = 'Fill'
$lblFolder.TextAlign = 'MiddleRight'
$toolbar.Controls.Add($lblFolder, 0, 0)
$txtFolder = New-Object Windows.Forms.TextBox
$txtFolder.Text = $Path
$txtFolder.RightToLeft = 'No'
$txtFolder.Dock = 'Fill'
$txtFolder.Margin = New-Object Windows.Forms.Padding(1, 6, 9, 3)
$toolbar.Controls.Add($txtFolder, 0, 1)
$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = 'בחירה...'
$btnBrowse.Dock = 'Fill'
$btnBrowse.Margin = New-Object Windows.Forms.Padding(4, 5, 4, 3)
$toolbar.Controls.Add($btnBrowse, 1, 1)
$btnRun = New-Object Windows.Forms.Button
$btnRun.Text = 'סרוק וצור עותקים'
$btnRun.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$btnRun.BackColor = $script:Blue
$btnRun.ForeColor = [Drawing.Color]::White
$btnRun.FlatStyle = 'Flat'
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.Dock = 'Fill'
$btnRun.Margin = New-Object Windows.Forms.Padding(4, 5, 4, 3)
$toolbar.Controls.Add($btnRun, 2, 1)
$btnStop = New-Object Windows.Forms.Button
$btnStop.Text = 'עצור'
$btnStop.Enabled = $false
$btnStop.Dock = 'Fill'
$btnStop.Margin = New-Object Windows.Forms.Padding(4, 5, 0, 3)
$toolbar.Controls.Add($btnStop, 3, 1)
$layout.Controls.Add($toolbar, 0, 1)

$summary = New-Object Windows.Forms.FlowLayoutPanel
$summary.Dock = 'Fill'
$summary.FlowDirection = 'RightToLeft'
$summary.WrapContents = $false
$summary.AutoScroll = $true
$summary.Padding = New-Object Windows.Forms.Padding(0, 7, 0, 0)
$summary.BackColor = [Drawing.Color]::White
$script:MetricLabels = @{}
foreach ($item in @(
    @('Scanned', 'נסרקו'), @('Created', 'חדשים'), @('Updated', 'עודכנו'),
    @('Current', 'כבר מעודכנים'), @('Problem', 'דורשים בדיקה')
)) {
    $card = New-Object Windows.Forms.Panel
    $card.Size = New-Object Drawing.Size(180, 76)
    $card.BackColor = $script:Soft
    $card.Margin = New-Object Windows.Forms.Padding(0, 1, 10, 1)
    $metricNumber = New-Object Windows.Forms.Label
    $metricNumber.Text = '0'
    $metricNumber.Font = New-Object Drawing.Font('Segoe UI', 22, [Drawing.FontStyle]::Bold)
    $metricNumber.ForeColor = $script:Ink
    $metricNumber.Dock = 'Top'
    $metricNumber.Height = 46
    $metricNumber.TextAlign = 'MiddleCenter'
    $metricCaption = New-Object Windows.Forms.Label
    $metricCaption.Text = $item[1]
    $metricCaption.ForeColor = $script:Muted
    $metricCaption.Dock = 'Bottom'
    $metricCaption.Height = 25
    $metricCaption.TextAlign = 'TopCenter'
    $card.Controls.AddRange(@($metricNumber, $metricCaption))
    $summary.Controls.Add($card)
    $script:MetricLabels[$item[0]] = $metricNumber
}
$layout.Controls.Add($summary, 0, 2)

$resultHeader = New-Object Windows.Forms.TableLayoutPanel
$resultHeader.Dock = 'Fill'
$resultHeader.ColumnCount = 2
[void]$resultHeader.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$resultHeader.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 190)))
$resultTitle = New-Object Windows.Forms.Label
$resultTitle.Text = 'קבצים שדורשים תשומת לב'
$resultTitle.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$resultTitle.ForeColor = $script:Ink
$resultTitle.Dock = 'Fill'
$resultTitle.TextAlign = 'MiddleRight'
$resultHeader.Controls.Add($resultTitle, 0, 0)
$chkAll = New-Object Windows.Forms.CheckBox
$chkAll.Text = 'הצג גם תוצאות תקינות'
$chkAll.Dock = 'Fill'
$chkAll.Checked = $false
$chkAll.ForeColor = $script:Muted
$chkAll.TextAlign = 'MiddleRight'
$resultHeader.Controls.Add($chkAll, 1, 0)
$layout.Controls.Add($resultHeader, 0, 3)

$resultPanel = New-Object Windows.Forms.Panel
$resultPanel.Dock = 'Fill'
$resultPanel.BackColor = $script:Background
$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.Visible = $false
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.MultiSelect = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [Drawing.Color]::White
$grid.BorderStyle = 'None'
$grid.RightToLeft = 'Yes'
$grid.RowTemplate.Height = 32
$grid.ColumnHeadersHeight = 35
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.BackColor = $script:Soft
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:Ink
$grid.DefaultCellStyle.SelectionBackColor = New-Color 221 232 252
$grid.DefaultCellStyle.SelectionForeColor = $script:Ink
$grid.GridColor = $script:Lines
$grid.CellBorderStyle = 'SingleHorizontal'
$grid.Columns.Add('FileName', 'שם קובץ') | Out-Null
$grid.Columns.Add('Result', 'מצב') | Out-Null
$grid.Columns.Add('Details', 'פרטים') | Out-Null
$grid.Columns.Add('FullPath', 'FullPath') | Out-Null
$grid.Columns['FileName'].FillWeight = 47
$grid.Columns['Result'].FillWeight = 19
$grid.Columns['Details'].FillWeight = 34
$grid.Columns['FullPath'].Visible = $false
$empty = New-Object Windows.Forms.Label
$empty.Dock = 'Fill'
$empty.Text = "כאן יוצגו רק כתוביות שדורשות בדיקה.`r`nהסריקה תתחיל אוטומטית."
$empty.TextAlign = 'MiddleCenter'
$empty.ForeColor = $script:Muted
$empty.BackColor = $script:Background
$resultPanel.Controls.Add($grid)
$resultPanel.Controls.Add($empty)
$empty.BringToFront()
$layout.Controls.Add($resultPanel, 0, 4)

$footer = New-Object Windows.Forms.TableLayoutPanel
$footer.Dock = 'Fill'
$footer.RowCount = 2
[void]$footer.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$footer.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 10)))
$statusText = New-Object Windows.Forms.Label
$statusText.Dock = 'Fill'
$statusText.Text = 'מוכן'
$statusText.TextAlign = 'MiddleRight'
$statusText.ForeColor = $script:Muted
$footer.Controls.Add($statusText, 0, 0)
$progress = New-Object Windows.Forms.ProgressBar
$progress.Dock = 'Fill'
$progress.Style = 'Continuous'
$progress.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 0)
$footer.Controls.Add($progress, 0, 1)
$layout.Controls.Add($footer, 0, 5)

$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:Files = @()
$script:Cursor = 0
$script:IsBusy = $false
$script:StopRequested = $false
$script:Stats = @{ Scanned = 0; Created = 0; Updated = 0; Current = 0; Other = 0; Problem = 0 }
$script:Clock = [Diagnostics.Stopwatch]::New()
$script:Timer = New-Object Windows.Forms.Timer
$script:Timer.Interval = 40

function Update-Metrics {
    foreach ($name in $script:MetricLabels.Keys) {
        $script:MetricLabels[$name].Text = [string]$script:Stats[$name]
    }
}

function Update-ResultsView {
    $grid.SuspendLayout()
    try {
        $grid.Rows.Clear()
        foreach ($result in $script:Results) {
            if (-not $chkAll.Checked -and $result.Kind -ne 'Problem') { continue }
            $kindText = switch ($result.Kind) {
                'Created' { 'חדש' }
                'Updated' { 'עודכן' }
                'Current' { 'כבר מעודכן' }
                'Other' { 'לא בעברית' }
                'Problem' { 'דורש בדיקה' }
            }
            $idx = $grid.Rows.Add($result.Name, $kindText, $result.Message, $result.FullPath)
            $grid.Rows[$idx].Cells['FileName'].ToolTipText = $result.FullPath
            if ($result.Kind -eq 'Problem') {
                $grid.Rows[$idx].Cells['Result'].Style.ForeColor = New-Color 177 56 56
            }
        }
    }
    finally { $grid.ResumeLayout() }
    $hasRows = $grid.Rows.Count -gt 0
    $grid.Visible = $hasRows
    $empty.Visible = -not $hasRows
    if ($hasRows) { $grid.BringToFront() } else { $empty.BringToFront() }
    if (-not $script:IsBusy) {
        if ($script:Stats.Problem -eq 0) {
            $empty.Text = if ($script:Stats.Scanned -eq 0) { 'לא נמצאו קובצי מקור מסוג SRT.' } else { 'הכול מוכן. אין קבצים שדורשים תשומת לב.' }
        }
        else {
            $empty.Text = 'אין תוצאות בתצוגה הנוכחית.'
        }
    }
}

function Set-WorkState([bool]$Working) {
    $script:IsBusy = $Working
    $btnRun.Enabled = -not $Working
    $btnBrowse.Enabled = -not $Working
    $txtFolder.Enabled = -not $Working
    $btnStop.Enabled = $Working
}

function Finish-Work {
    $script:Timer.Stop()
    $script:Clock.Stop()
    Set-WorkState $false
    Update-Metrics
    Update-ResultsView
    $duration = [Math]::Round($script:Clock.Elapsed.TotalSeconds, 1)
    $prefix = if ($script:StopRequested) { 'העבודה נעצרה' } else { 'הושלם' }
    $statusText.Text = "${prefix} | $($script:Stats.Scanned) נסרקו | $($script:Stats.Created) חדשים | $($script:Stats.Updated) עודכנו | $($script:Stats.Current) ללא שינוי | $($script:Stats.Other) לא בעברית | $($script:Stats.Problem) דורשים בדיקה | ${duration} שניות"
    $btnRun.Text = 'סרוק שוב'
}

function Start-Work {
    if ($script:IsBusy) { return }
    $folder = $txtFolder.Text.Trim().Trim('"')
    if (-not [IO.Directory]::Exists($folder)) {
        [void][Windows.Forms.MessageBox]::Show('התיקייה אינה קיימת. בחר תיקייה ונסה שוב.', 'Plex Hebrew', 'OK', 'Warning')
        return
    }
    $script:Results.Clear()
    $script:Stats = @{ Scanned = 0; Created = 0; Updated = 0; Current = 0; Other = 0; Problem = 0 }
    $script:Cursor = 0
    $script:StopRequested = $false
    $empty.Text = 'מאתר קובצי SRT...'
    $empty.Visible = $true
    $grid.Visible = $false
    Set-WorkState $true
    $statusText.Text = 'מאתר קבצים בתיקייה ובתתי־התיקיות...'
    $progress.Value = 0
    try {
        $script:Files = Get-SourceFiles $folder
        $progress.Maximum = [Math]::Max(1, $script:Files.Count)
        if ($script:Files.Count -eq 0) { Finish-Work; return }
        $script:Clock.Restart()
        $script:Timer.Start()
    }
    catch {
        Set-WorkState $false
        $statusText.Text = $_.Exception.Message
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'שגיאת סריקה', 'OK', 'Error')
    }
}

$script:Timer.Add_Tick({
    if (-not $script:IsBusy) { return }
    $batch = 0
    while ($batch -lt 12 -and $script:Cursor -lt $script:Files.Count -and -not $script:StopRequested) {
        $f = $script:Files[$script:Cursor]
        $script:Cursor++
        $batch++
        $r = Invoke-SubtitleFile $f
        $script:Results.Add($r)
        $script:Stats.Scanned++
        $script:Stats[$r.Kind]++
    }
    $progress.Value = [Math]::Min($progress.Maximum, $script:Cursor)
    Update-Metrics
    if ($script:Cursor -lt $script:Files.Count -and -not $script:StopRequested) {
        $statusText.Text = "מעבד כתוביות: $($script:Cursor) / $($script:Files.Count)"
    }
    else { Finish-Work }
})

$btnRun.Add_Click({ Start-Work })
$btnStop.Add_Click({ $script:StopRequested = $true; $btnStop.Enabled = $false })
$btnBrowse.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'בחר את תיקיית הסרטים / הסדרות'
    if ([IO.Directory]::Exists($txtFolder.Text)) { $dialog.SelectedPath = $txtFolder.Text }
    if ($dialog.ShowDialog($form) -eq 'OK') { $txtFolder.Text = $dialog.SelectedPath }
    $dialog.Dispose()
})
$txtFolder.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        $eventArgs.SuppressKeyPress = $true
        Start-Work
    }
})
$chkAll.Add_CheckedChanged({ Update-ResultsView })
$grid.Add_CellDoubleClick({
    param($sender, $eventArgs)
    if ($eventArgs.RowIndex -lt 0) { return }
    $filePath = [string]$grid.Rows[$eventArgs.RowIndex].Cells['FullPath'].Value
    if ([IO.File]::Exists($filePath)) {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $filePath + '"')
    }
})
$form.Add_Shown({
    $form.Activate()
    if (-not $NoAutoStart -and [IO.Directory]::Exists($txtFolder.Text)) { Start-Work }
    elseif (-not [IO.Directory]::Exists($txtFolder.Text)) {
        $statusText.Text = 'בחר תיקייה. ברירת המחדל D:\Videos אינה זמינה.'
        $empty.Text = 'בחר תיקייה כדי להתחיל.'
    }
})
$form.Add_FormClosing({ $script:Timer.Stop(); $script:StopRequested = $true })
[void]$form.ShowDialog()
$form.Dispose()