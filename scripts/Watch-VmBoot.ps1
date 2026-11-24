<#
.SYNOPSIS
  Start a VirtualBox VM and capture screenshots while it boots, so a hang or BSOD can be read.

.DESCRIPTION
  Optionally restores a snapshot first, starts the VM, can press F8 early to reach the Windows
  Advanced Options menu (and choose Safe Mode, which lists each driver as it loads), then saves a
  screenshot every -IntervalSeconds. Look at the PNGs. A screenshot of unchanged size across
  intervals means the screen is frozen.

.PARAMETER VmName
  VirtualBox VM name.
.PARAMETER OutDir
  Folder for the PNG files (created if missing).
.PARAMETER Seconds
  Total watch time after start (default 90).
.PARAMETER IntervalSeconds
  Seconds between screenshots (default 15).
.PARAMETER RestoreSnapshot
  Snapshot name to restore before starting (resets to a clean state).
.PARAMETER SafeMode
  Press F8 until the Advanced Options menu appears, then press Enter on the first item (Safe Mode).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VmName,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [int]$Seconds = 90,
    [int]$IntervalSeconds = 15,
    [string]$RestoreSnapshot,
    [switch]$SafeMode,
    [string]$VBoxManage = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
)

Set-StrictMode -Version 2.0
if (-not (Test-Path -LiteralPath $VBoxManage)) { throw "VBoxManage not found: $VBoxManage" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Get-State { ((& $VBoxManage showvminfo $VmName --machinereadable | Select-String '^VMState=').Line) }

if ((Get-State) -notmatch 'poweroff|saved|aborted') { & $VBoxManage controlvm $VmName poweroff 2>&1 | Out-Null; Start-Sleep 3 }
if ($RestoreSnapshot) { & $VBoxManage snapshot $VmName restore $RestoreSnapshot 2>&1 | Out-Null }
& $VBoxManage startvm $VmName --type gui 2>&1 | Out-Null

if ($SafeMode) {
    $probe = Join-Path $OutDir 'probe.png'
    $sw = [Diagnostics.Stopwatch]::StartNew(); $menu = $false
    while ($sw.Elapsed.TotalSeconds -lt 40 -and -not $menu) {
        & $VBoxManage controlvm $VmName keyboardputscancode 42 c2 2>&1 | Out-Null   # F8
        Start-Sleep -Milliseconds 600
        & $VBoxManage controlvm $VmName screenshotpng $probe 2>&1 | Out-Null
        # the Advanced Options menu is a text screen with much more content than the boot splash
        if ((Test-Path $probe) -and ((Get-Item $probe).Length -gt 3500)) { $menu = $true }
    }
    Write-Output ("Advanced Options menu seen: {0}" -f $menu)
    if ($menu) { Start-Sleep 1; & $VBoxManage controlvm $VmName keyboardputscancode 1c 9c 2>&1 | Out-Null }   # Enter = Safe Mode
}

$t = 0; $i = 0
while ($t -lt $Seconds) {
    Start-Sleep $IntervalSeconds; $t += $IntervalSeconds; $i++
    $f = Join-Path $OutDir ('boot_{0:D2}.png' -f $i)
    & $VBoxManage controlvm $VmName screenshotpng $f 2>&1 | Out-Null
    $len = if (Test-Path $f) { (Get-Item $f).Length } else { 0 }
    Write-Output ('{0,4}s  {1}  {2}  {3} bytes' -f $t, (Get-State), (Split-Path $f -Leaf), $len)
    if ((Get-State) -notmatch 'running') { break }
}
Write-Output "Screenshots are in $OutDir"
