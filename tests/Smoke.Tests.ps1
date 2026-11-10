#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\PlexHeb-OneClick.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { throw 'Missing PowerShell source' }

$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('Syntax errors: ' + (($parseErrors | ForEach-Object Message) -join '; ')) }

# Windows PowerShell 5.1 needs BOM for a source file containing Hebrew literals.
$srcBytes = [IO.File]::ReadAllBytes($scriptPath)
if ($srcBytes.Length -lt 3 -or $srcBytes[0] -ne 0xEF -or $srcBytes[1] -ne 0xBB -or $srcBytes[2] -ne 0xBF) { throw 'Source script must have UTF-8 BOM' }

# The one-file launcher must embed exactly the human-readable source (apart from line endings/BOM).
$bundlePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'PlexHeb-NoTerminal.vbs'
$parts = @([IO.File]::ReadAllLines($bundlePath) | Where-Object { $_.StartsWith("'PSB64::") } | ForEach-Object { $_.Substring(8) })
if ($parts.Count -eq 0) { throw 'Embedded PowerShell missing from VBS launcher' }
$bundleText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($parts -join ''))).TrimStart([char]0xFEFF).TrimEnd([char]13,[char]10)
$sourceText = [IO.File]::ReadAllText($scriptPath,[Text.Encoding]::UTF8).TrimStart([char]0xFEFF).TrimEnd([char]13,[char]10)
if (($bundleText -replace "`r`n","`n") -cne ($sourceText -replace "`r`n","`n")) { throw 'VBS payload does not match readable PowerShell source' }

$folder = Join-Path $env:TEMP ('plexheb-ci-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
try {
    $hebrew = [string]([char]0x05E9) + [char]0x05DC + [char]0x05D5 + [char]0x05DD
    $srt = "1`r`n00:00:01,000 --> 00:00:02,000`r`n$hebrew`r`n"
    $original = Join-Path $folder 'Hebrew.srt'
    [IO.File]::WriteAllBytes($original, [Text.Encoding]::GetEncoding(1255).GetBytes($srt))
    $english = Join-Path $folder 'English.srt'
    [IO.File]::WriteAllText($english, "1`r`n00:00:01,000 --> 00:00:02,000`r`nHello world", (New-Object Text.UTF8Encoding($false)))
    $broken = Join-Path $folder 'Broken.srt'
    [IO.File]::WriteAllBytes($broken, [byte[]]@(255,0,34,11,44))

    $before = (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash
    $first = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoGui -Path $folder 3>&1) | Out-String
    if ($LASTEXITCODE -ne 0) { throw "First run failed: $first" }
    if ($first -notmatch 'Created: 1' -or $first -notmatch 'Non-Hebrew: 1' -or $first -notmatch 'Problems: 1') {
        throw "Unexpected initial scan: $first"
    }
    $out = Join-Path $folder 'Hebrew.HEB.srt'
    if (-not [IO.File]::Exists($out)) { throw 'HEB copy was not created' }
    $bytes = [IO.File]::ReadAllBytes($out)
    if ($bytes.Length -lt 4 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { throw 'UTF-8 BOM missing' }
    if (([Text.Encoding]::UTF8.GetString($bytes)).IndexOf($hebrew) -lt 0) { throw 'Hebrew subtitle missing after conversion' }
    $outputBefore = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash

    $second = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -NoGui -Path $folder 3>&1) | Out-String
    if ($LASTEXITCODE -ne 0 -or $second -notmatch 'Current: 1') { throw "Second run did not skip unchanged output: $second" }
    if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ne $before) { throw 'Original changed' }
    if ((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash -ne $outputBefore) { throw 'HEB output changed on identical rerun' }
    Write-Host 'PASS: syntax, CP1255 Hebrew, UTF-8 BOM, English/broken skip, idempotence, source unchanged'
}
finally {
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
