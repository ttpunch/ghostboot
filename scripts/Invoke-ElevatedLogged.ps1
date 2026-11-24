<#
.SYNOPSIS
  Run a script file elevated (one UAC prompt) and capture its output to a log you can read afterwards.

.DESCRIPTION
  An agent or non-admin session cannot attach disks or copy protected files. This starts a hidden
  elevated PowerShell that runs -ScriptPath, writes a transcript to -LogPath, waits for it to finish
  and prints the log. The person at the PC must click Yes on the UAC prompt. It never bypasses UAC.

  The elevated script receives the log path as its first argument and should call
  Start-Transcript itself if it wants a transcript; this wrapper also tees stdout to -LogPath.

.PARAMETER ScriptPath
  The .ps1 file to run elevated. Read it first: it runs with administrator rights.
.PARAMETER LogPath
  Where to write the log.

.EXAMPLE
  .\Invoke-ElevatedLogged.ps1 -ScriptPath .\attach_readonly.ps1 -LogPath .\attach.log
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$LogPath
)

Set-StrictMode -Version 2.0
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Script not found: $ScriptPath" }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
Remove-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue

$wrapper = Join-Path ([System.IO.Path]::GetTempPath()) ('elev_' + [guid]::NewGuid().ToString('N') + '.ps1')
@'
param($Script, $Log)
& $Script $Log *>&1 | Tee-Object -FilePath $Log -Append | Out-Null
'@ | Set-Content -Encoding UTF8 -LiteralPath $wrapper

try {
    Start-Process powershell -Verb RunAs -WindowStyle Minimized -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$wrapper`"", "`"$ScriptPath`"", "`"$LogPath`""
    )
} finally {
    Remove-Item -LiteralPath $wrapper -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath }
else { Write-Output 'No log written: the UAC prompt was declined or the elevated script failed to start.' }
