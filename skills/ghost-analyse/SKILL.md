---
name: ghost-analyse
description: Use to analyse a restored Ghost disk (Windows version, bitness, partitions, boot method, NTFS dirty flag, storage drivers, HAL, original hardware) before booting it in a VM, and to read the findings.
version: 0.2.0
license: MIT
metadata:
  hermes:
    tags: [ghost, analysis, windows, boot, registry, ntfs, read-only]
---

# ghost-analyse

Predict the first-boot failure before you boot. Everything here is read-only against the restored disk.

## 0. Does a restore already exist?

Before restoring again, look for an earlier restore (VHD/VDI from a previous attempt, a VM folder named after the
image). Attach it **read-only** and analyse it; a finished restore saves hours. Check sizes: a dynamic VHD whose used
size is close to the image's uncompressed data is probably complete.

Attach read-only (elevated):

```powershell
@"
select vdisk file="<path>.vhd"
attach vdisk readonly
"@ | Out-File -Encoding ascii $env:TEMP\a.txt; diskpart /s $env:TEMP\a.txt
```

If you are not elevated, use `scripts/Invoke-ElevatedLogged.ps1` (one UAC click) to run the attach script and
capture its output. Files written by an old Windows keep that machine's ACLs: reads can be denied in a normal
session, so copy what you need with `robocopy <dir> <dest> <file> /B` from an elevated shell. Detach when done.

## 1. Analyse the volume

```powershell
.\scripts\Get-GhostDiskAnalysis.ps1 -Root G:\ -CheckDirty -OutFile .\report.json      # elevated for -CheckDirty/-CheckRegistry
python .\scripts\hive_report.py <copy of WINNT\system32\config\system>                 # no elevation, no reg load
```

`Get-GhostDiskAnalysis.ps1` reports version, bitness, boot files (boot.ini, ntldr, bootmgr, BCD), a replaced
kernel (a `/Kernel=` switch, or `ntos*.exe`/`ntkr*.exe` files), the NTFS dirty flag (`-CheckDirty`) and, with
`-CheckRegistry`, storage drivers. `hive_report.py` reads the SYSTEM hive file directly and reports: ControlSet,
service pack code, storage service start values, the critical device entries, the HAL device, the original PCI
hardware and every boot-start (0) and system-start (1) driver.

## 2. What the findings mean

| Finding | Meaning | Go to (`bsod-triage`) |
|---|---|---|
| `NTFS-DIRTY` | dirty flag set: Windows 2000/XP stop 0x7B with status 0xC0000032 | 3a |
| `OEM-KERNEL` | replaced kernel | 6 |
| `STOP-0x7B-IDE-DISABLED` | atapi/pciide not boot-start | 3b |
| `CRITICAL-DEVICE-ENTRIES` | no entry for the VM's IDE controller | 3b |
| `BCD-DISK-SIGNATURE` | BCD names the old disk | 4 |
| `NO-BOOT-CONFIG` / `NO-WINDOWS` | wrong partition | analyse the other partition |
| HAL name in `hive_report.py` | decides the VM's I/O APIC setting | 2 |
| third-party boot drivers (Start=0) | may hang in a VM with no matching hardware | 2 |

Original PCI hardware (Enum\PCI) tells you what the OS expects and what will show as "new hardware" in the VM.
A generic `pci#cc_0101 -> pciide` entry means the VM's IDE controller usually works without registry edits.

## 3. Also check by hand

- Partition table: `Get-Partition`, MBR or GPT, system versus OS partition; the system partition's NTFS boot sector
  (sectors per track, heads, hidden sectors equal to the partition start) and total sectors against the partition size.
- `chkdsk X:` (read-only) and `fsutil fsinfo ntfsinfo X:` for the NTFS and log versions.

Report evidence and inference separately. A clean report removes known causes; it does not guarantee a boot.
