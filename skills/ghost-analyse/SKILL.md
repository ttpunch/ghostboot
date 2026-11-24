---
name: ghost-analyse
description: Use to analyse a restored Ghost disk (Windows version, bitness, partitions, boot method, storage drivers, custom kernel) before booting it in a VM, and to read the findings.
version: 0.1.0
license: MIT
metadata:
  hermes:
    tags: [ghost, analysis, windows, boot, registry, read-only]
---

# ghost-analyse

Predict the first-boot BSOD before you boot. Works on a mounted restored disk. Read-only: the script
copies the SYSTEM hive to a temp folder and loads the copy, so the disk itself is never changed.

## Run

```powershell
# elevated PowerShell, VHD attached, Windows volume has a drive letter (here G:)
.\scripts\Get-GhostDiskAnalysis.ps1 -Root G:\ -CheckRegistry -OutFile .\report.json
```

Without `-CheckRegistry` (no elevation needed) you get version, bitness and boot files only.

## What it reports

| Area | Fields | Why it matters |
|---|---|---|
| OS | kernel version, name, 32/64-bit | picks VM settings; 5.0 is 2000, 5.1 XP, 6.1 Windows 7 |
| Boot | `boot.ini`, `bootmgr`, `ntldr`, BCD, EFI BCD, `/Kernel=` switch, extra `nt*.exe` | replaced kernel is a likely blocker; BCD names the old disk signature |
| Registry (SYSTEM copy) | current ControlSet, Start values for IDE/AHCI/SCSI services, CriticalDeviceDatabase entries | decides STOP 0x7B |
| Findings | severity, id, message, fix | feed straight into `bsod-triage` |

## Also check by hand

- Partition list: `Get-Disk`, `Get-Partition -DiskNumber <N>`. MBR or GPT, system versus OS partition, hidden or
  recovery partitions. Run the script on the OS partition; check the boot partition for `bootmgr` and `Boot\BCD`.
- `HKLM\SYSTEM\MountedDevices` drive letter mapping (offline copy) if letters look wrong after boot.
- The HAL type (affects ACPI/APIC settings) if the guest hangs early: compare the HAL file in `System32`.

## Reading findings

| Id | Severity | Meaning | Go to |
|---|---|---|---|
| `OEM-KERNEL` | error | boot.ini selects a replaced kernel | `bsod-triage` OEM section |
| `STOP-0x7B-IDE-DISABLED` | error | IDE drivers not boot-start | `bsod-triage` 0x7B |
| `CRITICAL-DEVICE-ENTRIES` | warn | no entry for the VM's IDE controller | `bsod-triage` 0x7B |
| `IDE-SERVICE-MISSING` | warn | generic IDE driver absent | inject drivers or use another controller |
| `BCD-DISK-SIGNATURE` | info | BCD still points at the old disk | `bsod-triage` 0xc000000e |
| `NO-BOOT-CONFIG` | warn | analysing the wrong partition | analyse the boot partition |
| `NO-WINDOWS` | error | not the OS partition | point `-Root` elsewhere |
| `X64-GUEST` | info | 64-bit guest | enable VT-x in BIOS and I/O APIC in the VM |

Report evidence and inference separately. A clean report does not guarantee a boot; it only removes the
known causes.
