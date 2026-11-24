<#
.SYNOPSIS
  Read-only analysis of a restored Windows disk before it is booted in a VM.

.DESCRIPTION
  Point -Root at a mounted volume (for example G:\) or any folder that holds a restored Windows
  install. The script reports the Windows version, bitness, boot method (boot.ini or BCD), custom
  kernel hints, and, with -CheckRegistry, the storage driver start values and critical device
  entries that decide whether the first boot ends in STOP 0x7B.

  It never writes to -Root. For the registry check it copies the SYSTEM hive to a temp folder,
  loads the copy, reads it, unloads it and deletes the copy.

.PARAMETER Root
  Drive letter root or folder of the restored disk (for example G:\).
.PARAMETER CheckRegistry
  Also inspect the offline SYSTEM hive. Needs an elevated PowerShell.
.PARAMETER OutFile
  Optional path for the JSON report. The summary is always printed.

.EXAMPLE
  .\Get-GhostDiskAnalysis.ps1 -Root G:\ -CheckRegistry -OutFile .\report.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [switch]$CheckRegistry,
    [string]$OutFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding([string]$Severity, [string]$Id, [string]$Message, [string]$Fix) {
    $findings.Add([pscustomobject]@{ Severity = $Severity; Id = $Id; Message = $Message; Fix = $Fix })
}

function Get-OsName([string]$Version) {
    if (-not $Version) { return 'unknown' }
    switch -Regex ($Version) {
        '^5\.0\.' { return 'Windows 2000' }
        '^5\.1\.' { return 'Windows XP' }
        '^5\.2\.' { return 'Windows Server 2003 / XP x64' }
        '^6\.0\.' { return 'Windows Vista / Server 2008' }
        '^6\.1\.' { return 'Windows 7 / Server 2008 R2' }
        '^6\.2\.' { return 'Windows 8' }
        '^6\.3\.' { return 'Windows 8.1' }
        '^10\.'   { return 'Windows 10 / 11' }
        default   { return "unrecognised ($Version)" }
    }
}

# PE header: Machine field tells 32-bit (0x014C) from 64-bit (0x8664).
function Get-PeMachine([string]$Path) {
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            $fs.Seek(0x3C, 'Begin') | Out-Null
            $peOffset = $br.ReadInt32()
            $fs.Seek($peOffset + 4, 'Begin') | Out-Null
            return $br.ReadUInt16()
        } finally { $fs.Dispose() }
    } catch { return $null }
}

if (-not (Test-Path -LiteralPath $Root)) { throw "Root not found: $Root" }
$Root = (Resolve-Path -LiteralPath $Root).Path

$report = [ordered]@{
    Root        = $Root
    Os          = $null
    Boot        = $null
    Registry    = $null
    Findings    = $null
}

# 1. Locate the Windows directory (WINDOWS or WINNT).
$winDir = $null
foreach ($name in 'Windows', 'WINDOWS', 'WINNT') {
    $candidate = Join-Path $Root $name
    if (Test-Path -LiteralPath (Join-Path $candidate 'System32')) { $winDir = $candidate; break }
}
if (-not $winDir) {
    Add-Finding 'error' 'NO-WINDOWS' 'No Windows or WINNT folder with System32 found under the root.' 'Check you pointed -Root at the OS partition, not the boot or recovery partition.'
    $report.Findings = $findings
    $report | ConvertTo-Json -Depth 6
    if ($OutFile) { $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath $OutFile }
    exit 2
}

# 2. OS version, bitness, kernel.
$kernelPath = Join-Path $winDir 'System32\ntoskrnl.exe'
$version = $null
if (Test-Path -LiteralPath $kernelPath) {
    $version = (Get-Item -LiteralPath $kernelPath).VersionInfo.ProductVersion
}
$machine = if (Test-Path -LiteralPath $kernelPath) { Get-PeMachine $kernelPath } else { $null }
$bitness = switch ($machine) { 0x014C { '32-bit' } 0x8664 { '64-bit' } default { 'unknown' } }
$report.Os = [ordered]@{
    WindowsDir   = $winDir
    KernelFound  = (Test-Path -LiteralPath $kernelPath)
    KernelVersion = $version
    Name         = Get-OsName $version
    Bitness      = $bitness
}

# 3. Boot method and custom kernels.
$bootIni = Join-Path $Root 'boot.ini'
$bcd = Join-Path $Root 'Boot\BCD'
$espBcd = Join-Path $Root 'EFI\Microsoft\Boot\BCD'
$bootInfo = [ordered]@{
    BootIniPresent = (Test-Path -LiteralPath $bootIni)
    BootmgrPresent = (Test-Path -LiteralPath (Join-Path $Root 'bootmgr'))
    NtldrPresent   = (Test-Path -LiteralPath (Join-Path $Root 'ntldr'))
    BcdPresent     = (Test-Path -LiteralPath $bcd)
    EfiBcdPresent  = (Test-Path -LiteralPath $espBcd)
    KernelSwitch   = $null
    CustomKernelFiles = @()
}
if ($bootInfo.BootIniPresent) {
    $ini = Get-Content -LiteralPath $bootIni -ErrorAction SilentlyContinue
    $m = $ini | Select-String -Pattern '/Kernel=(\S+)' | Select-Object -First 1
    if ($m) { $bootInfo.KernelSwitch = $m.Matches[0].Groups[1].Value }
}
$sys32 = Join-Path $winDir 'System32'
$stock = 'ntoskrnl.exe', 'ntkrnlpa.exe', 'ntkrnlmp.exe', 'ntkrpamp.exe'
$custom = Get-ChildItem -LiteralPath $sys32 -Filter 'nt*.exe' -ErrorAction SilentlyContinue |
    Where-Object { $stock -notcontains $_.Name.ToLower() } | ForEach-Object { $_.Name }
