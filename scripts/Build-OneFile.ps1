#Requires -Version 5.1
<#
Build the one-file, hidden-terminal PlexHeb launcher from its readable PowerShell
source and fixed ASCII VBS wrapper. No external packages or services.
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'src\PlexHeb-OneClick.ps1'
$wrapperPath = Join-Path $root 'src\PlexHeb-Launcher.vbs'
$bundlePath = Join-Path $root 'PlexHeb-NoTerminal.vbs'
$sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
if ($sourceBytes.Length -lt 3 -or
    $sourceBytes[0] -ne 0xEF -or $sourceBytes[1] -ne 0xBB -or
    $sourceBytes[2] -ne 0xBF) { throw 'PowerShell source must have UTF-8 BOM for Windows PowerShell 5.1' }

$lf = [string][char]10
$cr = [string][char]13
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$sourceText = $utf8.GetString($sourceBytes, 3, $sourceBytes.Length - 3)
$sourceText = $sourceText.Replace($cr + $lf, $lf).Replace($cr, $lf).TrimEnd([char]10) + $lf
$normalizedSource = New-Object byte[] ($utf8.GetByteCount($sourceText) + 3)
$normalizedSource[0] = 0xEF; $normalizedSource[1] = 0xBB; $normalizedSource[2] = 0xBF
[void]$utf8.GetBytes($sourceText, 0, $sourceText.Length, $normalizedSource, 3)
$encoded = [Convert]::ToBase64String($normalizedSource)
$chunks = New-Object 'System.Collections.Generic.List[string]'
for ($offset = 0; $offset -lt $encoded.Length; $offset += 160) {
    $length = [Math]::Min(160, $encoded.Length - $offset)
    [void]$chunks.Add("'PSB64::" + $encoded.Substring($offset, $length))
}

$wrapperBytes = [IO.File]::ReadAllBytes($wrapperPath)
if (@($wrapperBytes | Where-Object { $_ -gt 127 }).Count -ne 0) {
    throw 'VBS wrapper must be ASCII'
}
$wrapperText = [Text.Encoding]::ASCII.GetString($wrapperBytes)
$wrapperText = $wrapperText.Replace($cr + $lf, $lf).Replace($cr, $lf).TrimEnd([char]10)
if ($wrapperText -notmatch '(?m)^Option Explicit$' -or
    $wrapperText -notmatch '(?m)^End Sub$' -or
    $wrapperText -match '(?m)^''PSB64::') {
    throw 'Invalid or non-source VBS wrapper'
}
$bundleText = $wrapperText + $lf + $lf + ($chunks -join $lf) + $lf
$expected = [Text.Encoding]::ASCII.GetBytes($bundleText)
if ($Check) {
    if (-not [IO.File]::Exists($bundlePath)) { throw 'Generated VBS is missing; run Build-OneFile.ps1' }
    $actual = [IO.File]::ReadAllBytes($bundlePath)
    if ($actual.Length -ne $expected.Length) {
        throw 'Generated VBS differs from source; run Build-OneFile.ps1'
    }
    for ($i = 0; $i -lt $actual.Length; $i++) {
        if ($actual[$i] -ne $expected[$i]) {
            throw "Generated VBS differs at byte $i; run Build-OneFile.ps1"
        }
    }
    Write-Host "PASS: deterministic one-file launcher matches source ($($expected.Length) bytes)"
} else {
    [IO.File]::WriteAllBytes($bundlePath, $expected)
    Write-Host "WROTE: deterministic PlexHeb-NoTerminal.vbs ($($expected.Length) bytes)"
}
