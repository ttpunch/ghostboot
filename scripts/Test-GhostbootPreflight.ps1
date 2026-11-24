<#
.SYNOPSIS
  Preflight checks before a Ghost-to-VirtualBox run. Read-only; changes nothing.

.PARAMETER SourceGho
  Full path to the .GHO file (spans .GHS / .001 sit in the same folder).
.PARAMETER VhdFolder
  Folder on the drive that will hold the VHD (portable or PC drive).
.PARAMETER NeededGB
  Free space to require on that drive (default 150).
.PARAMETER GhostPath
  Optional path to ghost32.exe. Not shipped by this repo.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceGho,
    [Parameter(Mandatory = $true)][string]$VhdFolder,
    [int]$NeededGB = 150,
    [string]$GhostPath
)

Set-StrictMode -Version 2.0
$results = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
    $results.Add([pscustomobject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
}

# Elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Check 'Elevated PowerShell' $isAdmin $(if ($isAdmin) { 'yes' } else { 'no: disk operations need Run as Administrator' })

# Source
$ghoOk = Test-Path -LiteralPath $SourceGho -PathType Leaf
Add-Check 'Source .GHO exists' $ghoOk $SourceGho
if ($ghoOk) {
    $gho = Get-Item -LiteralPath $SourceGho
    Add-Check 'Source size' ($gho.Length -gt 0) ('{0:N2} GB' -f ($gho.Length / 1GB))
    $spans = @(Get-ChildItem -LiteralPath $gho.DirectoryName -File | Where-Object { $_.BaseName -eq $gho.BaseName -and $_.Extension -match '^\.(ghs|\d{3})$' })
    Add-Check 'Spans beside the .GHO' $true ("$($spans.Count) span file(s) found; spans must stay in the same folder as the .GHO")
    $head = New-Object byte[] 2
    $fs = [System.IO.File]::OpenRead($gho.FullName)
    try { $fs.Read($head, 0, 2) | Out-Null } finally { $fs.Dispose() }
    Add-Check 'Header readable' $true ('first bytes: {0:X2} {1:X2} (Ghost images are not raw disk images)' -f $head[0], $head[1])
}

# Destination drive
if (Test-Path -LiteralPath $VhdFolder) {
    $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $VhdFolder).Path)
    $drive = Get-PSDrive | Where-Object { $_.Root -eq $root } | Select-Object -First 1
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        Add-Check 'Free space on VHD drive' ($freeGB -ge $NeededGB) ("$freeGB GB free, need $NeededGB GB")
    }
    $vol = Get-Volume -DriveLetter $root.Substring(0, 1) -ErrorAction SilentlyContinue
    if ($vol) {
        $fsOk = $vol.FileSystem -in 'NTFS', 'ReFS', 'exFAT'
        Add-Check 'VHD drive filesystem' $fsOk ("$($vol.FileSystem): FAT32 cannot hold a VHD over 4 GB")
        $disk = Get-Partition -DriveLetter $root.Substring(0, 1) -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue
        if ($disk) { Add-Check 'VHD drive bus' $true ("$($disk.BusType); USB drives are slow for Ghost restores") }
    }
} else {
    Add-Check 'VHD folder exists' $false $VhdFolder
}

# Stale virtual disks
$virt = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like '*Virtual*' })
Add-Check 'No stale virtual disks attached' ($virt.Count -eq 0) $(if ($virt.Count -eq 0) { 'none' } else { "attached: disk number(s) " + (($virt | ForEach-Object { $_.Number }) -join ', ') + '. Detach them first.' })

# Tools
$vbm = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
if (Test-Path -LiteralPath $vbm) {
    $v = (& $vbm --version) 2>$null
    Add-Check 'VirtualBox' $true $v
} else {
    Add-Check 'VirtualBox' $false 'VBoxManage.exe not found in the default location'
}
if ($GhostPath) { Add-Check 'ghost32.exe' (Test-Path -LiteralPath $GhostPath) $GhostPath }
else { Add-Check 'ghost32.exe' $false 'not given (-GhostPath). Required; this repo does not ship it.' }

# Host virtualization (matters for 64-bit guests)
$vt = $null
try { $vt = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled } catch { }
Add-Check 'Host virtualization (VT-x/AMD-V)' ($vt -eq $true) $(if ($null -eq $vt) { 'unknown' } else { "$vt" })

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) { Write-Output ("{0} check(s) failed." -f $failed.Count); exit 1 }
Write-Output 'All checks passed.'
