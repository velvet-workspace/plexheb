Option Explicit
' PlexHeb OneClick: hidden terminal, WinForms GUI stays visible.
' Single standalone file. Extracts its embedded PowerShell code to TEMP and deletes it on exit.
Dim fso, sh, f, row, payload64, dom, node, bytes, stream, tempFile, cmd, ps, result, env, folder
On Error Resume Next
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
If Err.Number <> 0 Then Fail "Windows Script Host is unavailable: " & Err.Description
Set f = fso.OpenTextFile(WScript.ScriptFullName, 1, False, 0)
If Err.Number <> 0 Then Fail "Cannot read program: " & Err.Description
payload64 = ""
Do Until f.AtEndOfStream
    row = f.ReadLine
    If Left(row, 8) = "'PSB64::" Then payload64 = payload64 & Mid(row, 9)
Loop
f.Close
If Len(payload64) < 200 Then Fail "Embedded PowerShell payload missing."
Set dom = CreateObject("Msxml2.DOMDocument.6.0")
If Err.Number <> 0 Then Fail "MSXML is unavailable: " & Err.Description
Set node = dom.createElement("binary")
node.DataType = "bin.base64"
node.Text = payload64
bytes = node.nodeTypedValue
If Err.Number <> 0 Then Fail "Could not decode program: " & Err.Description
Set stream = CreateObject("ADODB.Stream")
If Err.Number <> 0 Then Fail "ADODB.Stream is unavailable: " & Err.Description
stream.Type = 1
stream.Open
stream.Write bytes
tempFile = fso.BuildPath(sh.ExpandEnvironmentStrings("%TEMP%"), "PlexHeb-" & fso.GetBaseName(fso.GetTempName()) & ".ps1")
stream.SaveToFile tempFile, 2
stream.Close
If Err.Number <> 0 Then Fail "Could not create temporary program: " & Err.Description
folder = "D:\Videos"
If WScript.Arguments.Count > 0 Then folder = WScript.Arguments(0)
Set env = sh.Environment("PROCESS")
env("PLEXHEB_RUN_PS1") = tempFile
env("PLEXHEB_RUN_PATH") = folder
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(ps) Then ps = "powershell.exe"
cmd = Chr(34) & ps & Chr(34) & " -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQAgAD0AIAAnAFMAdABvAHAAJwAKAHQAcgB5ACAAewAKACAAIAAgACAAJABhAHAAcABQAGEAdABoACAAPQAgACQAZQBuAHYAOgBQAEwARQBYAEgARQBCAF8AUgBVAE4AXwBQAFMAMQAKACAAIAAgACAAJABmAG8AbABkAGUAcgAgAD0AIAAkAGUAbgB2ADoAUABMAEUAWABIAEUAQgBfAFIAVQBOAF8AUABBAFQASAAKACAAIAAgACAAaQBmACAAKAAtAG4AbwB0ACAAWwBJAE8ALgBGAGkAbABlAF0AOgA6AEUAeABpAHMAdABzACgAJABhAHAAcABQAGEAdABoACkAKQAgAHsAIAB0AGgAcgBvAHcAIAAnAFQAZQBtAHAAbwByAGEAcgB5ACAAUABsAGUAeABIAGUAYgAgAHMAYwByAGkAcAB0ACAAdwBhAHMAIABuAG8AdAAgAGMAcgBlAGEAdABlAGQALgAnACAAfQAKACAAIAAgACAAaQBmACAAKAAkAGUAbgB2ADoAUABMAEUAWABIAEUAQgBfAFQARQBTAFQAXwBOAE8ARwBVAEkAIAAtAGUAcQAgACcAMQAnACkAIAB7AAoAIAAgACAAIAAgACAAIAAgACQAbABpAG4AZQBzACAAPQAgAEAAKAAmACAAJABhAHAAcABQAGEAdABoACAALQBQAGEAdABoACAAJABmAG8AbABkAGUAcgAgAC0ATgBvAEcAdQBpACkACgAgACAAIAAgACAAIAAgACAAWwBJAE8ALgBGAGkAbABlAF0AOgA6AFcAcgBpAHQAZQBBAGwAbABMAGkAbgBlAHMAKAAoAEoAbwBpAG4ALQBQAGEAdABoACAAJABlAG4AdgA6AFQARQBNAFAAIAAnAFAAbABlAHgASABlAGIALQB0AGUAcwB0AC0AbwB1AHQAcAB1AHQALgB0AHgAdAAnACkALAAgACQAbABpAG4AZQBzACwAIABbAFQAZQB4AHQALgBFAG4AYwBvAGQAaQBuAGcAXQA6ADoAVQBUAEYAOAApAAoAIAAgACAAIAB9ACAAZQBsAHMAZQAgAHsACgAgACAAIAAgACAAIAAgACAAJgAgACQAYQBwAHAAUABhAHQAaAAgAC0AUABhAHQAaAAgACQAZgBvAGwAZABlAHIACgAgACAAIAAgAH0ACgB9AAoAYwBhAHQAYwBoACAAewAKACAAIAAgACAAJABkAGUAdABhAGkAbABzACAAPQAgACQAXwAgAHwAIABPAHUAdAAtAFMAdAByAGkAbgBnAAoAIAAgACAAIAAkAGwAbwBnACAAPQAgAEoAbwBpAG4ALQBQAGEAdABoACAAJABlAG4AdgA6AFQARQBNAFAAIAAnAFAAbABlAHgASABlAGIALQBsAGEAcwB0AC0AZQByAHIAbwByAC4AdAB4AHQAJwAKACAAIAAgACAAdAByAHkAIAB7ACAAWwBJAE8ALgBGAGkAbABlAF0AOgA6AFcAcgBpAHQAZQBBAGwAbABUAGUAeAB0ACgAJABsAG8AZwAsACAAJABkAGUAdABhAGkAbABzACwAIABbAFQAZQB4AHQALgBFAG4AYwBvAGQAaQBuAGcAXQA6ADoAVQBUAEYAOAApACAAfQAgAGMAYQB0AGMAaAAgAHsAfQAKACAAIAAgACAAdAByAHkAIAB7AAoAIAAgACAAIAAgACAAIAAgAEEAZABkAC0AVAB5AHAAZQAgAC0AQQBzAHMAZQBtAGIAbAB5AE4AYQBtAGUAIABTAHkAcwB0AGUAbQAuAFcAaQBuAGQAbwB3AHMALgBGAG8AcgBtAHMACgAgACAAIAAgACAAIAAgACAAWwB2AG8AaQBkAF0AWwBTAHkAcwB0AGUAbQAuAFcAaQBuAGQAbwB3AHMALgBGAG8AcgBtAHMALgBNAGUAcwBzAGEAZwBlAEIAbwB4AF0AOgA6AFMAaABvAHcAKAAoACcAUABsAGUAeABIAGUAYgAgAGMAbwB1AGwAZAAgAG4AbwB0ACAAcwB0AGEAcgB0ADoAJwAgACsAIABbAEUAbgB2AGkAcgBvAG4AbQBlAG4AdABdADoAOgBOAGUAdwBMAGkAbgBlACAAKwAgACQAZABlAHQAYQBpAGwAcwAgACsAIABbAEUAbgB2AGkAcgBvAG4AbQBlAG4AdABdADoAOgBOAGUAdwBMAGkAbgBlACAAKwAgACcARABlAHQAYQBpAGwAcwA6ACAAJwAgACsAIAAkAGwAbwBnACkALAAgACcAUABsAGUAeABIAGUAYgAgAHMAdABhAHIAdAB1AHAAIABlAHIAcgBvAHIAJwApAAoAIAAgACAAIAB9ACAAYwBhAHQAYwBoACAAewB9AAoAIAAgACAAIABlAHgAaQB0ACAAMQAKAH0ACgA="
result = sh.Run(cmd, 0, True)
If Err.Number <> 0 Then Fail "Could not launch PowerShell: " & Err.Description
If fso.FileExists(tempFile) Then fso.DeleteFile tempFile, True
If result <> 0 Then MsgBox "PlexHeb failed to start. Check %TEMP%\PlexHeb-last-error.txt", vbExclamation, "PlexHeb"
WScript.Quit result

Sub Fail(ByVal detail)
    MsgBox detail, vbCritical, "PlexHeb - startup error"
    WScript.Quit 1
End Sub