if ($custom) { $bootInfo.CustomKernelFiles = @($custom) }
$report.Boot = $bootInfo

if ($bootInfo.KernelSwitch) {
    Add-Finding 'error' 'OEM-KERNEL' "boot.ini selects a replaced kernel: $($bootInfo.KernelSwitch)." 'Registry fixes usually cannot help. Plan for vendor virtualization or the original hardware. Check the kernel version first.'
}
if (-not ($bootInfo.BootIniPresent -or $bootInfo.BcdPresent -or $bootInfo.EfiBcdPresent)) {
    Add-Finding 'warn' 'NO-BOOT-CONFIG' 'No boot.ini or BCD at this root. This may be the OS partition and the boot files are on another partition.' 'Analyse the System Reserved (boot) partition too, or rebuild boot files (see bsod-triage, 0xc000000e).'
}
if ($bootInfo.BcdPresent) {
    Add-Finding 'info' 'BCD-DISK-SIGNATURE' 'A BCD store is present. After a restore it usually still names the original disk signature.' 'If the VM shows 0xc000000e, rebuild boot files with bcdboot (bsod-triage).'
}

# 4. Registry check on a copy of the SYSTEM hive.
if ($CheckRegistry) {
    $hive = Join-Path $winDir 'System32\config\system'
    $reg = [ordered]@{ HiveFound = (Test-Path -LiteralPath $hive); Services = @{}; CriticalDevices = @{}; CurrentControlSet = $null }
    if ($reg.HiveFound) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ghostboot_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $copy = Join-Path $tmp 'system'
        $key = 'HKLM\GBOFFSYS'
        $loaded = $false
        try {
            Copy-Item -LiteralPath $hive -Destination $copy
            & reg.exe load $key $copy | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'reg load failed (needs an elevated PowerShell)' }
            $loaded = $true
            $sel = Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\GBOFFSYS\Select'
            $cs = 'ControlSet{0:D3}' -f [int]$sel.Current
            $reg.CurrentControlSet = $cs
            $svcNames = 'atapi', 'intelide', 'pciide', 'viaide', 'aliide', 'cmdide', 'toside', 'storahci', 'msahci', 'iaStorV', 'iaStor', 'LSI_SAS', 'lsi_scsi', 'vmscsi', 'pciide'
            foreach ($svc in $svcNames) {
                $p = "Registry::HKEY_LOCAL_MACHINE\GBOFFSYS\$cs\Services\$svc"
                if (Test-Path $p) { $reg.Services[$svc] = [int](Get-ItemProperty $p).Start }
            }
            $cdd = "Registry::HKEY_LOCAL_MACHINE\GBOFFSYS\$cs\Control\CriticalDeviceDatabase"
            foreach ($dev in 'pci#ven_8086&dev_7111', 'pci#ven_8086&dev_7010', 'pci#ven_8086&dev_7000', '*pnp0600') {
                $p = Join-Path $cdd $dev
                if (Test-Path $p) { $reg.CriticalDevices[$dev] = (Get-ItemProperty $p).Service } else { $reg.CriticalDevices[$dev] = $null }
            }
        } finally {
            if ($loaded) {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                & reg.exe unload $key | Out-Null
            }
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Interpret
        $ideNames = 'atapi', 'intelide', 'pciide'
        $ideOff = @($ideNames | Where-Object { $reg.Services.ContainsKey($_) -and $reg.Services[$_] -gt 0 })
        $ideMissing = @($ideNames | Where-Object { -not $reg.Services.ContainsKey($_) })
        if ($ideOff.Count -gt 0) {
            Add-Finding 'error' 'STOP-0x7B-IDE-DISABLED' ("IDE/ATAPI drivers not boot-start: " + ($ideOff -join ', ')) 'Set Start=0 for atapi, intelide, pciide in every ControlSet and add the CriticalDeviceDatabase entries (bsod-triage, 0x7B).'
        }
        if ($ideMissing.Count -gt 0) {
            Add-Finding 'warn' 'IDE-SERVICE-MISSING' ("IDE service key missing: " + ($ideMissing -join ', ')) 'The OS may not have generic IDE drivers; use a VM storage controller the OS knows, or inject drivers.'
        }
        $cddMissing = @($reg.CriticalDevices.Keys | Where-Object { -not $reg.CriticalDevices[$_] })
        if ($cddMissing.Count -gt 0) {
            Add-Finding 'warn' 'CRITICAL-DEVICE-ENTRIES' ("CriticalDeviceDatabase has no entry for: " + ($cddMissing -join ', ')) 'Add the Intel PIIX4 and generic IDE entries (bsod-triage, 0x7B) before first boot in VirtualBox.'
        }
    } else {
        Add-Finding 'error' 'NO-SYSTEM-HIVE' 'SYSTEM hive not found.' 'The restore may be incomplete. Re-run the restore.'
    }
    $report.Registry = $reg
}

# 5. Summary.
if ($report.Os.Bitness -eq '64-bit' -and $report.Os.Name -like 'Windows 7*') {
    Add-Finding 'info' 'X64-GUEST' 'A 64-bit guest needs VT-x/AMD-V enabled in the host BIOS for VirtualBox.' 'Check host virtualization; in the VM enable I/O APIC.'
}
$report.Findings = $findings
$json = $report | ConvertTo-Json -Depth 6
Write-Output $json
if ($OutFile) { $json | Set-Content -Encoding UTF8 -LiteralPath $OutFile }
